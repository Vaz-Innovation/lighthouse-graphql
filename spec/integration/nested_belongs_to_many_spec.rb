# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/BelongsToManyTest.php
#
# Laravel's `pivot { meta }` field has no ActiveRecord equivalent; pivot values
# are read through the join model instead (User.rolePivots).
RSpec.describe 'Nested mutations: belongsToMany' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Role {
        id: ID!
        name: String
        users: [User!] @belongsToMany
      }

      type User {
        id: ID!
        name: String
        roles: [Role!] @belongsToMany
        rolePivots: [RoleUserPivot!]! @hasMany(relation: "role_users")
      }

      type RoleUserPivot {
        role: Role!
        meta: String
      }

      type Mutation {
        createRole(input: CreateRoleInput! @spread): Role @create
        updateRole(input: UpdateRoleInput! @spread): Role @update
        upsertRole(input: UpsertRoleInput! @spread): Role @upsert
        createUser(input: CreateUserInput! @spread): User @create
        pivotsUpdateUser(input: UpsertUserInput! @spread): User @update
      }

      input CreateRoleInput { name: String users: CreateUserRelation }
      input CreateUserRelation { create: [CreateUserInput!] upsert: [UpsertUserInput!] connect: [ID!] sync: [ID!] }
      input CreateUserInput { name: String }
      input UpdateRoleInput { id: ID! name: String users: UpdateUserRelation }
      input UpdateUserRelation {
        create: [CreateUserInput!]
        update: [UpdateUserInput!]
        upsert: [UpsertUserInput!]
        delete: [ID!]
        connect: [ID!]
        sync: [ID!]
        syncWithoutDetaching: [ID!]
        disconnect: [ID!]
      }
      input UpdateUserInput { id: ID! name: String }
      input UpsertRoleInput { id: ID name: String users: UpsertUserRelation }
      input UpsertUserRelation {
        create: [CreateUserInput!]
        update: [UpdateUserInput!]
        upsert: [UpsertUserInput!]
        delete: [ID!]
        connect: [ID!]
        sync: [ID!]
        disconnect: [ID!]
      }
      input UpsertUserInput { id: ID name: String roles: UpdateRoleRelation }
      input UpdateRoleRelation {
        sync: [UpdateUserRolePivot!]
        syncWithoutDetaching: [UpdateUserRolePivot!]
        connect: [UpdateUserRolePivot!]
      }
      input UpdateUserRolePivot { id: ID! meta: String }
    GRAPHQL
  end

  def role_mutation(action, input, selection = 'id name users { id name }')
    graphql("mutation { #{action}Role(input: #{input}) { #{selection} } }")
  end

  # Users of a role, by id: the join's row order is the database's business.
  def user_ids(result, field)
    result.dig('data', field, 'users').map { |user| user['id'] }.sort
  end

  def role_with_users(count)
    LH::Role.create!(name: 'is_admin').tap { |role| count.times { |i| role.users << LH::User.create!(name: "user#{i}") } }
  end

  it 'syncs without detaching' do
    result = graphql(<<~GRAPHQL)
      mutation {
        createUser(input: { name: "user1" }) { id }
        createRole(input: { name: "foobar", users: { create: [{ name: "user2" }] } }) { id users { id } }
        updateRole(input: { id: 1, users: { syncWithoutDetaching: [1] } }) { id users { id } }
      }
    GRAPHQL

    expect_data(result.merge('data' => result['data'].except('updateRole')),
                'createUser' => { 'id' => '1' }, 'createRole' => { 'id' => '1', 'users' => [{ 'id' => '2' }] })
    expect(user_ids(result, 'updateRole')).to eq(%w[1 2])
  end

  it 'creates with new belongsToMany models' do
    result = role_mutation(:create, '{ name: "foobar", users: { create: [{ name: "bar" }, { name: "foo" }] } }')

    expect_data(result, 'createRole' => { 'id' => '1', 'name' => 'foobar',
                                          'users' => [{ 'id' => '1', 'name' => 'bar' }, { 'id' => '2', 'name' => 'foo' }] })
  end

  it 'upserts (creating) with upserted models that do not exist, keeping their ids' do
    result = role_mutation(:upsert, '{ id: 1, name: "is_user", users: { upsert: [{ id: 10, name: "user1" }, { id: 20, name: "user2" }] } }')

    expect_data(result, 'upsertRole' => { 'id' => '1', 'name' => 'is_user',
                                          'users' => [{ 'id' => '10', 'name' => 'user1' }, { 'id' => '20', 'name' => 'user2' }] })
    expect(LH::Role.first.users.count).to eq(2)
  end

  it 'upserts belongsToMany models without ids' do
    result = role_mutation(:upsert, '{ name: "is_user", users: { upsert: [{ name: "user1" }, { name: "user2" }] } }')

    expect_data(result, 'upsertRole' => { 'id' => '1', 'name' => 'is_user',
                                          'users' => [{ 'id' => '1', 'name' => 'user1' }, { 'id' => '2', 'name' => 'user2' }] })
  end

  it 'creates and connects' do
    LH::User.create!(name: 'user_one')
    LH::User.create!(name: 'user_two')

    expect_data(role_mutation(:create, '{ name: "foobar", users: { connect: [1, 2] } }'),
                'createRole' => { 'id' => '1', 'name' => 'foobar',
                                  'users' => [{ 'id' => '1', 'name' => 'user_one' }, { 'id' => '2', 'name' => 'user_two' }] })
  end

  it 'upserts (creating) and connects' do
    LH::User.create!(name: 'user_one')
    LH::User.create!(name: 'user_two')

    expect_data(role_mutation(:upsert, '{ id: 1, name: "foobar", users: { connect: [1, 2] } }'),
                'upsertRole' => { 'id' => '1', 'name' => 'foobar',
                                  'users' => [{ 'id' => '1', 'name' => 'user_one' }, { 'id' => '2', 'name' => 'user_two' }] })
  end

  it 'updates and creates belongsToMany models' do
    LH::Role.create!(name: 'is_admin')

    result = role_mutation(:update, '{ id: 1, name: "is_user", users: { create: [{ name: "user1" }, { name: "user2" }] } }')

    expect_data(result, 'updateRole' => { 'id' => '1', 'name' => 'is_user',
                                          'users' => [{ 'id' => '1', 'name' => 'user1' }, { 'id' => '2', 'name' => 'user2' }] })
    expect(LH::Role.first.users.count).to eq(2)
  end

  it 'allows null operations' do
    LH::Role.create!(name: 'role')
    input = '{ id: 1, name: "is_user", users: { create: null, update: null, upsert: null, delete: null, connect: null, ' \
            'sync: null, syncWithoutDetaching: null, disconnect: null } }'

    expect_data(role_mutation(:update, input), 'updateRole' => { 'id' => '1', 'name' => 'is_user', 'users' => [] })
  end

  it 'updates and upserts models that do not exist yet' do
    LH::Role.create!(name: 'is_admin')

    result = role_mutation(:update, '{ id: 1, name: "is_user", users: { upsert: [{ id: 1, name: "user1" }, { id: 2, name: "user2" }] } }')

    expect_data(result, 'updateRole' => { 'id' => '1', 'name' => 'is_user',
                                          'users' => [{ 'id' => '1', 'name' => 'user1' }, { 'id' => '2', 'name' => 'user2' }] })
  end

  %w[update upsert].each do |action|
    it "#{action}s and #{action}s the attached models" do
      role_with_users(2)

      result = role_mutation(action, "{ id: 1, name: \"is_user\", users: { #{action}: [{ id: 1, name: \"user1\" }, { id: 2, name: \"user2\" }] } }")

      expect_data(result, "#{action}Role" => { 'id' => '1', 'name' => 'is_user',
                                               'users' => [{ 'id' => '1', 'name' => 'user1' }, { 'id' => '2', 'name' => 'user2' }] })
      expect(LH::Role.first.users.count).to eq(2)
    end

    it "#{action}s and deletes attached models" do
      role_with_users(2)

      expect_data(role_mutation(action, '{ id: 1, name: "is_user", users: { delete: [1] } }'),
                  "#{action}Role" => { 'id' => '1', 'name' => 'is_user', 'users' => [{ 'id' => '2', 'name' => 'user1' }] })
      expect(LH::User.find_by(id: 1)).to be_nil
      expect(LH::User.find_by(id: 2)).not_to be_nil
    end

    it "#{action}s and connects, keeping the attached models" do
      LH::User.create!(name: 'loose')
      role = LH::Role.create!(name: 'role')
      role.users << LH::User.create!(name: 'attached')

      result = role_mutation(action, '{ id: 1, users: { connect: [1] } }', 'id users { id }')

      expect(user_ids(result, "#{action}Role")).to eq(%w[1 2])
      expect(role.users.count).to eq(2)
    end

    it "#{action}s and syncs" do
      LH::User.create!(name: 'loose')
      role = LH::Role.create!(name: 'role')
      role.users << LH::User.create!(name: 'attached')

      expect(user_ids(role_mutation(action, '{ id: 1, users: { sync: [1, 2] } }', 'id users { id }'), "#{action}Role")).to eq(%w[1 2])
      expect(role.users.count).to eq(2)
    end

    it "#{action}s and disconnects, keeping the models" do
      role_with_users(2)

      expect_data(role_mutation(action, '{ id: 1, users: { disconnect: [1] } }', 'id users { id }'),
                  "#{action}Role" => { 'id' => '1', 'users' => [{ 'id' => '2' }] })
      expect(LH::User.count).to eq(2)
    end

    it "#{action}s and detaches every model on an empty sync" do
      role_with_users(1)

      expect_data(role_mutation(action, '{ id: 1, users: { sync: [] } }', 'id name users { id }'),
                  "#{action}Role" => { 'id' => '1', 'users' => [] })
      expect(LH::Role.first.users.count).to eq(0)
    end
  end

  it 'syncs existing models while creating' do
    2.times { |i| LH::User.create!(name: "user#{i}") }

    expect_data(role_mutation(:create, '{ name: "foobar", users: { sync: [1, 2] } }', 'id name users { id }'),
                'createRole' => { 'id' => '1', 'name' => 'foobar', 'users' => [{ 'id' => '1' }, { 'id' => '2' }] })
  end

  it 'syncs existing models while upserting (creating)' do
    2.times { |i| LH::User.create!(name: "user#{i}") }

    expect_data(role_mutation(:upsert, '{ id: 1, name: "foobar", users: { sync: [1, 2] } }', 'id name users { id }'),
                'upsertRole' => { 'id' => '1', 'name' => 'foobar', 'users' => [{ 'id' => '1' }, { 'id' => '2' }] })
  end

  describe 'pivot values' do
    def pivots(result)
      result.dig('data', 'pivotsUpdateUser', 'rolePivots').to_h { |pivot| [pivot.dig('role', 'id'), pivot['meta']] }
    end

    it 'syncs with pivot values, detaching the rest' do
      user = LH::User.create!(name: 'user')
      LH::Role.create!(name: 'one')
      user.roles << LH::Role.create!(name: 'two')

      query = <<~GRAPHQL
        mutation ($meta: String) {
          pivotsUpdateUser(input: { id: 1, roles: { sync: [{ id: 1, meta: $meta }, { id: 2 }] } }) { rolePivots { role { id } meta } }
        }
      GRAPHQL
      result = graphql(query, { 'meta' => 'hello' })

      expect(pivots(result)).to eq('1' => 'hello', '2' => nil)
    end

    it 'syncs without detaching, with pivot values' do
      user = LH::User.create!(name: 'user')
      LH::Role.create!(name: 'one')
      user.roles << LH::Role.create!(name: 'two')

      query = <<~GRAPHQL
        mutation ($meta: String) {
          pivotsUpdateUser(input: { id: 1, roles: { syncWithoutDetaching: [{ id: 1, meta: $meta }] } }) { rolePivots { role { id } meta } }
        }
      GRAPHQL
      result = graphql(query, { 'meta' => 'hello' })

      expect(pivots(result)).to eq('2' => nil, '1' => 'hello')
    end

    it 'connects with pivot values' do
      LH::User.create!(name: 'user')
      LH::Role.create!(name: 'one')

      query = <<~GRAPHQL
        mutation ($meta: String) {
          pivotsUpdateUser(input: { id: 1, roles: { connect: [{ id: 1, meta: $meta }] } }) { rolePivots { role { id } meta } }
        }
      GRAPHQL
      result = graphql(query, { 'meta' => 'hello' })

      expect(pivots(result)).to eq('1' => 'hello')
    end
  end
end
