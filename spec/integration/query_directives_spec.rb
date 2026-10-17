# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Schema/Directives/AllDirectiveTest.php and
# tests/Integration/Pagination/PaginateDirectiveDBTest.php (Scout cases left out), plus the
# relationship directives' `type:` pagination and batching.
RSpec.describe 'Query directives' do
  include_context 'with PHP Lighthouse models'

  def ids(list)
    list.map { |item| item['id'] }
  end

  describe '@all' do
    let(:sdl) do
      <<~GRAPHQL
        type User { id: ID! name: String posts: [Post!]! @all }
        type Post { id: ID! }
        type Foo { id: ID! }

        type Query {
          users: [User!]! @all
          foos: [Foo!]! @all(model: "User")
          usersNotNamed(name: String @neq): [User!]! @all(model: "User")
        }
      GRAPHQL
    end

    it 'returns every model as a list' do
      2.times { |i| LH::User.create!(name: "u#{i}") }

      expect(graphql('{ users { id } }').dig('data', 'users')).to eq([{ 'id' => '1' }, { 'id' => '2' }])
    end

    it 'takes an explicit model name' do
      2.times { |i| LH::User.create!(name: "u#{i}") }

      expect(graphql('{ foos { id } }').dig('data', 'foos').size).to eq(2)
    end

    it 'returns all models on a nested field too' do
      task = LH::Task.create!(name: 'task')
      2.times { LH::Post.create!(title: 'p', task: task) }
      2.times { |i| LH::User.create!(name: "u#{i}") }

      expect_data(graphql('{ users { posts { id } } }'),
                  'users' => [{ 'posts' => [{ 'id' => '1' }, { 'id' => '2' }] }, { 'posts' => [{ 'id' => '1' }, { 'id' => '2' }] }])
    end

    it 'applies argument filters' do
      %w[a b c].each { |name| LH::User.create!(name: name) }

      expect(graphql('{ usersNotNamed(name: "a") { name } }').dig('data', 'usersNotNamed')).to eq([{ 'name' => 'b' }, { 'name' => 'c' }])
    end
  end

  describe '@paginate' do
    let(:sdl) do
      <<~GRAPHQL
        type User { id: ID! name: String posts: [Post!]! @paginate }
        type Post { id: ID! comments: [Comment!]! @paginate }
        type Comment { id: ID! }

        type Query {
          users: [User!]! @paginate
          usersByName(name: String @eq): [User!]! @paginate(model: "User")
          namedUsers: [User!]! @paginate(model: "User", scopes: ["named"])
          userConnection: [User!]! @paginate(model: "User", type: CONNECTION)
          usersSimple: [User!] @paginate(model: "User", type: SIMPLE)
          usersByTwo: [User!]! @paginate(model: "User", defaultCount: 2)
          usersCapped: [User!]! @paginate(model: "User", maxCount: 2)
          usersUncapped: [User!]! @paginate(model: "User", maxCount: null)
          cachedUsers: [User!]! @paginate(model: "User") @cache
        }
      GRAPHQL
    end

    def users(count)
      Array.new(count) { |i| LH::User.create!(name: "user#{i}") }
    end

    it 'paginates with a paginatorInfo' do
      users(3)

      expect_data(graphql('{ users(first: 2) { paginatorInfo { count total currentPage } data { id } } }'),
                  'users' => { 'paginatorInfo' => { 'count' => 2, 'total' => 3, 'currentPage' => 1 }, 'data' => [{ 'id' => '1' }, { 'id' => '2' }] })
    end

    it 'returns the requested page' do
      users(3)

      expect_data(graphql('{ users(first: 2, page: 2) { paginatorInfo { currentPage lastPage hasMorePages firstItem lastItem } data { id } } }'),
                  'users' => { 'paginatorInfo' => { 'currentPage' => 2, 'lastPage' => 2, 'hasMorePages' => false, 'firstItem' => 3, 'lastItem' => 3 },
                               'data' => [{ 'id' => '3' }] })
    end

    it 'requires first without a default count' do
      expect(error_messages(graphql('{ users { data { id } } }'))).to include("Field 'users' is missing required arguments: first")
    end

    it 'applies argument filters (they used to be ignored)' do
      LH::User.create!(name: 'ada')
      LH::User.create!(name: 'alan')

      expect_data(graphql('{ usersByName(first: 10, name: "alan") { data { name } } }'), 'usersByName' => { 'data' => [{ 'name' => 'alan' }] })
    end

    it 'applies scopes' do
      named = LH::User.create!(name: 'A named user')
      LH::User.create!(name: nil)

      expect_data(graphql('{ namedUsers(first: 5) { paginatorInfo { count total currentPage } data { id } } }'),
                  'namedUsers' => { 'paginatorInfo' => { 'count' => 1, 'total' => 1, 'currentPage' => 1 }, 'data' => [{ 'id' => named.id.to_s }] })
    end

    it "pages a nested field's association, at every level" do
      first, = users(3)
      posts = Array.new(3) { LH::Post.create!(title: 'p', user: first) }
      3.times { LH::Comment.create!(post: posts.first) }

      result = graphql(<<~GRAPHQL)
        {
          users(first: 2, page: 1) {
            paginatorInfo { count total currentPage }
            data {
              posts(first: 2, page: 2) {
                paginatorInfo { count total currentPage }
                data { comments(first: 1, page: 3) { paginatorInfo { count total currentPage } } }
              }
            }
          }
        }
      GRAPHQL

      expect_data(result, 'users' => {
                    'paginatorInfo' => { 'count' => 2, 'total' => 3, 'currentPage' => 1 },
                    'data' => [
                      { 'posts' => { 'paginatorInfo' => { 'count' => 1, 'total' => 3, 'currentPage' => 2 },
                                     'data' => [{ 'comments' => { 'paginatorInfo' => { 'count' => 0, 'total' => 0, 'currentPage' => 3 } } }] } },
                      { 'posts' => { 'paginatorInfo' => { 'count' => 0, 'total' => 0, 'currentPage' => 2 }, 'data' => [] } }
                    ]
                  })
    end

    it 'queries a connection' do
      users(3)

      result = graphql('{ userConnection(first: 2) { pageInfo { hasNextPage } edges { node { id } } } }')

      expect_data(result, 'userConnection' => { 'pageInfo' => { 'hasNextPage' => true }, 'edges' => [{ 'node' => { 'id' => '1' } }, { 'node' => { 'id' => '2' } }] })
    end

    it 'continues a connection after a cursor, in two queries' do
      users(3)
      sql = queries_in do
        @result = graphql('query ($after: String!) { userConnection(first: 2, after: $after) { pageInfo { hasNextPage hasPreviousPage startCursor endCursor total count currentPage lastPage } edges { node { id } } } }',
                          { 'after' => Base64.strict_encode64('2') })
      end

      expect_data(@result, 'userConnection' => {
                    'pageInfo' => { 'hasNextPage' => false, 'hasPreviousPage' => true, 'startCursor' => 'Mw==', 'endCursor' => 'Mw==',
                                    'total' => 3, 'count' => 1, 'currentPage' => 2, 'lastPage' => 2 },
                    'edges' => [{ 'node' => { 'id' => '3' } }]
                  })
      expect(sql.size).to eq(2)
    end

    it 'queries an empty connection' do
      expect(graphql('{ userConnection(first: 5) { pageInfo { count currentPage endCursor hasNextPage hasPreviousPage lastPage startCursor total } edges { node { id } } } }')['data'])
        .to eq('userConnection' => { 'pageInfo' => { 'count' => 0, 'currentPage' => 1, 'endCursor' => nil, 'hasNextPage' => false,
                                                     'hasPreviousPage' => false, 'lastPage' => 1, 'startCursor' => nil, 'total' => 0 },
                                     'edges' => [] })
    end

    it 'queries an empty paginator' do
      expect(graphql('{ users(first: 5) { paginatorInfo { count currentPage firstItem hasMorePages lastItem lastPage perPage total } data { id } } }')['data'])
        .to eq('users' => { 'paginatorInfo' => { 'count' => 0, 'currentPage' => 1, 'firstItem' => nil, 'hasMorePages' => false,
                                                 'lastItem' => nil, 'lastPage' => 1, 'perPage' => 5, 'total' => 0 },
                            'data' => [] })
    end

    it 'queries zero items' do
      users(3)

      expect(graphql('{ users(first: 0) { paginatorInfo { count currentPage firstItem hasMorePages lastItem lastPage perPage total } data { id } } }')['data'])
        .to eq('users' => { 'paginatorInfo' => { 'count' => 0, 'currentPage' => 1, 'firstItem' => nil, 'hasMorePages' => false,
                                                 'lastItem' => nil, 'lastPage' => 0, 'perPage' => 0, 'total' => 3 },
                            'data' => [] })
    end

    it 'counts only when paginatorInfo is selected' do
      users(1)

      expect(queries_in { graphql('{ users(first: 1) { data { id } } }') }.size).to eq(1)
      expect(queries_in { graphql('{ users(first: 1) { paginatorInfo { total } data { id } } }') }.size).to eq(2)
    end

    it 'paginates simply, in a single query and without a total' do
      users(3)
      sql = queries_in { @result = graphql('{ usersSimple(first: 10) { paginatorInfo { count currentPage firstItem lastItem perPage hasMorePages } data { id } } }') }

      expect_data(@result, 'usersSimple' => { 'paginatorInfo' => { 'count' => 3, 'currentPage' => 1, 'firstItem' => 1, 'lastItem' => 3,
                                                                   'perPage' => 10, 'hasMorePages' => false } })
      expect(sql.size).to eq(1)
      expect(schema.types['SimplePaginatorInfo'].fields).not_to have_key('total')
    end

    it 'uses the default page for a null page' do
      users(3)

      expect_data(graphql('query ($page: Int) { usersSimple(first: 2, page: $page) { paginatorInfo { currentPage count } data { id } } }', { 'page' => nil }),
                  'usersSimple' => { 'paginatorInfo' => { 'currentPage' => 1, 'count' => 2 } })
    end

    it 'defaults first to defaultCount' do
      users(3)

      expect_data(graphql('{ usersByTwo { paginatorInfo { count } data { id } } }'), 'usersByTwo' => { 'paginatorInfo' => { 'count' => 2 } })
    end

    it 'defaults first to Config.pagination_default_count' do
      Lighthouse.configure { |c| c.pagination_default_count = 2 }
      users(3)

      expect(build_schema(sdl).execute('{ users { data { id } } }').dig('data', 'users', 'data').size).to eq(2)
    end

    it 'caps first at maxCount' do
      expect(error_messages(graphql('{ usersCapped(first: 3) { data { id } } }')))
        .to eq(['Maximum number of 2 requested items exceeded, got 3. Fetch smaller chunks.'])
    end

    it 'caps first at Config.pagination_max_count, unless the directive sets maxCount: null' do
      Lighthouse.configure { |c| c.pagination_max_count = 5 }

      expect(error_messages(graphql('{ users(first: 10) { data { id } } }'))).to eq(['Maximum number of 5 requested items exceeded, got 10. Fetch smaller chunks.'])
      expect(graphql('{ usersUncapped(first: 10) { data { id } } }')['errors']).to be_nil
    end

    it 'refuses a negative first' do
      expect(error_messages(graphql('{ users(first: -1) { data { id } } }'))).to eq(['Requested pagination amount must be non-negative, got -1.'])
    end

    it 'works with @cache, whatever the selection' do
      users(3)

      expect(graphql('{ cachedUsers(first: 2) { data { id } } }')['errors']).to be_nil
      expect_data(graphql('{ cachedUsers(first: 2) { paginatorInfo { count total currentPage } data { id } } }'),
                  'cachedUsers' => { 'paginatorInfo' => { 'count' => 2, 'total' => 3, 'currentPage' => 1 } })
    end

    describe 'in a type extension' do
      let(:sdl) do
        <<~GRAPHQL
          type User { id: ID! }
          type Query { foo: Int }
          extend type Query { users: [User!]! @paginate(model: "User") }
        GRAPHQL
      end

      it 'paginates' do
        2.times { |i| LH::User.create!(name: "u#{i}") }

        expect(graphql('{ users(first: 1) { data { id } } }').dig('data', 'users', 'data').size).to eq(1)
      end
    end
  end

  describe 'relationship directives' do
    let(:sdl) do
      <<~GRAPHQL
        type User {
          id: ID!
          tasks: [Task!]! @hasMany
          tasksNamed(name: String @eq): [Task!]! @hasMany(relation: "tasks")
          taskPages: [Task!]! @hasMany(relation: "tasks", type: PAGINATOR)
          taskConnection: [Task!]! @hasMany(relation: "tasks", type: CONNECTION)
          simpleTasks: [Task!]! @hasMany(relation: "tasks", type: SIMPLE, defaultCount: 1)
          roles: [Role!]! @belongsToMany
          company: Company @belongsTo
        }
        type Task { id: ID! name: String user: User @belongsTo post: Post @hasOne image: Image @morphOne images: [Image!]! @morphMany tags: [Tag!]! @morphToMany }
        type Post { id: ID! }
        type Image { id: ID! imageable: Task @morphTo }
        type Tag { id: ID! }
        type Role { id: ID! }
        type Company { id: ID! }

        type Query {
          users: [User!]! @all
          tasks: [Task!]! @all
          images: [Image!]! @all
        }
      GRAPHQL
    end

    it 'returns plain lists by default, as PHP Lighthouse does' do
      user = LH::User.create!(name: 'u')
      LH::Task.create!(name: 'a', user: user)

      expect(graphql('{ users { tasks { name } } }')['data']).to eq('users' => [{ 'tasks' => [{ 'name' => 'a' }] }])
    end

    it 'loads an association for all parents in one query' do
      users = Array.new(3) { |i| LH::User.create!(name: "u#{i}") }
      users.each { |user| 2.times { |i| LH::Task.create!(name: "#{user.name}-#{i}", user: user) } }

      sql = queries_in { @result = graphql('{ users { tasks { id } } }') }

      expect(@result.dig('data', 'users').map { |u| u['tasks'].size }).to eq([2, 2, 2])
      expect(sql.size).to eq(2) # the users, then all their tasks
    end

    it 'batches singular, many-to-many and polymorphic associations too' do
      company = LH::Company.create!(name: 'c')
      3.times do |i|
        user = LH::User.create!(name: "u#{i}", company: company)
        user.roles << LH::Role.create!(name: "r#{i}")
        task = LH::Task.create!(name: "t#{i}", user: user)
        LH::Post.create!(title: 'p', task: task)
        task.images.create!(url: 'i')
        task.tags << LH::Tag.create!(name: "tag#{i}")
      end

      users_sql = queries_in { graphql('{ users { company { id } roles { id } } }') }
      tasks_sql = queries_in { graphql('{ tasks { user { id } post { id } image { id } images { id } tags { id } } }') }
      images_sql = queries_in { graphql('{ images { imageable { id } } }') }

      expect(users_sql.size).to eq(1 + 1 + 2)      # users, companies, role_users + roles
      expect(tasks_sql.size).to eq(1 + 1 + 1 + 1 + 1 + 2) # tasks, users, posts, image, images, taggables + tags
      expect(images_sql.size).to eq(2)
    end

    it 'applies argument filters to the association' do
      user = LH::User.create!(name: 'u')
      %w[a b].each { |name| LH::Task.create!(name: name, user: user) }

      expect(graphql('{ users { tasksNamed(name: "b") { name } } }')['data']).to eq('users' => [{ 'tasksNamed' => [{ 'name' => 'b' }] }])
    end

    it 'paginates with type:' do
      user = LH::User.create!(name: 'u')
      3.times { |i| LH::Task.create!(name: "t#{i}", user: user) }

      result = graphql('{ users { taskPages(first: 2, page: 2) { paginatorInfo { total currentPage } data { name } } taskConnection(first: 1) { pageInfo { hasNextPage endCursor } edges { node { name } } } simpleTasks { data { name } } } }')

      expect(result['data']).to eq('users' => [{
                                     'taskPages' => { 'paginatorInfo' => { 'total' => 3, 'currentPage' => 2 }, 'data' => [{ 'name' => 't2' }] },
                                     'taskConnection' => { 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'MQ==' }, 'edges' => [{ 'node' => { 'name' => 't0' } }] },
                                     'simpleTasks' => { 'data' => [{ 'name' => 't0' }] }
                                   }])
    end

    it 'resolves polymorphic associations' do
      task = LH::Task.create!(name: 't')
      task.images.create!(url: 'i')

      expect(graphql('{ images { imageable { id } } }')['data']).to eq('images' => [{ 'imageable' => { 'id' => task.id.to_s } }])
    end

    it 'works without GraphQL::Dataloader' do
      user = LH::User.create!(name: 'u')
      LH::Task.create!(name: 'a', user: user)

      expect(build_schema(sdl).execute('{ users { tasks { name } } tasks { user { id } } }').to_h['data'])
        .to eq('users' => [{ 'tasks' => [{ 'name' => 'a' }] }], 'tasks' => [{ 'user' => { 'id' => user.id.to_s } }])
    end
  end

  describe '@find' do
    let(:sdl) do
      <<~GRAPHQL
        type User { id: ID! name: String email: String }
        type Query {
          user(id: ID! @eq): User @find
          userByEmail(email: String! @eq): User @find(model: "User")
          userByName(name: String! @eq): User @find(model: "User")
          plainUser(id: ID!): User @find(model: "User")
        }
      GRAPHQL
    end

    it 'finds by any filtered argument, not only id' do
      LH::User.create!(name: 'a', email: 'a@x.y')
      LH::User.create!(name: 'b', email: 'b@x.y')

      expect_data(graphql('{ userByEmail(email: "b@x.y") { name } }'), 'userByEmail' => { 'name' => 'b' })
    end

    it 'fails when more than one model matches' do
      2.times { LH::User.create!(name: 'same') }

      expect(error_messages(graphql('{ userByName(name: "same") { id } }'))).to eq(['The query returned more than one result.'])
    end

    it 'finds by an id argument without a filter directive' do
      LH::User.create!(name: 'a')

      expect_data(graphql('{ plainUser(id: 1) { name } }'), 'plainUser' => { 'name' => 'a' })
    end

    it 'works without GraphQL::Dataloader' do
      LH::User.create!(name: 'a')

      expect(build_schema(sdl).execute('{ user(id: 1) { name } }').to_h['data']).to eq('user' => { 'name' => 'a' })
    end
  end
end
