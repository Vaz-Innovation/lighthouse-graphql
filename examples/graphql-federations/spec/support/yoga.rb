# frozen_string_literal: true

# The other gateway: GraphQL Yoga (gateway/, Node), with the supergraph stitched
# by @graphql-tools/federation. Where Apollo Router asks the blog for a
# subscription with an HTTP callback, Yoga asks it over Server-Sent Events, and
# streams the updates to its clients the same way; it needs no license. It reads
# the composed supergraph and reaches the suite's subgraphs (SUBGRAPH_URLS).
# Its log is tmp/yoga.log. Without Node, its specs are skipped.
class Stack::Yoga
  DIR = File.join(Stack::ROOT, 'gateway')

  attr_reader :port

  def self.available? = system('node', '--version', out: File::NULL, err: File::NULL)

  def initialize(subgraphs, supergraph)
    @subgraphs = subgraphs
    @supergraph = supergraph
    @port = Stack::Waiting.free_port
  end

  def url = "http://127.0.0.1:#{port}/graphql"

  def start
    install!
    env = { 'PORT' => port.to_s, 'SUPERGRAPH' => @supergraph,
            'SUBGRAPH_URLS' => JSON.generate(@subgraphs.transform_values(&:url)) }
    @pid = Process.spawn(env, 'node', 'src/server.js', chdir: DIR, out: log, err: log)
    Stack::Waiting.wait_for("the Yoga gateway (#{log})") do
      Process.waitpid(@pid, Process::WNOHANG) && raise("the Yoga gateway stopped; see #{log}")
      Client.new(url).execute('{ __typename }')['data'] == { '__typename' => 'Query' }
    end
    self
  end

  def stop
    return unless @pid

    Process.kill('TERM', @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  private

  def log = File.join(Stack::TMP, 'yoga.log')

  def install!
    return if File.exist?(File.join(DIR, 'node_modules/.package-lock.json'))
    raise "npm ci failed in gateway/; see #{log}" unless system('npm', 'ci', chdir: DIR, out: log, err: log)
  end
end
