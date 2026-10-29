# frozen_string_literal: true

# The filters on an input object's fields apply wherever the client sends it,
# at any depth, with no @nest: PHP Lighthouse's ResolveInfo::applyArgBuilderDirectives
# goes through the nested inputs of the arguments it is given.
RSpec.describe 'Filters on nested input fields' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users(filter: UserFilter): [User!]! @all(model: "LH::User")
        spread(filter: UserFilter @spread): [User!]! @all(model: "LH::User")
        every(filters: [UserFilter!]): [User!]! @all(model: "LH::User")
      }

      type Mutation {
        deleteUsers(filter: UserFilter): [User!]! @delete(model: "LH::User")
      }

      input UserFilter { name: String @eq, deep: UserNameFilter }
      input UserNameFilter { exactName: String @eq(key: "name") }
      input TaskFilter { name: String @eq }

      type Task { name: String }
      type User { name: String tasks(filter: TaskFilter): [Task!]! @hasMany }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl, dataloader: true) }

  before do
    %w[ada bob].each { |name| LH::User.create!(name: name).tasks.create!([{ name: "#{name} reads" }, { name: "#{name} writes" }]) }
  end

  def data(query) = schema.execute(query).to_h.fetch('data')

  it "applies the input's fields' filters, at any depth" do
    expect(data('{ users(filter: { name: "ada" }) { name } }')['users']).to eq([{ 'name' => 'ada' }])
    expect(data('{ users(filter: { deep: { exactName: "bob" } }) { name } }')['users']).to eq([{ 'name' => 'bob' }])
  end

  it 'applies them through @spread' do
    expect(data('{ spread(filter: { name: "bob" }) { name } }')['spread']).to eq([{ 'name' => 'bob' }])
  end

  it 'applies those of every input of a list, together' do
    expect(data('{ every(filters: [{ name: "ada" }]) { name } }')['every']).to eq([{ 'name' => 'ada' }])
    expect(data('{ every(filters: [{ name: "ada" }, { name: "bob" }]) { name } }')['every']).to eq([])
  end

  it 'gives a relation filtered through an input its own query, not the batched load' do
    users = data('{ users { name tasks(filter: { name: "ada writes" }) { name } } }')['users']

    expect(users.pluck('tasks')).to eq([[{ 'name' => 'ada writes' }], []])
  end

  it 'counts as a filter for @delete' do
    expect(data('mutation { deleteUsers(filter: { name: "ada" }) { name } }')['deleteUsers']).to eq([{ 'name' => 'ada' }])
    expect(LH::User.pluck(:name)).to eq(%w[bob])
    expect(schema.execute('mutation { deleteUsers(filter: {}) { name } }')['errors'].pluck('message'))
      .to eq(['Would modify all models, use an argument to filter.'])
  end
end
