# frozen_string_literal: true

# Comment's Searchkick index (Query.searchComments, through @search) lives in
# Elasticsearch at ELASTICSEARCH_URL (http://localhost:9200 by default), or in
# OpenSearch when OPENSEARCH_URL is set. Searchkick refuses to guess when both
# clients are loaded, so only the one in use is required.
if ENV['OPENSEARCH_URL']
  require 'opensearch'
  Searchkick.client_type = :opensearch
else
  require 'elasticsearch'
  Searchkick.client_type = :elasticsearch
end
