# frozen_string_literal: true

require 'spec_helper'

# @whereAuth keeps the records of the signed-in user, through every resolver that
# runs a field's filters: each must hand it the query's context.
class WhereAuthSpecEnhanced
  def self.call(_obj, _args, _ctx, resolve_info) = resolve_info.enhance_builder(SafetyPlainPost.all).to_a
end

RSpec.describe '@whereAuth through every resolver' do
  let(:schema) do
    build_schema(<<~GRAPHQL, dataloader: true)
      type SafetyPlainPost { id: ID! title: String! mine: [SafetyPlainPost!]! @hasMany(relation: "written") @whereAuth(relation: "author") }
      type Query {
        found(id: ID!): SafetyPlainPost @find @whereAuth(relation: "author")
        foundByTitle(title: String! @eq): SafetyPlainPost @find @whereAuth(relation: "author")
        first(title: String @eq): SafetyPlainPost @first @whereAuth(relation: "author")
        all: [SafetyPlainPost!]! @all @whereAuth(relation: "author")
        paged: [SafetyPlainPost!]! @paginate @whereAuth(relation: "author")
        counted: Int! @count(model: "SafetyPlainPost") @whereAuth(relation: "author")
        summed: Int @aggregate(function: "COUNT", model: "SafetyPlainPost") @whereAuth(relation: "author")
        enhanced: [SafetyPlainPost!]! @field(resolver: "WhereAuthSpecEnhanced") @whereAuth(relation: "author")
        root(id: ID! @eq): SafetyPlainPost @find
      }
      type Mutation { deleteMine(title: String @eq): [SafetyPlainPost!]! @delete @whereAuth(relation: "author") }
    GRAPHQL
  end
  let(:user) { SafetyPlainPost.unscoped.create!(title: 'user', author_id: nil) }
  let!(:own) { SafetyPlainPost.unscoped.create!(title: 'own', author_id: user.id) }
  let!(:others) { SafetyPlainPost.unscoped.create!(title: 'others', author_id: user.id + 1000) }

  def run(query) = schema.execute(query, context: { current_user: user }).to_h['data']

  it "finds only the user's own record, by id or by a filter" do
    expect([run("{ found(id: #{own.id}) { title } }"), run("{ found(id: #{others.id}) { title } }")])
      .to eq([{ 'found' => { 'title' => 'own' } }, { 'found' => nil }])
    expect([run('{ foundByTitle(title: "own") { title } }'), run('{ foundByTitle(title: "others") { title } }')])
      .to eq([{ 'foundByTitle' => { 'title' => 'own' } }, { 'foundByTitle' => nil }])
  end

  it "keeps the user's own records in every other resolver" do
    expect(run('{ first(title: "own") { title } }')).to eq('first' => { 'title' => 'own' })
    expect(run('{ all { title } }')).to eq('all' => [{ 'title' => 'own' }])
    expect(run('{ paged(first: 10) { data { title } } }')).to eq('paged' => { 'data' => [{ 'title' => 'own' }] })
    expect(run('{ counted summed }')).to eq('counted' => 1, 'summed' => 1)
    expect(run('{ enhanced { title } }')).to eq('enhanced' => [{ 'title' => 'own' }])
    expect(run("{ root(id: #{user.id}) { mine { title } } }")).to eq('root' => { 'mine' => [{ 'title' => 'own' }] })
  end

  it "modifies only the user's own records" do
    run('mutation { deleteMine(title: "others") { id } }')

    expect(SafetyPlainPost.unscoped.exists?(others.id)).to be(true)
  end
end
