# frozen_string_literal: true

# A paginated relation is loaded for every parent of a level at once, as PHP
# Lighthouse's PaginatedModelsLoader does: one query for the pages and, only
# when the client asks for a total, one for the counts — however many parents.
RSpec.describe 'Paginated relations, batched' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users: [User!]! @all
        tasks: [Task!]! @all
        teams: [Team!]! @all
      }

      type User {
        id: ID!
        tasks(name: String @neq, orderBy: [OrderByClause!] @orderBy): [Task!]! @hasMany(type: PAGINATOR)
        taskConnection: [Task!]! @hasMany(relation: "tasks", type: CONNECTION)
        simpleTasks: [Task!]! @hasMany(relation: "tasks", type: SIMPLE)
        roles: [Role!]! @belongsToMany(type: PAGINATOR)
      }

      type Team {
        id: ID!
        users: [User!]! @paginate
      }

      type Task {
        id: ID!
        name: String
        images: [Image!]! @morphMany(type: PAGINATOR)
        tags: [Tag!]! @morphToMany(type: CONNECTION)
      }

      type Role { id: ID! name: String }
      type Image { id: ID! url: String }
      type Tag { id: ID! name: String }

      input OrderByClause { column: String! order: String }
    GRAPHQL
  end

  def users_with_tasks(count, tasks_each: 3, from: 0)
    Array.new(count) do |i|
      u = from + i
      LH::User.create!(name: "user #{u}").tap do |user|
        tasks_each.times { |t| LH::Task.create!(name: "task #{u}-#{t}", user: user) }
      end
    end
  end

  def data(query)
    result = graphql(query)
    raise result['errors'].inspect if result['errors']

    result['data']
  end

  def query_count(query)
    queries_in { data(query) }.size
  end

  describe 'the number of queries' do
    it 'does not grow with the number of parents' do
      query = '{ users { tasks(first: 2) { data { id } paginatorInfo { total } } } }'
      users_with_tasks(2)
      few = query_count(query)
      users_with_tasks(6, from: 2)

      expect(query_count(query)).to eq(few)
      expect(few).to eq(3) # the users, the pages, the counts
    end

    it 'does not count when the client asks for no total' do
      users_with_tasks(4)

      expect(query_count('{ users { tasks(first: 2) { data { id } } } }')).to eq(2)
      expect(query_count('{ users { taskConnection(first: 2) { edges { node { id } } } } }')).to eq(2)
      expect(query_count('{ users { simpleTasks(first: 2) { data { id } paginatorInfo { hasMorePages } } } }')).to eq(2)
    end

    it 'batches every kind of collection relation, and nested @paginate' do
      users = users_with_tasks(4)
      team = LH::Team.create!(name: 'team')
      users.each { |user| user.update!(team: team) }
      LH::Team.create!(name: 'empty team')
      role = LH::Role.create!(name: 'admin')
      users.each { |user| user.roles << role }
      tag = LH::Tag.create!(name: 'tag')
      LH::Task.find_each do |task|
        task.images.create!(url: "#{task.name}.png")
        LH::Taggable.create!(tag: tag, taggable: task)
      end

      expect(query_count('{ users { roles(first: 5) { data { name } paginatorInfo { total } } } }')).to eq(3)
      expect(query_count('{ tasks { images(first: 5) { data { url } paginatorInfo { total } } tags(first: 5) { edges { node { name } } } } }'))
        .to eq(4) # the tasks, the image pages and counts, the tag pages
      expect(query_count('{ teams { users(first: 2) { data { id } paginatorInfo { total } } } }')).to eq(3)
    end
  end

  describe 'the pages' do
    let!(:users) { users_with_tasks(3, tasks_each: 5) }

    def tasks_of(user, query)
      data(query)['users'].find { |entry| entry['id'] == user.id.to_s }
    end

    it 'gives each parent its own page and total, as if it were loaded alone' do
      result = data('{ users { id tasks(first: 2, page: 2) { data { name } paginatorInfo { total currentPage lastPage hasMorePages } } } }')

      expect(result['users'].map { |user| user.dig('tasks', 'data').pluck('name') })
        .to eq([['task 0-2', 'task 0-3'], ['task 1-2', 'task 1-3'], ['task 2-2', 'task 2-3']])
      expect(result['users'].map { |user| user.dig('tasks', 'paginatorInfo') }.uniq)
        .to eq([{ 'total' => 5, 'currentPage' => 2, 'lastPage' => 3, 'hasMorePages' => true }])
    end

    it 'applies the field filters and order inside each page' do
      query = '{ users { id tasks(first: 2, name: "task 1-4", orderBy: [{ column: "name", order: "DESC" }]) ' \
              '{ data { name } paginatorInfo { total } } } }'

      expect(tasks_of(users[1], query)['tasks']).to eq('data' => [{ 'name' => 'task 1-3' }, { 'name' => 'task 1-2' }],
                                                       'paginatorInfo' => { 'total' => 4 })
    end

    it 'walks a connection with cursors, per parent' do
      first = data('{ users { id taskConnection(first: 2) { edges { node { name } } pageInfo { endCursor hasNextPage total } } } }')
      cursor = first['users'][2].dig('taskConnection', 'pageInfo', 'endCursor')
      rest = data("{ users { id taskConnection(first: 10, after: \"#{cursor}\") { edges { node { name } } pageInfo { hasNextPage } } } }")

      expect(first['users'][2]['taskConnection']['edges'].map { |edge| edge.dig('node', 'name') }).to eq(['task 2-0', 'task 2-1'])
      expect(first['users'][2]['taskConnection']['pageInfo']).to include('hasNextPage' => true, 'total' => 5)
      expect(rest['users'][2]['taskConnection']['edges'].map { |edge| edge.dig('node', 'name') }).to eq(['task 2-2', 'task 2-3', 'task 2-4'])
      expect(rest['users'][2]['taskConnection']['pageInfo']['hasNextPage']).to be(false)
    end

    it 'tells a simple paginator whether there is more without counting' do
      result = data('{ users { simpleTasks(first: 4) { data { name } paginatorInfo { hasMorePages count } } } }')

      expect(result['users'].map { |user| user.dig('simpleTasks', 'paginatorInfo') }.uniq).to eq([{ 'hasMorePages' => true, 'count' => 4 }])
    end

    it 'returns empty pages for parents without related records' do
      LH::User.create!(name: 'lonely')

      lonely = data('{ users { tasks(first: 2) { data { id } paginatorInfo { total lastPage } } } }')['users'].last

      expect(lonely['tasks']).to eq('data' => [], 'paginatorInfo' => { 'total' => 0, 'lastPage' => 1 })
    end
  end

  it 'falls back to one query per parent without a Dataloader, with the same results' do
    users_with_tasks(2)
    query = '{ users { tasks(first: 2) { data { name } paginatorInfo { total } } } }'
    batched = data(query)

    plain = build_schema(sdl).execute(query).to_h

    expect(plain['data']).to eq(batched)
  end
end
