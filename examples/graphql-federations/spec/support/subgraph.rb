# frozen_string_literal: true

# A subgraph: one of the Rails apps, served by `bin/rails server` in the test
# environment, on a free port, with its log in tmp/<name>.log.
class Stack::Subgraph
  ENV_VARS = { 'RAILS_ENV' => 'test' }.freeze

  attr_reader :name, :port

  # Creates (or migrates) the app's database.
  def self.prepare(name)
    log = File.join(Stack::TMP, "#{name}.log")
    ok = system(ENV_VARS, 'bin/rails', 'db:prepare', chdir: File.join(Stack::ROOT, name), out: [log, 'a'], err: [log, 'a'])
    raise "bin/rails db:prepare failed in #{name}; see #{log}" unless ok
  end

  def initialize(name)
    @name = name
    @port = Stack::Waiting.free_port
  end

  def url = "http://127.0.0.1:#{port}/graphql"

  def start
    log = File.join(Stack::TMP, "#{name}.log")
    @pid = Process.spawn(ENV_VARS, 'bin/rails', 'server', '-b', '0.0.0.0', '-p', port.to_s, '-P', File.join(Stack::TMP, "#{name}.pid"),
                         chdir: File.join(Stack::ROOT, name), out: log, err: log)
    Stack::Waiting.wait_for("the #{name} subgraph (#{log})") do
      Process.waitpid(@pid, Process::WNOHANG) && raise("the #{name} subgraph stopped; see #{log}")
      Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).is_a?(Net::HTTPSuccess)
    end
    self
  end

  def stop
    Process.kill('TERM', @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
