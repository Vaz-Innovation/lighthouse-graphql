# frozen_string_literal: true

# A task named Hidden is one no query may see.
class Types::ScopedTaskType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(tasks, _context) = tasks.where.not(name: 'Hidden')
end

# A role named Hidden is one no query may see.
class Types::ScopedRoleType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(roles, _context) = roles.where.not(name: 'Hidden')
end

# What a mutation's input may reach (nuwave/lighthouse#2744, and beyond it):
# an update, upsert, delete or disconnect on a has-one, has-many or
# many-to-many association only the parent's related records; and every
# operation, connect and sync included, only records the query may see (the
# type's scope_items), a hidden one as missing as one that does not exist.
RSpec.describe 'Nested mutations: what an input may reach' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query { tasks: [ScopedTask!]! @all(model: "LH::Task") roles: [ScopedRole!]! @all(model: "LH::Role") }

      type ScopedTask @model(class: "LH::Task") { id: ID! name: String! }
      type ScopedRole @model(class: "LH::Role") { id: ID! name: String! }
      type User @model(class: "LH::User") { id: ID! name: String tasks: [ScopedTask!]! @hasMany roles: [ScopedRole!]! @belongsToMany }
      type Post @model(class: "LH::Post") { id: ID! title: String }

      type Mutation {
        updateUser(input: UpdateUserInput! @spread): User @update(model: "LH::User")
        updateTask(input: UpdateTaskInput! @spread): ScopedTask @update(model: "LH::Task")
        createPost(input: CreatePostInput! @spread): Post @create(model: "LH::Post")
      }

      input UpdateUserInput { id: ID! tasks: TaskOperations roles: RoleOperations }
      input TaskOperations {
        update: [UpdateTaskInput!]
        upsert: [UpsertTaskInput!]
        delete: [ID!]
        connect: [ID!]
        disconnect: [ID!]
      }
      input UpdateTaskInput { id: ID! name: String }
      input UpsertTaskInput { id: ID name: String! }
      input RoleOperations { connect: [ID!] sync: [ID!] delete: [ID!] }
      input CreatePostInput { title: String task: PostTaskOperations }
      input PostTaskOperations { connect: ID }
    GRAPHQL
  end

  let!(:ada) { LH::User.create!(name: 'Ada') }
  let!(:grace) { LH::User.create!(name: 'Grace') }
  let!(:own) { LH::Task.create!(name: 'own', user: ada) }
  let!(:theirs) { LH::Task.create!(name: 'theirs', user: grace) }
  let!(:loose) { LH::Task.create!(name: 'loose') }
  let!(:hidden) { LH::Task.create!(name: 'Hidden') }

  def update_user(input)
    graphql('mutation($input: UpdateUserInput!) { updateUser(input: $input) { tasks { name } roles { name } } }',
            'input' => { 'id' => ada.id }.merge(input))
  end

  def not_related(*records) = "Cannot modify a model that is not related to the given parent: #{records.map(&:id).join(', ')}."

  describe 'operations on related records: only the parent’s' do
    it "refuses an update of another parent's record, changing nothing" do
      result = update_user('tasks' => { 'update' => [{ 'id' => theirs.id, 'name' => 'mine now' }] })

      expect(error_messages(result)).to eq([not_related(theirs)])
      expect([theirs.reload.name, theirs.user_id]).to eq(['theirs', grace.id])
    end

    it 'checks every id of a delete before deleting any' do
      result = update_user('tasks' => { 'delete' => [own.id, theirs.id] })

      expect(error_messages(result)).to eq([not_related(theirs)])
      expect(LH::Task.where(id: [own.id, theirs.id]).count).to eq(2)
    end

    it "refuses to disconnect another parent's record" do
      result = update_user('tasks' => { 'disconnect' => [theirs.id] })

      expect(error_messages(result)).to eq([not_related(theirs)])
      expect(theirs.reload.user_id).to eq(grace.id)
    end

    it "refuses an upsert of another parent's record, and creates one for an id no record has" do
      refused = update_user('tasks' => { 'upsert' => [{ 'id' => theirs.id, 'name' => 'mine now' }] })
      created = update_user('tasks' => { 'upsert' => [{ 'id' => '999', 'name' => 'new' }] })

      expect(error_messages(refused)).to eq([not_related(theirs)])
      expect(theirs.reload.name).to eq('theirs')
      expect_data(created, 'updateUser' => { 'tasks' => [{ 'name' => 'own' }, { 'name' => 'new' }] })
    end

    it 'updates, deletes and disconnects the related ones as before' do
      result = update_user('tasks' => { 'update' => [{ 'id' => own.id, 'name' => 'renamed' }], 'disconnect' => [own.id] })

      expect(error_messages(result)).to be_empty
      expect([own.reload.name, own.user_id]).to eq(['renamed', nil])
    end
  end

  describe 'records the query may not see: as missing as ones that do not exist' do
    it 'connects a record not related yet, but not a hidden one' do
      connected = update_user('tasks' => { 'connect' => [loose.id] })
      refused = update_user('tasks' => { 'connect' => [hidden.id] })
      absent = update_user('tasks' => { 'connect' => ['999'] })

      expect_data(connected, 'updateUser' => { 'tasks' => [{ 'name' => 'own' }, { 'name' => 'loose' }] })
      expect(error_messages(refused)).to eq(["Couldn't find LH::Task with 'id'=#{hidden.id}"])
      expect(error_messages(absent)).to eq(["Couldn't find LH::Task with 'id'=999"])
      expect(hidden.reload.user_id).to be_nil
    end

    it 'updates no hidden record from the root either' do
      result = graphql('mutation($input: UpdateTaskInput!) { updateTask(input: $input) { name } }',
                       'input' => { 'id' => hidden.id, 'name' => 'found' })

      expect(error_messages(result)).to eq(["Couldn't find LH::Task with 'id'=#{hidden.id}"])
      expect(hidden.reload.name).to eq('Hidden')
    end

    it 'connects a belongs-to only to a record that exists and may be seen' do
      created = graphql(%(mutation { createPost(input: { title: "a", task: { connect: "#{loose.id}" } }) { title } }))
      hidden_one = graphql(%(mutation { createPost(input: { title: "b", task: { connect: "#{hidden.id}" } }) { title } }))
      absent = graphql('mutation { createPost(input: { title: "c", task: { connect: "999" } }) { title } }')

      expect_data(created, 'createPost' => { 'title' => 'a' })
      expect(error_messages(hidden_one)).to eq(["Couldn't find LH::Task with 'id'=#{hidden.id}"])
      expect(error_messages(absent)).to eq(["Couldn't find LH::Task with 'id'=999"])
      expect(LH::Post.pluck(:title)).to eq(['a'])
    end

    it 'connects and syncs a many-to-many only to records that may be seen' do
      editor = LH::Role.create!(name: 'editor')
      secret = LH::Role.create!(name: 'Hidden')

      connected = update_user('roles' => { 'connect' => [editor.id] })
      refused = update_user('roles' => { 'sync' => [editor.id, secret.id] })

      expect_data(connected, 'updateUser' => { 'roles' => [{ 'name' => 'editor' }] })
      expect(error_messages(refused)).to eq(["Couldn't find LH::Role with 'id'=#{secret.id}"])
      expect(ada.roles.reload.pluck(:name)).to eq(['editor'])
    end

    it 'deletes no many-to-many record the parent is not related to' do
      stranger = LH::Role.create!(name: 'stranger')

      result = update_user('roles' => { 'delete' => [stranger.id] })

      expect(error_messages(result)).to eq([not_related(stranger)])
      expect(LH::Role.exists?(stranger.id)).to be(true)
    end
  end
end
