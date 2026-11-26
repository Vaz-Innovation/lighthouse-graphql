# frozen_string_literal: true

# Sends GraphQL requests over HTTP, as a client of the router (or of one
# subgraph) does. `token` signs in (`Authorization: Bearer <token>`).
class Client
  attr_reader :last_response

  def initialize(url, token: nil, headers: {})
    @uri = URI(url)
    @headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }.merge(headers)
    @headers['Authorization'] = "Bearer #{token}" if token
  end

  # The parsed response of one operation.
  def execute(query, variables: {}, operation_name: nil, extensions: nil, headers: {})
    body = { query: query, variables: variables, operationName: operation_name, extensions: extensions }.compact
    JSON.parse(post_body(body, headers).body)
  end

  # Posts any body (a batch's array, an APQ request without the query) and answers the HTTP response.
  def post_body(body, headers = {})
    request = Net::HTTP::Post.new(@uri.request_uri.empty? ? '/' : @uri.request_uri, @headers.merge(headers))
    request.body = body.is_a?(String) ? body : JSON.generate(body)
    @last_response = Net::HTTP.start(@uri.host, @uri.port, read_timeout: 30) { |http| http.request(request) }
  end

  # A multipart request (the GraphQL multipart request specification): the
  # operation, with each file of `files` ({ "0" => [name, content, type] }) in
  # place of the variables `map` names.
  def upload(operations, map, files, headers: {})
    boundary = "lighthouse#{SecureRandom.hex(8)}"
    parts = { 'operations' => JSON.generate(operations), 'map' => JSON.generate(map) }.map do |name, value|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end
    files.each do |key, (filename, content, type)|
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"; filename=\"#{filename}\"\r\n" \
               "Content-Type: #{type}\r\n\r\n#{content}\r\n"
    end
    response = post_body("#{parts.join}--#{boundary}--\r\n", headers.merge('Content-Type' => "multipart/form-data; boundary=#{boundary}"))
    JSON.parse(response.body)
  end

  def with(token: nil, headers: {})
    self.class.new(@uri.to_s, token: token, headers: @headers.except('Authorization').merge(headers))
  end
end
