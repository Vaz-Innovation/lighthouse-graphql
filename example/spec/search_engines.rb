# The engines Searchkick runs @search on in the suite: Elasticsearch and OpenSearch,
# each a throwaway Testcontainers one on a host port Docker picks, started the first
# time a spec asks for it. ELASTICSEARCH_URL or OPENSEARCH_URL names a server of
# your own instead (CI's OpenSearch 2 service), and SEARCH_ENGINES lists the engines
# to run on (both by default; SEARCH_ENGINES= runs none, and skips their specs).
module SearchEngines
  IMAGES = {
    elasticsearch: 'elasticsearch:9.5.5',
    opensearch: 'opensearchproject/opensearch:3.9.0'
  }.freeze

  URL_VARIABLES = { elasticsearch: 'ELASTICSEARCH_URL', opensearch: 'OPENSEARCH_URL' }.freeze

  # A single node, without the security plugin (no TLS, no password), in half a gigabyte.
  ENVIRONMENTS = {
    elasticsearch: { 'discovery.type' => 'single-node', 'xpack.security.enabled' => 'false', 'ES_JAVA_OPTS' => '-Xms512m -Xmx512m' },
    opensearch: {
      'discovery.type' => 'single-node', 'DISABLE_SECURITY_PLUGIN' => 'true', 'DISABLE_INSTALL_DEMO_CONFIG' => 'true',
      'OPENSEARCH_JAVA_OPTS' => '-Xms512m -Xmx512m'
    }
  }.freeze

  # What Searchkick memoizes about the server it first talked to.
  SERVER_MEMOS = %i[@server_info @server_version @opensearch @opensearch4_client].freeze

  module_function

  def enabled = ENV.fetch('SEARCH_ENGINES', IMAGES.keys.join(',')).split(',').map { |name| name.strip.to_sym } & IMAGES.keys

  # Point Searchkick at `engine`, starting its container first if no URL names one.
  def use(engine)
    variable = URL_VARIABLES.fetch(engine)
    ENV[variable] = start(engine) if ENV[variable].blank?
    require(engine == :opensearch ? 'opensearch' : 'elasticsearch')
    Searchkick.client_type = engine
    Searchkick.client = nil
    SERVER_MEMOS.each { |memo| Searchkick.remove_instance_variable(memo) if Searchkick.instance_variable_defined?(memo) }
  end

  def start(engine)
    require 'testcontainers'

    container = Testcontainers::DockerContainer.new(IMAGES.fetch(engine), env: ENVIRONMENTS.fetch(engine))
    container.with_exposed_ports(9200)
    container.start
    at_exit { container.remove(force: true) }
    container.wait_for_http(path: '/_cluster/health?wait_for_status=yellow&timeout=1s', container_port: 9200, timeout: 180)
    "http://#{container.host}:#{container.mapped_port(9200)}"
  end
end
