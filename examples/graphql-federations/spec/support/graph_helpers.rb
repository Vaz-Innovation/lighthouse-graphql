# frozen_string_literal: true

require 'pg'

# What the specs share: clients of the router and of each subgraph, and users to sign in as.
module GraphHelpers
  def router(token: nil, headers: {}) = Client.new(Stack.router_url, token: token, headers: headers)

  def yoga(token: nil, headers: {}) = Client.new(Stack.yoga_url, token: token, headers: headers)

  def subgraph(name, token: nil) = Client.new(Stack.subgraph(name).url, token: token)

  # A new user, signed up through the router (accounts' Mutation.signUp), with
  # the API token accounts gave them, read from its database as its staff would;
  # `admin: true` makes them one.
  def sign_up(name: 'Ada Lovelace', admin: false)
    email = "#{name.downcase.gsub(/\W+/, '-')}-#{SecureRandom.hex(4)}@lighthouse.test"
    result = router.execute('mutation($name: String!, $email: String!) { signUp(name: $name, email: $email) { id } }',
                            variables: { name: name, email: email })
    id = result.dig('data', 'signUp', 'id') || raise("signUp failed: #{result.inspect}")
    accounts_sql('UPDATE users SET role = $1 WHERE id = $2', [admin ? 'admin' : 'member', id])
    token = accounts_sql('SELECT api_token FROM users WHERE id = $1', [id]).first['api_token']
    { id: id, name: name, email: email, token: token }
  end

  # SQL on the accounts subgraph's database.
  def accounts_sql(sql, params = [])
    @accounts_db ||= PG.connect(dbname: 'lighthouse_federation_accounts_test')
    @accounts_db.exec_params(sql, params).to_a
  end

  # A published post by `user`, written through the router (blog's createPost).
  def write_post(user, title: "Post #{SecureRandom.hex(3)}", body: 'Lighthouse federates. ' * 30, published: true, tags: nil)
    input = { title: title, body: body, published: published }
    input[:tags] = { create: tags.map { |name| { name: name } } } if tags
    result = router(token: user[:token]).execute('mutation($input: CreatePostInput!) { createPost(input: $input) { id } }',
                                                 variables: { input: input })
    result.dig('data', 'createPost', 'id') || raise("createPost failed: #{result.inspect}")
  end

  def data(result)
    expect(result['errors']).to be_nil, -> { "unexpected errors: #{JSON.pretty_generate(result['errors'])}" }
    result['data']
  end

  def messages(result) = (result['errors'] || []).map { |error| error['message'] }
end
