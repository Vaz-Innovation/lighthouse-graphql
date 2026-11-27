# frozen_string_literal: true

# A type class's scope_items on the records a field reaches through an
# interface or a union: the type each record resolves as is the one whose
# scope applies, whatever abstract type the field returns.
RSpec.describe "A type class's scope_items through interfaces and unions" do
  let(:schema) do
    build_schema(<<~GRAPHQL, dataloader: true)
      type Query {
        authored: [TaAuthored!]! @all(model: "TypeAuthPost")
        pagedAuthored: [TaAuthored!]! @paginate(model: "TypeAuthPost")
        authoredById(id: ID! @eq): TaAuthored @find(model: "TypeAuthPost")
        users: [TaUser!]! @all(model: "TypeAuthUser")
        comments: [TaComment!]! @all(model: "TypeAuthComment")
      }

      interface TaAuthored { id: ID! }
      union TaSearchable = TaPost | TaUser

      type TaUser @model(class: "TypeAuthUser") {
        name: String
        authored: [TaAuthored!]! @hasMany(relation: "posts")
      }
      type TaComment @model(class: "TypeAuthComment") {
        body: String
        target: TaSearchable @belongsTo(relation: "post")
      }
      type TaPost implements TaAuthored @model(class: "TypeAuthPost") { id: ID! title: String }
    GRAPHQL
  end

  let!(:ada) { TypeAuthUser.create!(name: 'Ada') }
  let!(:live) { TypeAuthPost.create!(title: 'Live', published: true, author_id: ada.id) }
  let!(:draft) { TypeAuthPost.create!(title: 'Draft', published: false, author_id: ada.id) }

  before { [live, draft].each { |post| TypeAuthComment.create!(body: "On #{post.title}", post_id: post.id) } }

  after { [TypeAuthComment, TypeAuthPost, TypeAuthUser].each(&:delete_all) }

  def run(query, variables = {})
    result = schema.execute(query, variables: variables, context: { current_user: nil })
    expect(result['errors']).to be_nil, -> { result['errors'].inspect }
    result['data']
  end

  def titles(items) = items.map { |item| item&.dig('title') }

  it 'scopes a root list of an interface' do
    expect(titles(run('{ authored { ... on TaPost { title } } }')['authored'])).to eq(['Live'])
  end

  it 'scopes a page of an interface, and its total' do
    page = run('{ pagedAuthored(first: 10) { paginatorInfo { total } data { ... on TaPost { title } } } }')['pagedAuthored']

    expect([page['paginatorInfo']['total'], titles(page['data'])]).to eq([1, ['Live']])
  end

  it 'finds no hidden record by id through an interface' do
    found = run('query($id: ID!) { authoredById(id: $id) { ... on TaPost { title } } }', id: draft.id)

    expect(found['authoredById']).to be_nil
  end

  it 'scopes a relationship that returns an interface' do
    users = run('{ users { name authored { ... on TaPost { title } } } }')['users']

    expect(titles(users.first['authored'])).to eq(['Live'])
  end

  it 'scopes a relationship that returns a union' do
    comments = run('{ comments { body target { ... on TaPost { title } } } }')['comments']

    expect(comments.to_h { |c| [c['body'], c.dig('target', 'title')] }).to eq('On Live' => 'Live', 'On Draft' => nil)
  end

  it 'scopes an entity looked up through an entity interface' do
    subgraph = build_subgraph(<<~GRAPHQL, dataloader: true)
      type Query { posts: [TaPost!]! @all(model: "TypeAuthPost") }
      interface TaAuthored @key(fields: "id") { id: ID! }
      type TaPost implements TaAuthored @model(class: "TypeAuthPost") @key(fields: "id") { id: ID! title: String }
    GRAPHQL
    query = 'query($r: [_Any!]!) { _entities(representations: $r) { ... on TaPost { title } } }'
    representations = [{ __typename: 'TaAuthored', id: live.id.to_s }, { __typename: 'TaAuthored', id: draft.id.to_s }]

    result = subgraph.execute(query, variables: { r: representations }, context: { current_user: nil })

    expect(result['errors']).to be_nil, -> { result['errors'].inspect }
    expect(result['data']['_entities']).to eq([{ 'title' => 'Live' }, nil])
  end
end
