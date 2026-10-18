# frozen_string_literal: true

# @orderBy as PHP Lighthouse's: the clause types it generates for an argument
# written as `_`, ordering by columns and by relations' aggregates, and a
# fixed order on a field.
RSpec.describe '@orderBy' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users(orderBy: _ @orderBy(columns: ["name", "created_at"])): [User!]! @all
        anyUsers(orderBy: _ @orderBy): [User!]! @all(model: "User")
        enumUsers(orderBy: _ @orderBy(columnsEnum: "UserColumn")): [User!]! @all(model: "User")
        rankedUsers(
          orderBy: _ @orderBy(columns: ["name"], relations: [{ relation: "posts" }, { relation: "tasks", columns: ["difficulty"] }])
        ): [User!]! @all(model: "User")
        pagedUsers(orderBy: _ @orderBy(relations: [{ relation: "posts" }])): [User!]! @paginate(model: "User", defaultCount: 2)
        latestUsers: [User!]! @all(model: "User") @orderBy(column: "name", direction: DESC)
        typedUsers(orderBy: [OrderByClause!] @orderBy): [User!]! @all(model: "User")
      }

      enum UserColumn {
        NAME @enum(value: "name")
        EMAIL @enum(value: "email")
      }

      type User {
        name: String
        tasks(orderBy: _ @orderBy(columns: ["difficulty"])): [Task!]! @hasMany
        posts(orderBy: _ @orderBy(relations: [{ relation: "comments" }])): [Post!]! @hasMany(type: PAGINATOR, defaultCount: 5)
      }

      type Task { name: String }
      type Post { title: String }
    GRAPHQL
  end

  before do
    ada = LH::User.create!(name: 'Ada', email: 'c@x.io')
    alan = LH::User.create!(name: 'Alan', email: 'a@x.io')
    LH::User.create!(name: 'Grace', email: 'b@x.io')
    2.times { |i| LH::Post.create!(title: "ada #{i}", user: ada) }
    LH::Post.create!(title: 'alan', user: alan)
    LH::Task.create!(name: 'a1', difficulty: 1, user: ada)
    LH::Task.create!(name: 'a2', difficulty: 2, user: ada)
    LH::Task.create!(name: 'b1', difficulty: 9, user: alan)
  end

  def names(field, arguments = nil)
    result = graphql("{ #{field}#{"(#{arguments})" if arguments} { name } }")
    raise result['errors'].inspect if result['errors']

    result.dig('data', field).pluck('name')
  end

  describe 'the generated types' do
    it 'types the argument with a list of <Type><Field><Arg>OrderByClause, over an enum of the columns' do
      argument = schema.types['Query'].fields['users'].arguments['orderBy']

      expect(argument.type.to_type_signature).to eq('[QueryUsersOrderByOrderByClause!]')
      expect(schema.types['QueryUsersOrderByOrderByClause'].arguments.transform_values { |a| a.type.to_type_signature })
        .to eq('column' => 'QueryUsersOrderByColumn!', 'order' => 'SortOrder!')
      expect(schema.types['QueryUsersOrderByColumn'].values.transform_values(&:value)).to eq('NAME' => 'name', 'CREATED_AT' => 'created_at')
      expect(schema.types['SortOrder'].values.keys).to eq(%w[ASC DESC])
    end

    it 'shares OrderByClause, on any column, without columns:' do
      expect(schema.types['Query'].fields['anyUsers'].arguments['orderBy'].type.to_type_signature).to eq('[OrderByClause!]')
      expect(schema.types['OrderByClause'].arguments['column'].type.to_type_signature).to eq('String!')
    end

    it 'orders by the enum columnsEnum: names' do
      expect(schema.types['QueryEnumUsersOrderByOrderByClause'].arguments['column'].type.to_type_signature).to eq('UserColumn!')
    end

    it 'offers a column or an aggregate of each relation with relations:' do
      clause = schema.types['QueryRankedUsersOrderByRelationOrderByClause']

      expect(clause.arguments.transform_values { |a| a.type.to_type_signature })
        .to eq('column' => 'QueryRankedUsersOrderByColumn', 'order' => 'SortOrder!',
               'posts' => 'QueryRankedUsersOrderByPosts', 'tasks' => 'QueryRankedUsersOrderByTasks')
      expect(schema.types['QueryRankedUsersOrderByPosts'].arguments['aggregate'].type.to_type_signature)
        .to eq('OrderByRelationAggregateFunction!')
      expect(schema.types['QueryRankedUsersOrderByTasks'].arguments.transform_values { |a| a.type.to_type_signature })
        .to eq('aggregate' => 'OrderByRelationWithColumnAggregateFunction!', 'column' => 'QueryRankedUsersOrderByTasksColumn')
    end

    it 'keeps the type of an argument written with one' do
      expect(schema.types['Query'].fields['typedUsers'].arguments['orderBy'].type.to_type_signature).to eq('[OrderByClause!]')
    end

    it 'fails on both columns: and columnsEnum:' do
      expect { build_schema('type Query { a(o: _ @orderBy(columns: ["a"], columnsEnum: "E")): [Int] }') }
        .to raise_error(Lighthouse::DefinitionError,
                        'The @orderBy directive can only have one of the following arguments: `columns`, `columnsEnum`.')
    end
  end

  describe 'on an argument' do
    it 'orders by the clauses, in turn' do
      expect(names('users', 'orderBy: [{ column: NAME, order: DESC }]')).to eq(%w[Grace Alan Ada])
      LH::User.create!(name: 'Ada', email: 'a@y.io')

      result = graphql('{ enumUsers(orderBy: [{ column: NAME, order: ASC }, { column: EMAIL, order: DESC }]) { name } }')

      expect(result.dig('data', 'enumUsers').pluck('name')).to eq(%w[Ada Ada Alan Grace])
      expect(LH::User.where(name: 'Ada').order(email: :desc).pluck(:email)).to eq(%w[c@x.io a@y.io])
    end

    it 'orders by any column of an OrderByClause' do
      expect(names('anyUsers', 'orderBy: [{ column: "email", order: ASC }]')).to eq(%w[Alan Grace Ada])
    end

    it "orders by the count of a relation's records, those without any too" do
      expect(names('rankedUsers', 'orderBy: [{ posts: { aggregate: COUNT }, order: DESC }]')).to eq(%w[Ada Alan Grace])
      expect(names('rankedUsers', 'orderBy: [{ posts: { aggregate: COUNT }, order: ASC }, { column: NAME, order: DESC }]'))
        .to eq(%w[Grace Alan Ada])
    end

    it "orders by an aggregate of a relation's column" do
      expect(names('rankedUsers', 'orderBy: [{ tasks: { aggregate: MAX, column: DIFFICULTY }, order: DESC }, { column: NAME, order: ASC }]'))
        .to eq(%w[Alan Ada Grace])
      expect(names('rankedUsers', 'orderBy: [{ tasks: { aggregate: SUM, column: DIFFICULTY }, order: ASC }, { column: NAME, order: ASC }]').last(2))
        .to eq(%w[Ada Alan])
    end

    it 'orders a page, and counts every record' do
      result = graphql('{ pagedUsers(orderBy: [{ posts: { aggregate: COUNT }, order: DESC }]) { data { name } paginatorInfo { total } } }')

      expect(result['data']).to eq('pagedUsers' => { 'data' => [{ 'name' => 'Ada' }, { 'name' => 'Alan' }], 'paginatorInfo' => { 'total' => 3 } })
    end

    it "orders a relation's records" do
      result = graphql('{ users(orderBy: [{ column: NAME, order: ASC }]) { name tasks(orderBy: [{ column: DIFFICULTY, order: DESC }]) { name } } }')

      expect(result.dig('data', 'users').first).to eq('name' => 'Ada', 'tasks' => [{ 'name' => 'a2' }, { 'name' => 'a1' }])
    end

    it "orders each parent's page of a batched relation by an aggregate" do
      LH::Comment.create!(comment: 'x', post: LH::Post.find_by(title: 'ada 1'))
      posts = 'posts(orderBy: [{ comments: { aggregate: COUNT }, order: DESC }]) { data { title } }'
      result = nil

      sql = queries_in { result = graphql("{ users(orderBy: [{ column: NAME, order: ASC }]) { #{posts} } }") }

      expect(result.dig('data', 'users').map { |u| u.dig('posts', 'data').pluck('title') }).to eq([['ada 1', 'ada 0'], ['alan'], []])
      expect(sql.grep(/lh_posts/).size).to be <= 2
    end

    it 'needs exactly one of a column and a relation in a clause' do
      expect(error_messages(graphql('{ rankedUsers(orderBy: [{ column: NAME, posts: { aggregate: COUNT }, order: ASC }]) { name } }')))
        .to eq(['An order by clause takes exactly one of: column, posts, tasks.'])
      expect(error_messages(graphql('{ rankedUsers(orderBy: [{ order: ASC }]) { name } }')))
        .to eq(['An order by clause takes exactly one of: column, posts, tasks.'])
    end

    it 'orders as the records are, for null' do
      expect(names('users', 'orderBy: null')).to eq(%w[Ada Alan Grace])
    end
  end

  describe 'on a field' do
    it 'orders by column: in direction:, whatever the client sends' do
      expect(names('latestUsers')).to eq(%w[Grace Alan Ada])
    end
  end
end
