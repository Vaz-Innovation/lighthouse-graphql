# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/HasManyTest.php
RSpec.describe 'Nested mutations: hasMany' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task {
        id: ID!
        name: String!
      }

      type User {
        id: ID!
        name: String
        tasks: [Task!]! @hasMany
      }

      type Mutation {
        createUser(input: CreateUserInput! @spread): User @create
        updateUser(input: UpdateUserInput! @spread): User @update
        upsertUser(input: UpsertUserInput! @spread): User @upsert
      }

      input CreateUserInput { name: String tasks: CreateTaskRelation }
      input CreateTaskRelation { create: [CreateTaskInput!] upsert: [UpsertTaskInput!] connect: [ID!] }
      input CreateTaskInput { name: String }
      input UpdateUserInput { id: ID! name: String tasks: UpdateTaskRelation }
      input UpdateTaskRelation {
        create: [CreateTaskInput!]
        update: [UpdateTaskInput!]
        upsert: [UpsertTaskInput!]
        delete: [ID!]
        connect: [ID!]
        disconnect: [ID!]
      }
      input UpdateTaskInput { id: ID! name: String }
      input UpsertUserInput { id: ID name: String tasks: UpsertTaskRelation }
      input UpsertTaskRelation {
        create: [CreateTaskInput!]
        update: [UpdateTaskInput!]
        upsert: [UpsertTaskInput!]
        delete: [ID!]
        connect: [ID!]
        disconnect: [ID!]
      }
      input UpsertTaskInput { id: ID name: String }
    GRAPHQL
  end

  def user_mutation(action, input, variables = {})
    if input.is_a?(Hash)
      return graphql("mutation ($input: #{action.to_s.capitalize}UserInput!) { #{action}User(input: $input) { id name tasks { id name } } }",
                     { 'input' => input }.merge(variables))
    end

    graphql("mutation { #{action}User(input: #{input}) { id name tasks { id name } } }")
  end

  def user_with_task
    LH::User.create!(name: 'user').tap { |user| LH::Task.create!(name: 'task', user: user) }
  end

  it 'creates with a new hasMany' do
    expect_data(user_mutation(:create, '{ name: "foo", tasks: { create: [{ name: "bar" }] } }'),
                'createUser' => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
  end

  it 'creates and connects existing models' do
    first = LH::Task.create!(name: 'one')
    second = LH::Task.create!(name: 'two')

    expect_data(user_mutation(:create, { 'name' => 'foo', 'tasks' => { 'connect' => [first.id, second.id] } }),
                'createUser' => { 'name' => 'foo', 'tasks' => [{ 'id' => first.id.to_s, 'name' => 'one' },
                                                               { 'id' => second.id.to_s, 'name' => 'two' }] })
  end

  it 'allows null operations' do
    LH::User.create!(name: 'user')

    expect_data(user_mutation(:update, '{ id: 1, name: "foo", tasks: { create: null, update: null, upsert: null, delete: null } }'),
                'updateUser' => { 'name' => 'foo', 'tasks' => [] })
  end

  it 'creates with an upserted hasMany' do
    expect_data(user_mutation(:create, '{ name: "foo", tasks: { upsert: [{ id: 1, name: "bar" }] } }'),
                'createUser' => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
  end

  it 'upserts a hasMany without an id' do
    expect_data(user_mutation(:upsert, '{ name: "foo", tasks: { upsert: [{ name: "bar" }] } }'),
                'upsertUser' => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
  end

  it 'upserts (creating) with an upserted hasMany' do
    expect_data(user_mutation(:upsert, '{ id: 1, name: "foo", tasks: { upsert: [{ id: 1, name: "bar" }] } }'),
                'upsertUser' => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
  end

  %w[update upsert].each do |action|
    it "#{action}s and creates hasMany models" do
      LH::User.create!(name: 'user')

      expect_data(user_mutation(action, '{ id: 1, name: "foo", tasks: { create: [{ name: "bar" }] } }'),
                  "#{action}User" => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
    end

    it "#{action}s and updates hasMany models" do
      user_with_task

      expect_data(user_mutation(action, '{ id: 1, name: "foo", tasks: { update: [{ id: 1, name: "bar" }] } }'),
                  "#{action}User" => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
    end

    it "#{action}s and upserts hasMany models" do
      user_with_task

      expect_data(user_mutation(action, '{ id: 1, name: "foo", tasks: { upsert: [{ id: 1, name: "bar" }] } }'),
                  "#{action}User" => { 'id' => '1', 'name' => 'foo', 'tasks' => [{ 'id' => '1', 'name' => 'bar' }] })
    end

    it "#{action}s and deletes hasMany models" do
      user_with_task

      expect_data(user_mutation(action, '{ id: 1, name: "foo", tasks: { delete: [1] } }'),
                  "#{action}User" => { 'id' => '1', 'name' => 'foo', 'tasks' => [] })
      expect(LH::Task.count).to eq(0)
    end

    it "#{action}s and connects existing models" do
      user = LH::User.create!(name: 'user')
      first = LH::Task.create!(name: 'one')
      second = LH::Task.create!(name: 'two')

      expect_data(user_mutation(action, { 'id' => user.id, 'name' => 'foo', 'tasks' => { 'connect' => [first.id, second.id] } }),
                  "#{action}User" => { 'id' => user.id.to_s, 'name' => 'foo',
                                       'tasks' => [{ 'id' => first.id.to_s, 'name' => 'one' }, { 'id' => second.id.to_s, 'name' => 'two' }] })
    end

    it "#{action}s and disconnects hasMany models, keeping the others" do
      user = LH::User.create!(name: 'user')
      gone = LH::Task.create!(name: 'gone', user: user)
      kept = LH::Task.create!(name: 'kept', user: user)

      expect_data(user_mutation(action, { 'id' => user.id, 'name' => 'foo', 'tasks' => { 'disconnect' => [gone.id] } }),
                  "#{action}User" => { 'id' => user.id.to_s, 'name' => 'foo', 'tasks' => [{ 'id' => kept.id.to_s, 'name' => 'kept' }] })
      expect(gone.reload.user).to be_nil
    end
  end

  it 'updates a nested model that belonged to no one, attaching it (as PHP Lighthouse does)' do
    user = LH::User.create!(name: 'user')
    task = LH::Task.create!(name: 'loose')

    expect_data(user_mutation(:update, { 'id' => user.id, 'name' => 'foo', 'tasks' => { 'update' => [{ 'id' => task.id, 'name' => 'bar' }] } }),
                'updateUser' => { 'id' => user.id.to_s, 'name' => 'foo', 'tasks' => [{ 'id' => task.id.to_s, 'name' => 'bar' }] })
  end

  describe 'connecting models with a custom primary key' do
    let(:sdl) do
      <<~GRAPHQL
        type Query { user: User @first }
        type CustomPrimaryKey { custom_primary_key_id: ID! }
        type User { id: ID! name: String customPrimaryKeys: [CustomPrimaryKey!] @hasMany }
        type Mutation {
          createUser(input: CreateUserInput! @spread): User @create
          updateUser(input: UpdateUserInput! @spread): User @update
        }
        input CreateUserInput { name: String customPrimaryKeys: UpdateCustomPrimaryKeyHasMany }
        input UpdateUserInput { id: ID! name: String customPrimaryKeys: UpdateCustomPrimaryKeyHasMany }
        input UpdateCustomPrimaryKeyHasMany { connect: [ID!] disconnect: [ID!] }
      GRAPHQL
    end

    it 'connects and disconnects them by that key' do
      3.times { LH::CustomPrimaryKey.create! }

      created = graphql(<<~GRAPHQL)
        mutation {
          createUser(input: { name: "foo", customPrimaryKeys: { connect: [1, 2, 3] } }) { id customPrimaryKeys { custom_primary_key_id } }
        }
      GRAPHQL
      expect_data(created, 'createUser' => { 'id' => '1', 'customPrimaryKeys' => [{ 'custom_primary_key_id' => '1' },
                                                                                  { 'custom_primary_key_id' => '2' },
                                                                                  { 'custom_primary_key_id' => '3' }] })

      updated = graphql(<<~GRAPHQL)
        mutation {
          updateUser(input: { id: 1, customPrimaryKeys: { disconnect: [2] } }) { customPrimaryKeys { custom_primary_key_id } }
        }
      GRAPHQL
      expect_data(updated, 'updateUser' => { 'customPrimaryKeys' => [{ 'custom_primary_key_id' => '1' }, { 'custom_primary_key_id' => '3' }] })
    end
  end

  describe 'upserting across a pivot table' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type User { id: ID! name: String! roles: [Role!] @belongsToMany }
        type Role { id: ID! name: String! }
        type Mutation { upsertUser(input: UpsertUserInput! @spread): User @upsert }
        input UpsertUserInput { id: ID name: String! roles: UpsertRolesHasMany }
        input UpsertRolesHasMany { upsert: [UpsertRoleInput!] }
        input UpsertRoleInput { id: ID name: String! users: UpsertRoleUsersRelation }
        input UpsertRoleUsersRelation { sync: [ID!] }
      GRAPHQL
    end

    it 'overrides the existing model, moving the role to another user' do
      expect_data(graphql('mutation { upsertUser(input: { name: "foo", roles: { upsert: [{ name: "bar" }] } }) { id name roles { id name } } }'),
                  'upsertUser' => { 'id' => '1', 'name' => 'foo', 'roles' => [{ 'id' => '1', 'name' => 'bar' }] })
      role = LH::Role.first
      expect(role.users.pluck(:id)).to eq([1])
      LH::User.create!(name: 'other')

      result = graphql(<<~GRAPHQL)
        mutation {
          upsertUser(input: { id: "1", name: "fooz", roles: { upsert: [{ id: "1", name: "baz", users: { sync: ["2"] } }] } }) {
            id name roles { id name }
          }
        }
      GRAPHQL

      expect_data(result, 'upsertUser' => { 'id' => '1', 'name' => 'fooz', 'roles' => [] })
      expect(role.users.reload.pluck(:id)).to eq([2])
    end
  end
end
