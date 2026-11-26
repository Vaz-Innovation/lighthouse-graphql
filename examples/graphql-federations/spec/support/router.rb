# frozen_string_literal: true

# Apollo Router, in Docker (ROUTER_IMAGE), with router/router.yaml, in front of
# the subgraphs: their URLs are the suite's servers' (override_subgraph_url),
# reached from the container through host.docker.internal. Subscriptions and
# batching are GraphOS features of the router: they are on only when APOLLO_KEY
# and APOLLO_GRAPH_REF name a graph (a free plan's will do). Its log is tmp/router.log.
class Stack::Router
  IMAGE = ENV.fetch('ROUTER_IMAGE', 'ghcr.io/apollographql/router:v2.19.0')

  # What router/router.yaml configures that only a router connected to GraphOS runs.
  LICENSED = %w[subscription batching].freeze

  attr_reader :port

  def initialize(subgraphs, supergraph, licensed:)
    @subgraphs = subgraphs
    @supergraph = supergraph
    @licensed = licensed
    @port = Stack::Waiting.free_port
    @name = "lighthouse-federation-router-#{Process.pid}"
  end

  def url = "http://127.0.0.1:#{port}/"

  def start
    File.write(config_path, config.to_yaml)
    system('docker', 'rm', '-f', @name, out: File::NULL, err: File::NULL)
    raise 'docker could not start the router' unless system(*command, out: File::NULL)

    @started = true
    Stack::Waiting.wait_for('the router (tmp/router.log)') do
      raise "the router stopped; see #{log!}" unless running?

      Client.new(url).execute('{ __typename }')['data'] == { '__typename' => 'Query' }
    end
    self
  end

  def stop
    return unless @started

    log!
    system('docker', 'rm', '-f', @name, out: File::NULL, err: File::NULL)
  end

  private

  def config_path = File.join(Stack::TMP, 'router.yaml')

  def config
    config = YAML.load_file(File.join(Stack::ROOT, 'router/router.yaml'))
    config['override_subgraph_url'] = @subgraphs.transform_values { |subgraph| "http://host.docker.internal:#{subgraph.port}/graphql" }
    if @licensed
      # The subgraph calls the router back on the port the suite maps to its listener.
      config['subscription']['mode']['callback']['public_url'] = "http://127.0.0.1:#{port}/callback"
    else
      LICENSED.each { |key| config.delete(key) }
    end
    config
  end

  def command
    command = ['docker', 'run', '-d', '--name', @name, '-p', "#{port}:4000", '--add-host', 'host.docker.internal:host-gateway',
               '-e', 'APOLLO_TELEMETRY_DISABLED=true', '-v', "#{config_path}:/config/router.yaml:ro",
               '-v', "#{@supergraph}:/config/supergraph.graphql:ro"]
    command += ['-e', 'APOLLO_KEY', '-e', 'APOLLO_GRAPH_REF'] if @licensed
    command + [IMAGE, '--config', '/config/router.yaml', '--supergraph', '/config/supergraph.graphql']
  end

  def running?
    `docker inspect -f '{{.State.Running}}' #{@name} 2>/dev/null`.strip == 'true'
  end

  # Keeps the router's log in tmp/router.log; answers its path.
  def log!
    File.join(Stack::TMP, 'router.log').tap { |path| File.write(path, `docker logs #{@name} 2>&1`) }
  end
end
