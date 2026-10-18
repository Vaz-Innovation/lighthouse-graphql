# frozen_string_literal: true

# A field's @builder applies after its argument directives, as PHP Lighthouse's
# field builder directives do (ResolveInfo::enhanceBuilder), on root and
# relationship fields alike.
RSpec.describe 'field builders after argument builders' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users(orderBy: _ @orderBy(columns: ["name"])): [User!]! @all @builder(method: "ByEmail@call")
      }

      type User {
        name: String
        tasks: [Task!]! @hasMany @builder(method: "Hard@call")
      }

      type Task { name: String }
    GRAPHQL
  end

  before do
    stub_const('Builders::ByEmail', Class.new { def self.call(relation, _args, _ctx) = relation.order(:email) })
    stub_const('Builders::Hard', Class.new { def self.call(relation, _args, _ctx) = relation.where(difficulty: 5..) })
    ada = LH::User.create!(name: 'Ada', email: 'b@x.io')
    LH::User.create!(name: 'Ada', email: 'a@x.io')
    LH::User.create!(name: 'Alan', email: 'c@x.io')
    LH::Task.create!(name: 'easy', difficulty: 1, user: ada)
    LH::Task.create!(name: 'hard', difficulty: 9, user: ada)
  end

  it "orders by the client's clauses first, the builder's after" do
    result = nil
    sql = queries_in { result = graphql('{ users(orderBy: [{ column: NAME, order: DESC }]) { name } }') }

    expect(result.dig('data', 'users').pluck('name')).to eq(%w[Alan Ada Ada])
    expect(sql.join).to match(/ORDER BY "lh_users"."name" DESC, "lh_users"."email" ASC/)
  end

  it "applies a relationship field's builder" do
    result = graphql('{ users { name tasks { name } } }')

    expect(result.dig('data', 'users').flat_map { |user| user['tasks'] }).to eq([{ 'name' => 'hard' }])
  end
end
