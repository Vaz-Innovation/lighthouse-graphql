# frozen_string_literal: true

require 'spec_helper'

# A filter that raises (an argument directive, a @builder, @whereAuth) fails the
# field with a client error, reported to Config.on_error: never the unfiltered rows.
class Builders::FilterErrorsSpecBroken
  def self.call(_target, _value, _context) = raise('the builder broke')
end

# One a resolver of the app's own applies through enhance_builder.
class FilterErrorsSpecEnhanced
  def self.call(_obj, _args, _ctx, resolve_info) = resolve_info.enhance_builder(Post.all).to_a
end

RSpec.describe 'a filter that raises' do
  let(:reported) { [] }
  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Post { id: ID! title: String! }
      type SearchPost { id: ID! related(only: String @builder(class: "FilterErrorsSpecBroken")): [SearchPost!]! @hasMany }
      type Query {
        byField: [Post!]! @all @builder(class: "FilterErrorsSpecBroken")
        byArgument(only: String @builder(class: "FilterErrorsSpecBroken")): [Post!]! @all
        byScope(boom: Boolean @scope(name: "no_such_scope")): [Post!]! @paginate
        byOwner: [SearchPost!]! @all @whereAuth(relation: "related")
        counted(only: String @builder(class: "FilterErrorsSpecBroken")): Int! @count(model: "Post")
        first(only: String @builder(class: "FilterErrorsSpecBroken")): Post @first
        enhanced(only: String @builder(class: "FilterErrorsSpecBroken")): [Post!]! @field(resolver: "FilterErrorsSpecEnhanced")
        searchPosts: [SearchPost!]! @all
        misspelt(authorId: ID @eq(key: "auhtor_id")): [Post!]! @paginate
      }
      type Mutation { deletePosts(only: String @builder(class: "FilterErrorsSpecBroken")): [Post!]! @delete }
    GRAPHQL
  end
  # The app's own mapping of errors, as graphql-ruby's rescue_from.
  let(:mapped) { Class.new(schema) { rescue_from(StandardError) { |error, *| raise GraphQL::ExecutionError, "mapped: #{error.message}" } } }
  let(:queries) do
    {
      'byField' => '{ byField { title } }',
      'byArgument' => '{ byArgument(only: "x") { title } }',
      'byScope' => '{ byScope(first: 10, boom: true) { data { title } } }',
      'byOwner' => '{ byOwner { id } }',
      'counted' => '{ counted(only: "x") }',
      'first' => '{ first(only: "x") { title } }',
      'enhanced' => '{ enhanced(only: "x") { title } }',
      'related' => '{ searchPosts { related(only: "x") { id } } }'
    }
  end

  before do
    Lighthouse::Config.on_error = ->(error, _context) { reported << error.message }
    Post.create!(title: 'one')
    Post.create!(title: 'two')
    SearchPost.create!(title: 'parent', author_id: nil)
  end

  def run(query, context = {}, on: schema) = on.execute(query, context: context).to_h

  it 'fails the field with the error itself, reported, rather than answer the rows the filter would have left out' do
    queries.each_value do |query|
      expect { run(query, { current_user: Object.new }) }.to raise_error(StandardError) { |error| expect(error).not_to be_a(ArgumentError) }
    end
    expect(reported.size).to eq(queries.size)
  end

  it "lets the schema's rescue_from map it, as any error of a resolver" do
    queries.each do |field, query|
      result = run(query, { current_user: Object.new }, on: mapped)

      expect(result['data']&.dig(field)).to be_nil, field
      expect(result['errors'].first['message']).to start_with('mapped: '), field
    end
  end

  it 'modifies nothing on a mass mutation' do
    expect { run('mutation { deletePosts(only: "x") { id } }') }.to raise_error(RuntimeError, 'the builder broke')
    expect(Post.count).to eq(2)
  end

  it 'never skips a @builder it cannot find, which would answer every row: the schema error is the client\'s, and reported' do
    missing = build_schema('type Post { id: ID! } type Query { posts: [Post!]! @all @builder(class: "NoSuchBuilder") }')

    expect(missing.execute('{ posts { id } }').to_h['errors'].pluck('message')).to eq(['@builder: no builder "NoSuchBuilder".'])
    expect(reported).to eq(['@builder: no builder "NoSuchBuilder".'])
  end

  it 'never answers the rows of a query the database refuses: a misspelt column fails as it runs' do
    expect { run('{ misspelt(first: 10, authorId: 1) { data { id } } }') }.to raise_error(ActiveRecord::StatementInvalid, /auhtor_id/)
  end
end
