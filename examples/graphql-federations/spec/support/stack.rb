# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'socket'
require 'uri'
require 'yaml'
require 'fileutils'

# The federated graph the suite runs against, started once:
#
# 1. PostgreSQL: a Testcontainers one, on a port Docker picks, or yours when
#    PGHOST is set (both subgraphs' databases are created in it);
# 2. the two subgraphs, each a Rails server of its own (Stack::Subgraph);
# 3. the supergraph, composed by `rover supergraph compose` from the SDL each
#    running subgraph answers (`_service { sdl }`), which Lighthouse prints;
# 4. Apollo Router, in Docker, in front of them (Stack::Router);
# 5. GraphQL Yoga, the other gateway, when Node is installed (Stack::Yoga).
#
# Logs go to tmp/: accounts.log, blog.log, compose.log, router.log, yoga.log.
module Stack
  ROOT = File.expand_path('../..', __dir__)
  TMP = File.join(ROOT, 'tmp')
  SUBGRAPHS = %w[accounts blog].freeze

  # What starting the pieces shares: free ports, and waiting for a server.
  module Waiting
    module_function

    # A port no socket holds, on any address. Not TCPServer's: it sets
    # SO_REUSEADDR, with which macOS hands out 127.0.0.1 ports Docker already
    # publishes on 0.0.0.0, and the router's `docker run -p` then fails.
    def free_port
      socket = Socket.new(:INET, :STREAM)
      socket.bind(Addrinfo.tcp('0.0.0.0', 0))
      socket.local_address.ip_port
    ensure
      socket&.close
    end

    def wait_for(what, timeout: 90)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if begin
          yield
        rescue SystemCallError, IOError, Net::ReadTimeout
          false
        end
        raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.25
      end
    end
  end

  class << self
    attr_reader :composed, :subgraphs, :router, :yoga

    def start!
      return if @started

      @started = true
      FileUtils.mkdir_p(TMP)
      at_exit { stop! }
      database!
      SUBGRAPHS.each { |name| Subgraph.prepare(name) } # accounts first: blog reads its users table.
      @subgraphs = SUBGRAPHS.to_h { |name| [name, Subgraph.new(name).start] }
      compose!
      @router = Router.new(subgraphs, composed, licensed: licensed?).start
      @yoga = Yoga.new(subgraphs, composed).start if yoga?
    end

    # Is Node installed, to run the Yoga gateway?
    def yoga? = Yoga.available?

    # Is the router connected to GraphOS, with what that license allows (subscriptions, batching)?
    def licensed? = !ENV['APOLLO_KEY'].to_s.empty? && !ENV['APOLLO_GRAPH_REF'].to_s.empty?

    def rover? = !rover_bin.nil?

    # rover: ROVER, else the one on the PATH, else the one its installer puts in ~/.rover/bin.
    def rover_bin
      @rover_bin ||= [ENV.fetch('ROVER', nil), 'rover', File.expand_path('~/.rover/bin/rover')].compact.find do |candidate|
        system(candidate, '--version', out: File::NULL, err: File::NULL)
      rescue Errno::ENOENT
        false
      end
    end

    def router_url = router.url

    def yoga_url = yoga.url

    def subgraph(name) = subgraphs.fetch(name)

    # The SDL a running subgraph answers.
    def sdl(name)
      Client.new(subgraph(name).url).execute('{ _service { sdl } }').dig('data', '_service', 'sdl')
    end

    def stop!
      yoga&.stop
      router&.stop
      (subgraphs || {}).each_value(&:stop)
      @postgres&.remove(force: true)
    end

    private

    def database!
      return if ENV['PGHOST']

      require 'testcontainers/postgres'
      # The `postgres` database: the one the image always creates, which the
      # container's health check connects to (the subgraphs create their own).
      @postgres = Testcontainers::PostgresContainer.new('postgres:16', username: 'postgres', password: 'postgres', database: 'postgres')
      @postgres.start
      url = URI(@postgres.database_url)
      ENV.update('PGHOST' => url.host, 'PGPORT' => url.port.to_s, 'PGUSER' => 'postgres', 'PGPASSWORD' => 'postgres')
    end

    # Composes the supergraph from the SDL the running subgraphs answer, into
    # tmp/. Without rover, the checked-in router/supergraph.graphql is used.
    def compose!
      @composed = File.join(TMP, 'supergraph.graphql')
      unless rover?
        warn 'rover is not installed: the router uses router/supergraph.graphql as it is checked in.'
        return FileUtils.cp(File.join(ROOT, 'router/supergraph.graphql'), composed)
      end

      output, log, status = Open3.capture3(rover_bin, 'supergraph', 'compose', '--config', compose_config, '--elv2-license', 'accept')
      File.write(File.join(TMP, 'compose.log'), log)
      raise "rover could not compose the supergraph:\n#{log}" unless status.success?

      File.write(composed, output)
    end

    # router/supergraph.yaml, with each subgraph's SDL as it answers it, in tmp/.
    def compose_config
      config = YAML.load_file(File.join(ROOT, 'router/supergraph.yaml'))
      SUBGRAPHS.each do |name|
        path = File.join(TMP, "#{name}.graphql")
        File.write(path, sdl(name))
        config['subgraphs'][name]['schema']['file'] = path
      end
      File.join(TMP, 'supergraph.yaml').tap { |path| File.write(path, config.to_yaml) }
    end
  end
end

require_relative 'subgraph'
require_relative 'router'
require_relative 'yoga'
