# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Schema/Directives/{Create,Update,UpdateMany,Upsert,UpsertMany,Delete}DirectiveTest.php
# (Laravel-specific cases — mass assignment, custom PHP directives, @nest — have no ActiveRecord counterpart.)
RSpec.describe 'Model mutation directives' do
  include_context 'with PHP Lighthouse models'

  describe '@create' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type Company { id: ID! name: String! }
        type Tag { name: String! default_string: String! }
        type Task { id: ID! name: String! }
        type User { id: ID! name: String tasks: [Task!]! @hasMany }

        type Mutation {
          createCompany(name: String): Company @create
          createCompanyFromInput(input: CreateCompanyInput! @spread): Company @create
          createTag(name: String): Tag @create
          createUser(input: CreateUserInput! @spread): User @create
          createUserWithTask(input: CreateUserWithTaskInput! @spread): User @create
        }

        input CreateCompanyInput { name: String }
        input CreateUserInput { name: String tasks: CreateTaskRelation }
        input CreateTaskRelation { create: [CreateTaskInput!] }
        input CreateTaskInput { name: String }
        input CreateUserWithTaskInput { name: String newTask: CreateTaskInput @create(relation: "tasks") }
      GRAPHQL
    end

    it 'creates from field arguments' do
      expect_data(graphql('mutation { createCompany(name: "foo") { id name } }'), 'createCompany' => { 'id' => '1', 'name' => 'foo' })
    end

    it 'creates from an input object' do
      expect_data(graphql('mutation { createCompanyFromInput(input: { name: "foo" }) { id name } }'),
                  'createCompanyFromInput' => { 'id' => '1', 'name' => 'foo' })
    end

    it 'returns database defaults right away' do
      expect_data(graphql('mutation { createTag(name: "foobar") { name default_string } }'),
                  'createTag' => { 'name' => 'foobar', 'default_string' => 'this is the default string' })
    end

    it 'creates nothing when a nested model fails to save' do
      LH::Task.create!(name: 'Uniq')

      expect { graphql('mutation { createUser(input: { name: "foo", tasks: { create: [{ name: "Uniq" }] } }) { id } }') }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect(LH::User.count).to eq(0)
    end

    it 'keeps the parent on a nested failure when transactions are off' do
      Lighthouse.configure { |c| c.transactional_mutations = false }
      LH::Task.create!(name: 'Uniq')

      expect { graphql('mutation { createUser(input: { name: "foo", tasks: { create: [{ name: "Uniq" }] } }) { id } }') }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect(LH::User.count).to eq(1)
    end

    it 'runs a nested create given as an argument with @create(relation:)' do
      expect_data(graphql('mutation { createUserWithTask(input: { name: "foo", newTask: { name: "Uniq" } }) { name tasks { name } } }'),
                  'createUserWithTask' => { 'name' => 'foo', 'tasks' => [{ 'name' => 'Uniq' }] })
    end

    it 'creates twice in a row' do
      expect_data(graphql('mutation { createUser(input: { name: "foo", tasks: { create: [{ name: "fooTask" }] } }) { name } }'),
                  'createUser' => { 'name' => 'foo' })
      expect_data(graphql('mutation { createUser(input: { name: "bar", tasks: { create: [{ name: "barTask" }] } }) { name } }'),
                  'createUser' => { 'name' => 'bar' })
    end
  end

  describe '@create with argument directives on belongsTo' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type Post { id: ID! title: String! task: Task @belongsTo }
        type Task { id: ID! name: String! user: User @belongsTo }
        type User { id: ID! name: String }

        type Mutation {
          createPost(input: CreatePostInput! @spread): Post @create
          createTask(input: CreateTaskInput! @spread): Task @create
          createTaskUpserting(input: CreateTaskUpsertingInput! @spread): Task @create
        }

        input CreatePostInput { title: String! task: UpsertTaskInput @upsert }
        input UpsertTaskInput { id: ID name: String! }
        input CreateTaskInput { name: String user: CreateUserInput @create }
        input CreateUserInput { name: String }
        input CreateTaskUpsertingInput { name: String! user: UpsertUserInput @upsert }
        input UpsertUserInput { id: ID name: String! }
      GRAPHQL
    end

    it 'creates an optional belongsTo with @create on the argument' do
      expect_data(graphql('mutation { createTask(input: { name: "task", user: { name: "user" } }) { name user { name } } }'),
                  'createTask' => { 'name' => 'task', 'user' => { 'name' => 'user' } })
    end

    it 'upserts the belongsTo before saving' do
      expect_data(graphql('mutation { createPost(input: { title: "My post", task: { name: "New Task" } }) { title task { id name } } }'),
                  'createPost' => { 'title' => 'My post', 'task' => { 'id' => '1', 'name' => 'New Task' } })
    end

    it 'updates the existing belongsTo through @upsert' do
      task = LH::Task.create!(name: 'Original name')

      result = graphql('mutation ($id: ID!, $name: String!) { createPost(input: { title: "My post", task: { id: $id, name: $name } }) { task { id name } } }',
                       { 'id' => task.id, 'name' => 'Updated via directive' })

      expect_data(result, 'createPost' => { 'task' => { 'id' => task.id.to_s, 'name' => 'Updated via directive' } })
      expect(task.reload.name).to eq('Updated via directive')
    end

    it 'ignores a null @upsert argument' do
      expect_data(graphql('mutation { createTaskUpserting(input: { name: "My task", user: null }) { name user { id } } }'),
                  'createTaskUpserting' => { 'name' => 'My task', 'user' => nil })
      expect(LH::User.count).to eq(0)
    end
  end

  describe '@update' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type Company { id: ID! name: String! }
        type Category { category_id: ID! name: String! }
        type CategoryById { id: ID! @rename(attribute: "category_id") name: String! }
        type Task { id: Int name: String! }
        type User { id: ID! name: String tasks: [Task!]! @hasMany }

        type Mutation {
          updateCompany(id: ID!, name: String): Company @update
          updateCompanyWithoutKey: Company @update(model: "Company")
          updateCompanyFromInput(input: UpdateCompanyInput! @spread): Company @update
          updateCategory(category_id: ID!, name: String): Category @update
          updateCategoryById(id: ID!, name: String): CategoryById @update(model: "Category")
          updateUser(input: UpdateUserInput! @spread): User @update
          updateUserTask(input: UpdateUserTaskInput! @spread): User @update(model: "User")
          updateUserTasks(input: UpdateUserTasksInput! @spread): User @update(model: "User")
        }

        input UpdateCompanyInput { id: ID! name: String }
        input UpdateUserInput { id: ID! name: String tasks: CreateTaskRelation }
        input CreateTaskRelation { create: [CreateTaskInput!] }
        input CreateTaskInput { thisFieldDoesNotExist: String }
        input UpdateUserTaskInput { id: Int name: String updateTask: UpdateTaskInput @update(relation: "tasks") }
        input UpdateUserTasksInput { id: Int name: String updateTask: [UpdateTaskInput] @update(relation: "tasks") }
        input UpdateTaskInput { id: Int name: String }
      GRAPHQL
    end

    it 'updates from field arguments' do
      LH::Company.create!(name: 'foo')

      expect_data(graphql('mutation { updateCompany(id: 1, name: "bar") { id name } }'), 'updateCompany' => { 'id' => '1', 'name' => 'bar' })
      expect(LH::Company.first.name).to eq('bar')
    end

    it 'updates from an input object' do
      LH::Company.create!(name: 'foo')

      expect_data(graphql('mutation { updateCompanyFromInput(input: { id: 1, name: "bar" }) { id name } }'),
                  'updateCompanyFromInput' => { 'id' => '1', 'name' => 'bar' })
    end

    it 'fails without a primary key' do
      expect(error_messages(graphql('mutation { updateCompanyWithoutKey { id } }'))).to eq(['Missing primary key for update.'])
    end

    it 'updates with a custom primary key' do
      LH::Category.create!(name: 'foo')

      expect_data(graphql('mutation { updateCategory(category_id: 1, name: "bar") { category_id name } }'),
                  'updateCategory' => { 'category_id' => '1', 'name' => 'bar' })
    end

    it 'updates with a custom primary key passed as id' do
      LH::Category.create!(name: 'foo')

      expect_data(graphql('mutation { updateCategoryById(id: 1, name: "bar") { id name } }'),
                  'updateCategoryById' => { 'id' => '1', 'name' => 'bar' })
      expect(LH::Category.first.name).to eq('bar')
    end

    it 'leaves the record unchanged when a nested model fails' do
      LH::User.create!(name: 'Original')

      expect { graphql('mutation { updateUser(input: { id: 1, name: "Changed", tasks: { create: [{ thisFieldDoesNotExist: "bar" }] } }) { id } }') }
        .to raise_error(ActiveModel::UnknownAttributeError)
      expect(LH::User.first.name).to eq('Original')
    end

    it 'runs a nested update given as an argument with @update(relation:)' do
      LH::User.create!(name: 'user')
      LH::Task.create!(id: 3, name: 'task')

      expect_data(graphql('mutation { updateUserTask(input: { id: 1, name: "foo", updateTask: { id: 3, name: "Uniq" } }) { name tasks { id name } } }'),
                  'updateUserTask' => { 'name' => 'foo', 'tasks' => [{ 'id' => 3, 'name' => 'Uniq' }] })
    end

    it 'runs a nested update on a list given as an argument' do
      LH::User.create!(name: 'user')
      LH::Task.create!(id: 3, name: 'a')
      LH::Task.create!(id: 4, name: 'b')

      expect_data(graphql('mutation { updateUserTasks(input: { id: 1, name: "foo", updateTask: [{ id: 3, name: "Uniq" }, { id: 4, name: "Foo" }] }) { tasks { id name } } }'),
                  'updateUserTasks' => { 'tasks' => [{ 'id' => 3, 'name' => 'Uniq' }, { 'id' => 4, 'name' => 'Foo' }] })
    end
  end

  describe '@updateMany' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type Company { id: ID! name: String! }
        input UpdateCompanyInput { id: ID! name: String }

        type Mutation {
          updateCompanies(inputs: [UpdateCompanyInput]!): [Company!]! @updateMany
          updateCompaniesFooBar(foo: String, bar: String): [Company!]! @updateMany(model: "Company")
          updateCompaniesNotList(inputs: UpdateCompanyInput!): [Company!]! @updateMany(model: "Company")
          updateCompaniesNotInputs(inputs: [String!]!): [Company!]! @updateMany(model: "Company")
        }
      GRAPHQL
    end

    it 'updates from the list argument' do
      LH::Company.create!(name: 'foo1')
      LH::Company.create!(name: 'bar1')

      expect_data(graphql('mutation { updateCompanies(inputs: [{ id: 1, name: "foo2" }, { id: 2, name: "bar2" }]) { id name } }'),
                  'updateCompanies' => [{ 'id' => '1', 'name' => 'foo2' }, { 'id' => '2', 'name' => 'bar2' }])
    end

    it 'accepts empty inputs' do
      expect_data(graphql('mutation { updateCompanies(inputs: []) { id } }'), 'updateCompanies' => [])
    end

    it 'rolls back every change on a partial failure' do
      LH::Company.create!(name: 'foo1')

      result = graphql('mutation { updateCompanies(inputs: [{ id: 1, name: "foo2" }, { id: 2, name: "does not exist" }]) { id } }')

      expect(error_messages(result)).to eq(["Couldn't find LH::Company with 'id'=2"])
      expect(LH::Company.first.name).to eq('foo1')
    end

    it 'applies the same id several times in order' do
      LH::Company.create!(name: 'foo1')

      expect_data(graphql('mutation { updateCompanies(inputs: [{ id: 1, name: "foo2" }, { id: 1, name: "foo3" }]) { id name } }'),
                  'updateCompanies' => [{ 'id' => '1', 'name' => 'foo2' }, { 'id' => '1', 'name' => 'foo3' }])
    end

    {
      'more than one argument' => ['updateCompaniesFooBar(foo: "asf", bar: null)', 'clients pass exactly one field argument'],
      'a non-list argument' => ['updateCompaniesNotList(inputs: { id: 1, name: "foo" })', 'single argument value is a list'],
      'a list of non-input values' => ['updateCompaniesNotInputs(inputs: ["foo"])', 'list items of its single argument value are input objects']
    }.each do |case_name, (call, message)|
      it "rejects #{case_name}" do
        expect { graphql("mutation { #{call} { id } }") }.to raise_error(Lighthouse::DefinitionError, /#{message}/)
      end
    end
  end

  describe '@upsert' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type User { id: ID! email: String name: String company_id: ID tasks: [Task!]! @hasMany }
        type Task { id: Int name: String! difficulty: Int }

        type Mutation {
          upsertUser(name: String!, email: String!): User @upsert(identifyingColumns: ["email"])
          upsertUserByTwo(name: String!, email: String!, company_id: ID!): User @upsert(identifyingColumns: ["name", "company_id"], model: "User")
          upsertUserNeedsBoth(name: String!, email: String): User @upsert(identifyingColumns: ["name", "email"], model: "User")
          upsertUserFromInput(input: UpsertUserInput! @spread): User! @upsert(identifyingColumns: ["email"], model: "User")
          updateUser(input: UpdateUserInput! @spread): User @update
          updateUserByTaskName(input: UpdateUserByTaskNameInput! @spread): User @update(model: "User")
          updateUserManyByTaskName(input: UpdateUserManyByTaskNameInput! @spread): User @update(model: "User")
        }

        input UpsertUserInput { email: String! name: String! }
        input UpdateUserInput { id: Int name: String tasks: [UpdateTaskInput!] @upsert(relation: "tasks") }
        input UpdateTaskInput { id: Int name: String }
        input UpdateUserByTaskNameInput { id: Int tasks: [TaskByNameInput!] @upsert(relation: "tasks", identifyingColumns: ["name"]) }
        input UpdateUserManyByTaskNameInput { id: Int tasks: [TaskByNameInput!] @upsertMany(relation: "tasks", identifyingColumns: ["name"]) }
        input TaskByNameInput { name: String! difficulty: Int }
      GRAPHQL
    end

    it 'upserts nested models given as an argument with @upsert(relation:)' do
      user = LH::User.create!(id: 1, name: 'user')
      LH::Task.create!(id: 1, name: 'old', user: user)

      expect_data(graphql('mutation { updateUser(input: { id: 1, name: "foo", tasks: [{ id: 1, name: "updated" }, { id: 2, name: "new" }] }) { name tasks { id name } } }'),
                  'updateUser' => { 'name' => 'foo', 'tasks' => [{ 'id' => 1, 'name' => 'updated' }, { 'id' => 2, 'name' => 'new' }] })
    end

    it 'inserts nested models without ids' do
      LH::User.create!(name: 'user')

      expect_data(graphql('mutation { updateUser(input: { id: 1, name: "foo", tasks: [{ name: "foo" }, { name: "bar" }] }) { tasks { name } } }'),
                  'updateUser' => { 'tasks' => [{ 'name' => 'foo' }, { 'name' => 'bar' }] })
    end

    it 'upserts by an identifying column' do
      graphql('mutation { upsertUser(email: "foo@te.st", name: "bar") { name } }')
      expect_data(graphql('mutation { upsertUser(email: "foo@te.st", name: "foo") { name email } }'),
                  'upsertUser' => { 'name' => 'foo', 'email' => 'foo@te.st' })
      expect(LH::User.count).to eq(1)
    end

    it 'upserts by several identifying columns' do
      LH::Company.create!(id: 1, name: 'company')

      graphql('mutation { upsertUserByTwo(email: "foo@te.st", name: "bar", company_id: 1) { name } }')
      expect_data(graphql('mutation { upsertUserByTwo(email: "bar@te.st", name: "bar", company_id: 1) { name email company_id } }'),
                  'upsertUserByTwo' => { 'name' => 'bar', 'email' => 'bar@te.st', 'company_id' => '1' })
      expect(LH::User.count).to eq(1)
    end

    it 'requires every identifying column' do
      expect(error_messages(graphql('mutation { upsertUserNeedsBoth(name: "foo") { id } }')))
        .to eq(['All configured identifying columns must be present and non-null for upsert.'])
    end

    it 'refuses empty identifying columns when the schema is built' do
      expect { build_schema("type User { id: ID! }\ntype Mutation { upsertUser(name: String!): User @upsert(identifyingColumns: []) }" + LH::PLACEHOLDER_QUERY) }
        .to raise_error(Lighthouse::DefinitionError, /identifyingColumns must not be empty/)
    end

    it 'upserts by an identifying column from a spread input' do
      graphql('mutation { upsertUserFromInput(input: { email: "foo@te.st", name: "bar" }) { name } }')
      expect_data(graphql('mutation { upsertUserFromInput(input: { email: "foo@te.st", name: "baz" }) { email name } }'),
                  'upsertUserFromInput' => { 'email' => 'foo@te.st', 'name' => 'baz' })
      expect(LH::User.count).to eq(1)
    end

    it 'upserts nested models by an identifying column' do
      user = LH::User.create!(name: 'user')
      task = LH::Task.create!(name: 'existing-task', difficulty: 1, user: user)

      expect_data(graphql("mutation { updateUserByTaskName(input: { id: #{user.id}, tasks: [{ name: \"existing-task\", difficulty: 2 }] }) { tasks { name difficulty } } }"),
                  'updateUserByTaskName' => { 'tasks' => [{ 'name' => 'existing-task', 'difficulty' => 2 }] })
      expect(task.reload.difficulty).to eq(2)
      expect(LH::Task.count).to eq(1)
    end

    it 'upserts many nested models by an identifying column' do
      user = LH::User.create!(name: 'user')
      first = LH::Task.create!(name: 'first-existing-task', difficulty: 1, user: user)
      second = LH::Task.create!(name: 'second-existing-task', difficulty: 1, user: user)

      graphql("mutation { updateUserManyByTaskName(input: { id: #{user.id}, tasks: [{ name: \"first-existing-task\", difficulty: 2 }, { name: \"second-existing-task\", difficulty: 3 }] }) { id } }")

      expect([first.reload.difficulty, second.reload.difficulty]).to eq([2, 3])
      expect(LH::Task.count).to eq(2)
    end
  end

  describe '@upsertMany' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type User { id: ID! email: String name: String }
        input UpsertUserInput { email: String name: String! }

        type Mutation {
          upsertUsers(inputs: [UpsertUserInput!]!): [User!]! @upsertMany(identifyingColumns: ["email"])
          upsertUsersNeedingBoth(inputs: [UpsertUserInput!]!): [User!]! @upsertMany(identifyingColumns: ["name", "email"], model: "User")
        }
      GRAPHQL
    end

    it 'upserts each input by an identifying column' do
      graphql('mutation { upsertUsers(inputs: [{ email: "foo@te.st", name: "bar" }, { email: "baz@te.st", name: "qux" }]) { email } }')
      expect(LH::User.count).to eq(2)

      expect_data(graphql('mutation { upsertUsers(inputs: [{ email: "foo@te.st", name: "updated" }, { email: "baz@te.st", name: "qux" }]) { email name } }'),
                  'upsertUsers' => [{ 'email' => 'foo@te.st', 'name' => 'updated' }, { 'email' => 'baz@te.st', 'name' => 'qux' }])
      expect(LH::User.count).to eq(2)
    end

    it 'requires every identifying column' do
      expect(error_messages(graphql('mutation { upsertUsersNeedingBoth(inputs: [{ name: "foo" }]) { id } }')))
        .to eq(['All configured identifying columns must be present and non-null for upsert.'])
    end
  end

  describe '@delete' do
    let(:sdl) do
      <<~GRAPHQL + LH::PLACEHOLDER_QUERY
        type User { id: ID! tasks: [Task!]! @hasMany }
        type Task { id: ID! post: Post @hasOne user: User @belongsTo }
        type Post { id: ID! }
        input SomeInput { foo: String }

        type Mutation {
          deleteUser(id: ID! @whereKey): User @delete
          deleteUsers(ids: [ID!]! @whereKey): [User!]! @delete(model: "User")
          deleteUsersByName(name: String! @eq): [User!]! @delete(model: "User")
          deleteNamedUser(id: ID! @whereKey): User @delete(model: "User", scopes: ["named"])
          deleteUserByEither(id: ID @whereKey, email: String @eq): User @delete(model: "User")
          deleteUserUnfiltered(id: ID): User @delete(model: "User")
          deleteTasks(options: SomeInput, id: ID! @eq): [Task!]! @delete(model: "Task")
          updateUser(id: ID, deleteTasks: [ID!]! @delete(relation: "tasks")): User @update
          updateTask(id: ID, deletePost: Boolean @delete(relation: "post"), deleteUser: Boolean @delete(relation: "user")): Task @update
        }
      GRAPHQL
    end

    it 'deletes a model and returns it' do
      user = LH::User.create!(name: 'u')

      expect_data(graphql('mutation ($id: ID!) { deleteUser(id: $id) { id } }', { 'id' => user.id }), 'deleteUser' => { 'id' => user.id.to_s })
      expect(LH::User.count).to eq(0)
    end

    it 'returns null when nothing matches' do
      expect_data(graphql('mutation { deleteUser(id: "non-existing") { id } }'), 'deleteUser' => nil)
    end

    it 'deletes several models by id' do
      ids = Array.new(2) { |i| LH::User.create!(name: "u#{i}").id }

      expect(graphql('mutation ($ids: [ID!]!) { deleteUsers(ids: $ids) { id } }', { 'ids' => ids }).dig('data', 'deleteUsers').size).to eq(2)
      expect(LH::User.count).to eq(0)
    end

    it 'returns an empty list for unknown or no ids' do
      expect_data(graphql('mutation { deleteUsers(ids: ["non-existing"]) { id } }'), 'deleteUsers' => [])
      expect_data(graphql('mutation { deleteUsers(ids: []) { id } }'), 'deleteUsers' => [])
    end

    it 'deletes by a non-primary key' do
      foo = LH::User.create!(name: 'foo')
      LH::User.create!(name: 'bar')

      expect_data(graphql('mutation { deleteUsersByName(name: "foo") { id } }'), 'deleteUsersByName' => [{ 'id' => foo.id.to_s }])
      expect(LH::User.count).to eq(1)
    end

    it 'applies scopes' do
      named = LH::User.create!(name: 'foo')
      unnamed = LH::User.create!(name: nil)

      expect_data(graphql("mutation { deleteNamedUser(id: #{named.id}) { id } }"), 'deleteNamedUser' => { 'id' => named.id.to_s })
      expect_data(graphql("mutation { deleteNamedUser(id: #{unnamed.id}) { id } }"), 'deleteNamedUser' => nil)
    end

    it 'refuses to run without a filter argument' do
      expect(error_messages(graphql('mutation { deleteUserByEither { id } }'))).to eq(['Would modify all models, use an argument to filter.'])
      expect(error_messages(graphql('mutation { deleteUserUnfiltered(id: 1) { id } }'))).to eq(['Would modify all models, use an argument to filter.'])
    end

    it 'filters with the arguments that have a filter directive, ignoring the others' do
      task = LH::Task.create!(name: 'task')

      expect_data(graphql("mutation { deleteTasks(options: { foo: \"bar\" }, id: #{task.id}) { id } }"), 'deleteTasks' => [{ 'id' => task.id.to_s }])
      expect(LH::Task.count).to eq(0)
    end

    it 'deletes nested hasMany models given as an argument with @delete(relation:)' do
      user = LH::User.create!(name: 'u')
      tasks = Array.new(2) { |i| LH::Task.create!(name: "t#{i}", user: user) }

      expect_data(graphql('mutation ($id: ID!, $ids: [ID!]!) { updateUser(id: $id, deleteTasks: $ids) { id tasks { id } } }',
                          { 'id' => user.id, 'ids' => [tasks[1].id] }),
                  'updateUser' => { 'id' => user.id.to_s, 'tasks' => [{ 'id' => tasks[0].id.to_s }] })
    end

    it 'deletes the hasOne of a Boolean @delete(relation:) argument when true' do
      task = LH::Task.create!(name: 'task')
      post = LH::Post.create!(title: 'p', task: task)

      expect_data(graphql("mutation { updateTask(id: #{task.id}, deletePost: false) { post { id } } }"), 'updateTask' => { 'post' => { 'id' => post.id.to_s } })
      expect_data(graphql("mutation { updateTask(id: #{task.id}, deletePost: true) { post { id } } }"), 'updateTask' => { 'post' => nil })
      expect(LH::Post.count).to eq(0)
    end

    it 'deletes the belongsTo of a Boolean @delete(relation:) argument' do
      user = LH::User.create!(name: 'u')
      task = LH::Task.create!(name: 'task', user: user)

      expect_data(graphql("mutation { updateTask(id: #{task.id}, deleteUser: true) { id user { id } } }"),
                  'updateTask' => { 'id' => task.id.to_s, 'user' => nil })
      expect(task.reload.user_id).to be_nil
      expect(LH::User.find_by(id: user.id)).to be_nil
    end

    it 'reports a model whose callbacks refuse the destroy' do
      LH::User.refuse_destroy = true
      user = LH::User.create!(name: 'u')

      expect(error_messages(graphql("mutation { deleteUser(id: #{user.id}) { id } }"))).to eq(["Could not modify model LH::User with ID #{user.id}."])
      expect(LH::User.count).to eq(1)
    ensure
      LH::User.refuse_destroy = false
    end
  end
end
