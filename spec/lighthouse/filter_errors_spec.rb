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

  before do
    Lighthouse::Config.on_error = ->(error, _context) { reported << error.message }
    Post.create!(title: 'one')
    Post.create!(title: 'two')
    SearchPost.create!(title: 'parent', author_id: nil)
  end

  def run(query, context = {}) = schema.execute(query, context: context).to_h

  it 'fails the field, reported, rather than answer the rows the filter would have left out' do
    {
      'byField' => '{ byField { title } }',
      'byArgument' => '{ byArgument(only: "x") { title } }',
      'byScope' => '{ byScope(first: 10, boom: true) { data { title } } }',
      'byOwner' => '{ byOwner { id } }',
      'counted' => '{ counted(only: "x") }',
      'first' => '{ first(only: "x") { title } }',
      'enhanced' => '{ enhanced(only: "x") { title } }'
    }.each do |field, query|
      result = run(query, current_user: Object.new)

      expect(result['data']&.dig(field)).to be_nil, field
      expect(result['errors'].pluck('message')).to eq(["Could not apply the filters of Query.#{field}."]), field
    end
    expect(reported.size).to eq(7)
  end

  it 'fails a nested field the same way, for each parent' do
    result = run('{ searchPosts { related(only: "x") { id } } }')

    expect(result['errors'].pluck('message')).to eq(['Could not apply the filters of SearchPost.related.'])
    expect(reported).to eq(['the builder broke'])
  end

  it 'modifies nothing on a mass mutation' do
    result = run('mutation { deletePosts(only: "x") { id } }')

    expect(result['errors'].pluck('message')).to eq(['Could not apply the filters of Mutation.deletePosts.'])
    expect(Post.count).to eq(2)
  end

  it 'never skips a @builder it cannot find, which would answer every row' do
    missing = build_schema('type Post { id: ID! } type Query { posts: [Post!]! @all @builder(class: "NoSuchBuilder") }')

    expect { missing.execute('{ posts { id } }').to_h }.to raise_error(Lighthouse::DefinitionError, /@builder: no builder "NoSuchBuilder"/)
  end

  it 'never answers the rows of a query the database refuses: a misspelt column fails as it runs' do
    expect { run('{ misspelt(first: 10, authorId: 1) { data { id } } }') }.to raise_error(ActiveRecord::StatementInvalid, /auhtor_id/)
  end
end
