# frozen_string_literal: true

# `scopes:` narrows the query of every directive that builds one, as in PHP Lighthouse.
RSpec.describe 'scopes:' do
  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Query {
        all: [Post!]! @all(scopes: ["published"])
        first: Post @first(scopes: ["published"])
        count: Int! @count(model: "Post", scopes: ["published"])
        page: [Post!]! @paginate(scopes: ["published"])
        find(id: ID! @eq): Post @find(scopes: ["published"])
      }

      type Post { id: ID! title: String }
    GRAPHQL
  end

  let!(:draft) { Post.create!(title: 'Draft', published: false) }
  let!(:published) { Post.create!(title: 'Out', published: true) }

  def data(query)
    result = schema.execute(query).to_h
    raise result['errors'].inspect if result['errors']

    result['data']
  end

  it 'applies to @all, @first, @count, @paginate and @find' do
    expect(data('{ all { title } first { title } count page(first: 10) { data { title } } }')).to eq(
      'all' => [{ 'title' => 'Out' }], 'first' => { 'title' => 'Out' }, 'count' => 1, 'page' => { 'data' => [{ 'title' => 'Out' }] }
    )
    expect(data("{ find(id: #{draft.id}) { title } }")).to eq('find' => nil)
    expect(data("{ find(id: #{published.id}) { title } }")).to eq('find' => { 'title' => 'Out' })
  end
end
