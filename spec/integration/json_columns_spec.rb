# frozen_string_literal: true

# A column with a path into its JSON document (`meta->rank`), as PHP
# Lighthouse's @whereConditions and @orderBy take Laravel's: compared as the
# value is (numbers as numbers), and ordered by. The example app's
# real_backends_spec runs the same on PostgreSQL and MySQL.
RSpec.describe 'JSON columns in @whereConditions and @orderBy' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts(
          where: _ @whereConditions(columns: ["title", "meta->series", "meta->rank", "meta->featured", "meta->author->name"])
          orderBy: _ @orderBy(columns: ["meta->rank", "title"])
        ): [Post!]! @all
        anyPosts(where: _ @whereConditions, orderBy: _ @orderBy): [Post!]! @all(model: "Post")
        rankedPosts: [Post!]! @all(model: "Post") @orderBy(column: "meta->rank", direction: DESC)
        authors(where: _ @whereConditions): [User!]! @all(model: "User")
      }

      type Post { title: String }
      type User { name: String }
    GRAPHQL
  end

  before do
    ada = LH::User.create!(name: 'Ada')
    LH::User.create!(name: 'Alan')
    LH::Post.create!(title: 'A', user: ada, meta: { series: 'graphql', rank: 10, featured: true, author: { name: 'Ada' }, tags: %w[x y] })
    LH::Post.create!(title: 'B', meta: { series: 'rails', rank: 9, featured: false, author: { name: 'Bob' } })
    LH::Post.create!(title: 'C', meta: { rank: 100, series: nil })
    LH::Post.create!(title: 'D', meta: nil)
  end

  def titles(field, arguments = nil)
    result = graphql("{ #{field}#{"(#{arguments})" if arguments} { title } }")
    raise result['errors'].inspect if result['errors']

    result.dig('data', field).pluck('title')
  end

  it 'names a JSON path in the generated column enum' do
    expect(schema.types['QueryPostsWhereColumn'].values.transform_values(&:value))
      .to include('META__RANK' => 'meta->rank', 'META__AUTHOR__NAME' => 'meta->author->name')
  end

  it 'compares the value at the path: text, numbers as numbers, booleans, nested keys' do
    expect(titles('posts', 'where: { column: META__SERIES, value: "graphql" }')).to eq(['A'])
    expect(titles('posts', 'where: { column: META__RANK, operator: GT, value: 9 }')).to contain_exactly('A', 'C')
    expect(titles('posts', 'where: { column: META__RANK, operator: BETWEEN, value: [9, 10] }')).to contain_exactly('A', 'B')
    expect(titles('posts', 'where: { column: META__RANK, operator: IN, value: [9, 100] }')).to contain_exactly('B', 'C')
    expect(titles('posts', 'where: { column: META__FEATURED, value: true }')).to eq(['A'])
    expect(titles('posts', 'where: { column: META__AUTHOR__NAME, operator: LIKE, value: "A%" }')).to eq(['A'])
  end

  it 'takes a missing path or a JSON null as null' do
    expect(titles('posts', 'where: { column: META__SERIES, operator: IS_NULL }')).to contain_exactly('C', 'D')
    expect(titles('posts', 'where: { column: META__SERIES, operator: IS_NOT_NULL }')).to contain_exactly('A', 'B')
  end

  it 'orders by the value at the path, numbers numerically' do
    expect(titles('posts', 'where: { column: META__RANK, operator: IS_NOT_NULL }, orderBy: [{ column: META__RANK, order: DESC }]'))
      .to eq(%w[C A B])
    expect(titles('rankedPosts')).to eq(%w[C A B D]) # SQLite orders NULL last when descending
  end

  it 'takes a JSON path, an array index and a table on an unrestricted input' do
    expect(titles('anyPosts', 'where: { column: "meta->tags->0", value: "x" }')).to eq(['A'])
    expect(titles('anyPosts', 'where: { column: "lh_posts.meta->series", value: "rails" }, orderBy: [{ column: "meta->rank", order: ASC }]'))
      .to eq(['B'])
  end

  it 'filters related records on their JSON columns with HAS' do
    result = graphql('{ authors(where: { HAS: { relation: "posts", condition: { column: "meta->rank", operator: GTE, value: 10 } } }) { name } }')

    expect(result.dig('data', 'authors')).to eq([{ 'name' => 'Ada' }])
  end

  it 'rejects a path that is not made of keys' do
    expect(error_messages(graphql(%({ anyPosts(where: { column: "meta->'x'", value: 1 }) { title } }))).first)
      .to start_with('Column names may contain only alphanumerics or underscores')
  end
end
