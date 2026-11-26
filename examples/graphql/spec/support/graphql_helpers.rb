# Requests against the app's real endpoint, as a client would send them.
module GraphqlHelpers
  # POSTs a query (or only `extensions`, for a persisted query) and returns the
  # parsed JSON body. `as:` signs the request in with that user's API token.
  def graphql(query = nil, variables: {}, as: nil, extensions: nil)
    params = { query: query, variables: variables, extensions: extensions }.compact
    post '/graphql', params: params, headers: auth_headers(as), as: :json
    response.parsed_body
  end

  def auth_headers(user)
    user ? { 'Authorization' => "Bearer #{user.api_token}" } : {}
  end

  # The `extensions.validation` messages of the first error, keyed by argument path.
  def validation_errors(body)
    body.dig('errors', 0, 'extensions', 'validation')
  end

  def error_messages(body)
    Array(body['errors']).pluck('message')
  end

  # The SQL statements a block runs, so specs can pin N+1 behaviour.
  def sql_queries(&)
    queries = []
    callback = lambda { |*, payload|
      queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/)
    }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    queries
  end
end
