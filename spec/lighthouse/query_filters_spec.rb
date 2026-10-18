# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :filter_spec_documents, force: true do |t|
    t.string :name
    t.json :tags
    t.json :meta
    t.datetime :archived_at
  end
end

class FilterSpecDocument < ApplicationRecord
  self.table_name = 'filter_spec_documents'

  scope :named, ->(name) { where(name: name) }
end

# @whereNull, @whereNotNull, @whereBetween, @whereNotBetween, @whereJsonContains,
# @scope, @whereAuth, @nest and @limit.
RSpec.describe 'Query filter directives' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        documents(
          archived: Boolean @whereNull(key: "archived_at")
          live: Boolean @whereNotNull(key: "archived_at")
          tag: String @whereJsonContains(key: "tags")
          tags: [String!] @whereJsonContains(key: "tags")
          color: String @whereJsonContains(key: "meta->colors")
          named: String @scope
          alias: String @scope(name: "named")
          filter: DocumentFilter @nest
          limit: Int @limit
        ): [Document!]! @all(model: "FilterSpecDocument")
        tasks(difficulty: IntRange @whereBetween, outside: IntRange @whereNotBetween(key: "difficulty")): [Task!]! @all(model: "LH::Task")
        myPosts: [Post!]! @all(model: "LH::Post") @whereAuth(relation: "user")
        myCompanies: [Company!]! @all(model: "LH::Company") @whereAuth(relation: "users")
        users: [User!]! @all(model: "LH::User")
      }

      input DocumentFilter { name: String @eq, nested: DocumentNameFilter @nest }
      input DocumentNameFilter { exactName: String @eq(key: "name") }
      input IntRange { from: Int! to: Int! }

      type Document { name: String }
      type Task { name: String }
      type Post { title: String }
      type Company { name: String }
      type User { name: String tasks(limit: Int @limit): [Task!]! @hasMany }
    GRAPHQL
  end

  before do
    FilterSpecDocument.delete_all
    FilterSpecDocument.create!(name: 'a', tags: %w[ruby graphql], meta: { colors: %w[red] })
    FilterSpecDocument.create!(name: 'b', tags: %w[ruby], meta: { colors: %w[blue] }, archived_at: Time.current)
    FilterSpecDocument.create!(name: 'c', tags: [], meta: {})
  end

  def names(query, field = 'documents', context: {})
    schema.execute(query, context: context).to_h.dig('data', field).pluck('name')
  end

  it '@whereNull and @whereNotNull keep the rows whose column is null, or not, and the opposite for false' do
    expect(names('{ documents(archived: true) { name } }')).to eq(%w[a c])
    expect(names('{ documents(archived: false) { name } }')).to eq(%w[b])
    expect(names('{ documents(live: true) { name } }')).to eq(%w[b])
  end

  it '@whereJsonContains keeps the rows whose JSON holds the value, every value of a list, or at a path' do
    expect(names('{ documents(tag: "graphql") { name } }')).to eq(%w[a])
    expect(names('{ documents(tags: ["ruby", "graphql"]) { name } }')).to eq(%w[a])
    expect(names('{ documents(color: "blue") { name } }')).to eq(%w[b])
  end

  it '@scope calls the model scope with the value, the argument name or the one given' do
    expect(names('{ documents(named: "b") { name } }')).to eq(%w[b])
    expect(names('{ documents(alias: "c") { name } }')).to eq(%w[c])
  end

  it "@nest applies the filters of the input's fields, at any depth" do
    expect(names('{ documents(filter: { name: "a" }) { name } }')).to eq(%w[a])
    expect(names('{ documents(filter: { nested: { exactName: "c" } }) { name } }')).to eq(%w[c])
  end

  it '@whereBetween and @whereNotBetween compare with the input fields, in order' do
    [1, 5, 9].each { |d| LH::Task.create!(name: "t#{d}", difficulty: d) }

    expect(names('{ tasks(difficulty: { from: 2, to: 9 }) { name } }', 'tasks')).to eq(%w[t5 t9])
    expect(names('{ tasks(outside: { from: 2, to: 6 }) { name } }', 'tasks')).to eq(%w[t1 t9])
  end

  it "@whereAuth keeps the signed-in user's records, through a belongs_to or a has_many, and none for a guest" do
    ada = LH::User.create!(name: 'ada')
    LH::Post.create!(title: 'mine', user: ada)
    LH::Post.create!(title: 'theirs', user: LH::User.create!(name: 'bob'))
    LH::Company.create!(name: 'ours').users << ada
    LH::Company.create!(name: 'other')

    expect(schema.execute('{ myPosts { title } }', context: { current_user: ada }).to_h.dig('data', 'myPosts')).to eq([{ 'title' => 'mine' }])
    expect(names('{ myCompanies { name } }', 'myCompanies', context: { current_user: ada })).to eq(%w[ours])
    expect(names('{ myCompanies { name } }', 'myCompanies')).to eq([])
  end

  describe '@limit' do
    it "caps a field's results at the client's value" do
      expect(names('{ documents(limit: 2) { name } }')).to eq(%w[a b])
      expect(names('{ documents { name } }')).to eq(%w[a b c])
    end

    it "cuts each parent's records of a relation on its own" do
      2.times { |u| LH::User.create!(name: "u#{u}").tap { |user| 3.times { |t| LH::Task.create!(name: "t#{u}#{t}", user: user) } } }

      result = schema.execute('{ users { tasks(limit: 2) { name } } }').to_h.dig('data', 'users')
      expect(result.map { |user| user['tasks'].pluck('name') }).to eq([%w[t00 t01], %w[t10 t11]])
    end

    it 'refuses a negative limit' do
      expect(schema.execute('{ documents(limit: -1) { name } }').to_h['errors'].pluck('message')).to eq(['The limit must be positive, got -1.'])
    end
  end
end
