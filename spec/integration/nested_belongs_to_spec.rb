# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/BelongsToTest.php
RSpec.describe 'Nested mutations: belongsTo' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task {
        id: ID!
        name: String!
        user: User @belongsTo
      }

      type User {
        id: ID!
        name: String!
      }

      type Mutation {
        createTask(input: CreateTaskInput! @spread): Task @create
        updateTask(input: UpdateTaskInput! @spread): Task @update
        upsertTask(input: UpsertTaskInput! @spread): Task @upsert
      }

      input CreateTaskInput {
        name: String
        user: CreateUserRelation
      }

      input CreateUserRelation {
        connect: ID
        create: CreateUserInput
        update: UpdateUserInput
        upsert: UpsertUserInput
      }

      input CreateUserInput {
        name: String!
      }

      input UpdateUserInput {
        id: ID!
        name: String
      }

      input UpdateTaskInput {
        id: ID!
        name: String
        user: UpdateUserRelation
      }

      input UpdateUserRelation {
        disconnect: Boolean
        delete: Boolean
      }

      input UpsertUserInput {
        id: ID
        name: String
      }

      input UpsertTaskInput {
        id: ID
        name: String
        user: UpsertUserRelation
      }

      input UpsertUserRelation {
        connect: ID
        create: CreateUserInput
        update: UpdateUserInput
        upsert: UpsertUserInput
        disconnect: Boolean
        delete: Boolean
      }
    GRAPHQL
  end

  def task_mutation(action, input, selection = 'id name user { id }')
    graphql("mutation { #{action}Task(input: #{input}) { #{selection} } }")
  end

  it 'creates and connects' do
    LH::User.create!(name: 'a')

    expect_data(task_mutation(:create, '{ name: "foo", user: { connect: 1 } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'ignores an explicit null relation' do
    expect_data(task_mutation(:create, '{ name: "foo", user: null }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'user' => nil })
  end

  it 'upserts (creating) and connects' do
    LH::User.create!(name: 'a')

    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { connect: 1 } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'allows null operations' do
    LH::User.create!(name: 'a')
    input = '{ id: 1, name: "foo", user: { connect: null, create: null, update: null, upsert: null, disconnect: null, delete: null } }'

    expect_data(task_mutation(:upsert, input), 'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => nil })
  end

  it 'creates with a new belongsTo' do
    expect_data(task_mutation(:create, '{ name: "foo", user: { create: { name: "New User" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'creates with an upserted belongsTo that does not exist yet' do
    expect_data(task_mutation(:create, '{ name: "foo", user: { upsert: { id: 1, name: "New User" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'upserts a belongsTo without an id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", user: { upsert: { name: "New User" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'upserts a belongsTo with a null id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", user: { upsert: { id: null, name: "New User" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'upserts (creating) with a new belongsTo' do
    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { create: { name: "New User" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'upserts (creating) with a new upserted belongsTo' do
    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { upsert: { id: 1, name: "New User" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
  end

  it 'creates and updates the belongsTo' do
    LH::User.create!(name: 'foo')

    expect_data(task_mutation(:create, '{ name: "foo", user: { update: { id: 1, name: "bar" } } }', 'id name user { id name }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1', 'name' => 'bar' } })
  end

  it 'upserts (creating) and updates the belongsTo' do
    LH::User.create!(name: 'foo')

    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { update: { id: 1, name: "bar" } } }', 'id name user { id name }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1', 'name' => 'bar' } })
  end

  it 'upserts (creating) and updates the belongsTo through upsert' do
    LH::User.create!(name: 'foo')

    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { upsert: { id: 1, name: "bar" } } }', 'id name user { id name }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1', 'name' => 'bar' } })
  end

  describe 'saving the parent once, with several belongsTo' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type Mutation {
          updateUser(input: UpdateUserInput! @spread): User! @update
        }

        type User { id: ID! name: String! company: Company team: Team }
        type Company { id: ID! name: String! }
        type Team { id: ID! name: String! }

        input UpdateUserInput {
          id: ID!
          name: String!
          company: UpdateCompanyBelongsTo
          team: UpdateTeamBelongsTo
        }
        input UpdateCompanyBelongsTo { update: UpdateCompanyInput }
        input UpdateCompanyInput { id: ID! name: String! }
        input UpdateTeamBelongsTo { update: UpdateTeamInput }
        input UpdateTeamInput { id: ID! name: String! }
      GRAPHQL
    end

    it 'issues a single UPDATE for the parent' do
      LH::Company.create!(name: 'c')
      LH::Team.create!(name: 't')
      LH::User.create!(name: 'foo')
      updates = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        updates << payload[:sql] if payload[:sql].start_with?('UPDATE "lh_users"')
      end

      result = graphql(<<~GRAPHQL)
        mutation {
          updateUser(input: {
            id: 1, name: "user"
            company: { update: { id: 1, name: "company" } }
            team: { update: { id: 1, name: "team" } }
          }) { id name company { id name } team { id name } }
        }
      GRAPHQL

      expect_data(result, 'updateUser' => { 'id' => '1', 'name' => 'user', 'company' => { 'id' => '1', 'name' => 'company' },
                                            'team' => { 'id' => '1', 'name' => 'team' } })
      expect(updates.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  %w[update upsert].each do |action|
    it "#{action}s and disconnects the belongsTo, keeping the related model" do
      user = LH::User.create!(name: 'u')
      LH::Task.create!(name: 't', user: user)

      expect_data(task_mutation(action, '{ id: 1, name: "foo", user: { disconnect: true } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'user' => nil })
      expect(LH::User.find_by(id: 1)).not_to be_nil
      expect(LH::Task.find(1).user).to be_nil
    end

    it "#{action}s and deletes the belongsTo" do
      user = LH::User.create!(name: 'u')
      task = LH::Task.create!(name: 't', user: user)

      expect_data(task_mutation(action, '{ id: 1, name: "foo", user: { delete: true } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'user' => nil })
      expect(LH::User.find_by(id: user.id)).to be_nil
      expect(task.reload.user_id).to be_nil
    end

    it "#{action}s without deleting or disconnecting on falsy values" do
      user = LH::User.create!(name: 'u')
      task = LH::Task.create!(name: 't', user: user)

      expect_data(task_mutation(action, '{ id: 1, name: "foo", user: { delete: null, disconnect: false } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'user' => { 'id' => '1' } })
      expect(task.reload.user).to eq(user)
    end
  end

  it 'upserts (creating) and disconnects' do
    user = LH::User.create!(name: 'u')
    task = LH::Task.create!(name: 't', user: user)

    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { disconnect: true } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => nil })
    expect(LH::User.exists?(user.id)).to be(true)
    expect(task.reload.user_id).to be_nil
  end

  it 'upserts (creating) and deletes nothing when there is no related model' do
    LH::User.create!(name: 'u')

    expect_data(task_mutation(:upsert, '{ id: 1, name: "foo", user: { delete: true } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'user' => nil })
    expect(LH::User.find_by(id: 1)).not_to be_nil
  end

  describe 'across two nested belongsTo relations' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type User { id: ID! name: String! roles: [Role!] @belongsToMany }
        type Role { id: ID! name: String! }

        type Mutation {
          upsertUser(input: UpsertUserInput! @spread): User @upsert
        }

        input UpsertUserInput { id: ID name: String! rolesPivot: UpsertRoleUserPivotBelongsTo }
        input UpsertRoleUserPivotBelongsTo { upsert: [UpsertRoleUserPivotInput!] }
        input UpsertRoleUserPivotInput { id: ID role: UpsertRoleBelongsTo }
        input UpsertRoleBelongsTo { upsert: UpsertRoleInput }
        input UpsertRoleInput { id: ID name: String! users: UpsertRoleUsersRelation }
        input UpsertRoleUsersRelation { sync: [ID!] }
      GRAPHQL
    end

    it 'upserts through the pivot model' do
      result = graphql('mutation { upsertUser(input: { name: "foo", rolesPivot: { upsert: [{ role: { upsert: { name: "bar" } } }] } }) { name roles { name } } }')

      expect_data(result, 'upsertUser' => { 'name' => 'foo', 'roles' => [{ 'name' => 'bar' }] })
    end

    it 'overrides the existing models, moving the role to another user' do
      graphql('mutation { upsertUser(input: { name: "foo", rolesPivot: { upsert: [{ role: { upsert: { name: "bar" } } }] } }) { id } }')
      role = LH::Role.first
      expect(role.users.pluck(:id)).to eq([1])
      LH::User.create!(name: 'other')

      result = graphql(<<~GRAPHQL)
        mutation {
          upsertUser(input: {
            id: "1", name: "fooz"
            rolesPivot: { upsert: [{ id: "1", role: { upsert: { id: "1", name: "baz", users: { sync: ["2"] } } } }] }
          }) { id name roles { id name } }
        }
      GRAPHQL

      expect_data(result, 'upsertUser' => { 'id' => '1', 'name' => 'fooz', 'roles' => [] })
      expect(role.users.reload.pluck(:id)).to eq([2])
    end
  end

  describe 'creating several belongsTo that do not exist yet' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type RoleUserPivot { id: ID! meta: String user: User! role: Role! }
        type User { id: ID! name: String! }
        type Role { id: ID! name: String! }

        type Mutation {
          createRoleUser(input: RoleUserInput! @spread): RoleUserPivot @create
        }

        input RoleUserInput { id: ID meta: String user: UserInput! role: RoleInput! }
        input UserInput { create: CreateUserInput }
        input CreateUserInput { id: ID name: String! }
        input RoleInput { create: CreateRoleInput }
        input CreateRoleInput { id: ID name: String! }
      GRAPHQL
    end

    it 'creates both with the given ids, then the pivot' do
      result = graphql('mutation { createRoleUser(input: { id: "1", user: { create: { id: "2", name: "user 1" } }, role: { create: { id: "3", name: "role 1" } } }) { id user { id name } role { id name } } }')

      expect_data(result, 'createRoleUser' => { 'id' => '1', 'user' => { 'id' => '2', 'name' => 'user 1' },
                                                'role' => { 'id' => '3', 'name' => 'role 1' } })
    end

    it 'creates them again with new ids when repeated' do
      query = 'mutation { createRoleUser(input: { meta: "asdf", user: { create: { name: "some username" } }, role: { create: { name: "some rolename" } } }) { id meta user { id name } role { id name } } }'

      expect_data(graphql(query), 'createRoleUser' => { 'id' => '1', 'meta' => 'asdf', 'user' => { 'id' => '1', 'name' => 'some username' },
                                                        'role' => { 'id' => '1', 'name' => 'some rolename' } })
      expect_data(graphql(query), 'createRoleUser' => { 'id' => '2', 'meta' => 'asdf', 'user' => { 'id' => '2', 'name' => 'some username' },
                                                        'role' => { 'id' => '2', 'name' => 'some rolename' } })
    end
  end
end
