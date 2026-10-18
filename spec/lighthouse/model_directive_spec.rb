# frozen_string_literal: true

# @model(class:): a type named otherwise than its model.
RSpec.describe '@model' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        articles: [Article!]! @all
        page: [Article!]! @paginate
        article(id: ID! @eq): Article @find
        firstArticle: Article @first
        posts: [Article!]! @all(model: "Widget")
      }

      type Mutation {
        createArticle(title: String!): Article! @create
        updateArticle(id: ID!, title: String): Article @update
      }

      type Article @model(class: "Post") { id: ID! title: String }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }
  let!(:post_record) { Post.create!(title: 'Hello') }

  def run(query) = schema.execute(query).to_h

  it 'gives the model to the directives of fields returning the type' do
    result = run(<<~GRAPHQL)
      {
        articles { title }
        page(first: 5) { data { title } paginatorInfo { total } }
        article(id: #{post_record.id}) { title }
        firstArticle { title }
      }
    GRAPHQL

    expect(result['data']).to eq('articles' => [{ 'title' => 'Hello' }],
                                 'page' => { 'data' => [{ 'title' => 'Hello' }], 'paginatorInfo' => { 'total' => 1 } },
                                 'article' => { 'title' => 'Hello' }, 'firstArticle' => { 'title' => 'Hello' })
  end

  it 'gives it to mutations too' do
    run('mutation { createArticle(title: "New") { id } }')
    run(%(mutation { updateArticle(id: #{post_record.id}, title: "Renamed") { title } }))

    expect(Post.order(:id).pluck(:title)).to eq(%w[Renamed New])
  end

  it "leaves a directive's own model: alone" do
    Widget.create!(name: 'w') if defined?(Widget)

    expect(schema.query.fields['posts'].ast_node.directives.first.arguments.map(&:value)).to eq(['Widget'])
  end

  it 'refuses a @model naming no ActiveRecord model when the schema is built' do
    expect { build_schema('type Query { x: Thing } type Thing @model(class: "Nope") { id: ID }') }
      .to raise_error(Lighthouse::DefinitionError, /@model\(class: "Nope"\) on Thing names no ActiveRecord model/)
  end
end
