# frozen_string_literal: true

# @whereConditions and @whereHasConditions as PHP Lighthouse's: the types they
# generate for an argument written as `_`, and the conditions a client builds
# with them, through a real schema and database.
RSpec.describe '@whereConditions and @whereHasConditions' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users(where: _ @whereConditions(columns: ["name", "email"])): [User!]! @all
        paginatedUsers(filter: _ @whereConditions(columns: ["name"])): [User!]! @paginate(model: "User", defaultCount: 10)
        anyUsers(where: _ @whereConditions): [User!]! @all(model: "User")
        withPosts(hasPosts: _ @whereHasConditions(columns: ["title"])): [User!]! @all(model: "User")
        withWork(work: _ @whereHasConditions(relation: "tasks")): [User!]! @all(model: "User")
      }

      type User {
        name: String
        tasks(where: _ @whereConditions(columns: ["difficulty"])): [Task!]! @hasMany
      }

      type Task { name: String }
    GRAPHQL
  end

  before do
    ada = LH::User.create!(name: 'Ada', email: 'ada@a.io')
    alan = LH::User.create!(name: 'Alan', email: 'alan@b.io')
    LH::User.create!(name: 'Grace', email: nil)
    LH::Post.create!(title: 'Notes', user: ada)
    LH::Post.create!(title: 'Engines', user: ada)
    LH::Post.create!(title: 'Machines', user: alan)
    LH::Task.create!(name: 'a1', difficulty: 1, user: ada)
    LH::Task.create!(name: 'a2', difficulty: 5, user: ada)
    LH::Task.create!(name: 'b1', difficulty: 3, user: alan)
  end

  def names(field, arguments)
    result = graphql("{ #{field}(#{arguments}) { name } }")
    raise result['errors'].inspect if result['errors']

    result.dig('data', field).pluck('name')
  end

  describe 'the generated types' do
    it 'types the argument with <Type><Field><Arg>WhereConditions, over an enum of the columns' do
      expect(schema.types['Query'].fields['users'].arguments['where'].type.graphql_name).to eq('QueryUsersWhereWhereConditions')
      expect(schema.types['QueryUsersWhereColumn'].values.transform_values(&:value)).to eq('NAME' => 'name', 'EMAIL' => 'email')
      expect(schema.types['QueryUsersWhereWhereConditions'].arguments.keys).to eq(%w[column operator value AND OR HAS])
    end

    it 'checks related records with a HAS on any column of theirs' do
      relation = schema.types['QueryUsersWhereWhereConditionsRelation']

      expect(relation.arguments.keys).to eq(%w[relation operator amount condition])
      expect(relation.arguments['condition'].type.graphql_name).to eq('QueryUsersWhereWhereConditionsHasCondition')
      expect(schema.types['QueryUsersWhereWhereConditionsHasCondition'].arguments['column'].type.graphql_name).to eq('String')
    end

    it 'shares WhereConditions, on any column, without columns:' do
      expect(schema.types['Query'].fields['anyUsers'].arguments['where'].type.graphql_name).to eq('WhereConditions')
      expect(schema.types['WhereConditions'].arguments['column'].type.graphql_name).to eq('String')
    end

    it 'names a @whereHasConditions argument <Type><Field><Arg>WhereHasConditions' do
      expect(schema.types['Query'].fields['withPosts'].arguments['hasPosts'].type.graphql_name)
        .to eq('QueryWithPostsHasPostsWhereHasConditions')
    end

    it "offers PHP Lighthouse's SQL operators" do
      expect(schema.types['SQLOperator'].values.keys)
        .to eq(%w[EQ NEQ GT GTE LT LTE LIKE NOT_LIKE IN NOT_IN BETWEEN NOT_BETWEEN IS_NULL IS_NOT_NULL])
    end
  end

  describe '@whereConditions' do
    it 'filters by one condition, EQ by default' do
      expect(names('users', 'where: { column: NAME, value: "Alan" }')).to eq(['Alan'])
    end

    it 'compares with the operator' do
      expect(names('users', 'where: { column: NAME, operator: LIKE, value: "A%" }')).to contain_exactly('Ada', 'Alan')
      expect(names('users', 'where: { column: NAME, operator: NEQ, value: "Ada" }')).to contain_exactly('Alan', 'Grace')
      expect(names('users', 'where: { column: NAME, operator: IN, value: ["Ada", "Grace"] }')).to contain_exactly('Ada', 'Grace')
      expect(names('users', 'where: { column: NAME, operator: NOT_IN, value: ["Ada", "Grace"] }')).to eq(['Alan'])
      expect(names('users', 'where: { column: NAME, operator: BETWEEN, value: ["Al", "Am"] }')).to eq(['Alan'])
      expect(names('users', 'where: { column: EMAIL, operator: IS_NULL }')).to eq(['Grace'])
      expect(names('users', 'where: { column: EMAIL, operator: IS_NOT_NULL }')).to contain_exactly('Ada', 'Alan')
    end

    it 'requires every condition of an AND' do
      expect(names('users', 'where: { AND: [{ column: NAME, operator: LIKE, value: "A%" }, { column: EMAIL, operator: LIKE, value: "%a.io" }] }'))
        .to eq(['Ada'])
    end

    it 'requires one condition of an OR, and the level\'s other conditions' do
      expect(names('users', 'where: { OR: [{ column: NAME, value: "Alan" }, { column: NAME, value: "Grace" }] }')).to contain_exactly('Alan', 'Grace')
      expect(names('users',
                   'where: { column: EMAIL, operator: IS_NOT_NULL, OR: [{ column: NAME, value: "Alan" }, { column: NAME, value: "Grace" }] }'))
        .to eq(['Alan'])
    end

    it 'nests OR inside AND' do
      either = '{ OR: [{ column: NAME, value: "Grace" }, { column: NAME, value: "Alan" }] }'
      where = "{ AND: [{ column: EMAIL, operator: LIKE, value: \"%.io\" }, #{either}] }"

      expect(names('users', "where: #{where}")).to eq(['Alan'])
    end

    it 'filters by related records with HAS' do
      expect(names('users', 'where: { HAS: { relation: "posts" } }')).to contain_exactly('Ada', 'Alan')
      expect(names('users', 'where: { HAS: { relation: "posts", condition: { column: "title", value: "Machines" } } }')).to eq(['Alan'])
    end

    it 'counts the related records with HAS operator and amount' do
      expect(names('users', 'where: { HAS: { relation: "posts", amount: 2 } }')).to eq(['Ada'])
      expect(names('users', 'where: { HAS: { relation: "posts", operator: LT, amount: 1 } }')).to eq(['Grace'])
      expect(names('users',
                   'where: { HAS: { relation: "tasks", operator: EQ, amount: 1, condition: { column: "difficulty", operator: GT, value: 2 } } }'))
        .to contain_exactly('Ada', 'Alan')
    end

    it 'nests HAS in a HAS condition' do
      LH::Comment.create!(comment: 'first!', post: LH::Post.find_by(title: 'Engines'))

      expect(names('users', 'where: { HAS: { relation: "posts", condition: { HAS: { relation: "comments" } } } }')).to eq(['Ada'])
    end

    it 'filters nothing when the argument is null' do
      expect(names('users', 'where: null')).to contain_exactly('Ada', 'Alan', 'Grace')
    end

    it 'takes any argument name, on @paginate too' do
      result = graphql('{ paginatedUsers(filter: { column: NAME, value: "Ada" }) { data { name } paginatorInfo { total } } }')

      expect(result['data']).to eq('paginatedUsers' => { 'data' => [{ 'name' => 'Ada' }], 'paginatorInfo' => { 'total' => 1 } })
    end

    it "filters a relation's records" do
      result = graphql('{ users(where: { column: NAME, value: "Ada" }) { tasks(where: { column: DIFFICULTY, operator: GTE, value: 2 }) { name } } }')

      expect(result['data']).to eq('users' => [{ 'tasks' => [{ 'name' => 'a2' }] }])
    end

    it 'takes any identifier as the column of an unrestricted WhereConditions' do
      expect(names('anyUsers', 'where: { column: "lh_users.name", value: "Grace" }')).to eq(['Grace'])
      expect(error_messages(graphql('{ anyUsers(where: { column: "name; DROP TABLE lh_users", value: 1 }) { name } }')))
        .to eq(['Column names may contain only alphanumerics or underscores, optionally a table and a JSON path (posts.meta->tags), ' \
                'and may not begin with a digit, got: name; DROP TABLE lh_users'])
    end

    it 'needs a value, unless the operator takes none' do
      expect(error_messages(graphql('{ users(where: { column: NAME }) { name } }')))
        .to eq(['Did not receive a value to match the WhereConditions for column name.'])
    end

    it 'fails on a relation the model does not have' do
      expect(error_messages(graphql('{ users(where: { HAS: { relation: "friends" } }) { name } }'))).to eq(['LH::User has no relation friends.'])
    end
  end

  describe '@whereHasConditions' do
    it 'keeps the records whose related records match, the relation named by has<Relation>' do
      expect(names('withPosts', 'hasPosts: { column: TITLE, operator: LIKE, value: "%ines" }')).to contain_exactly('Ada', 'Alan')
      expect(names('withPosts', 'hasPosts: { OR: [{ column: TITLE, value: "Notes" }, { column: TITLE, value: "Nope" }] }')).to eq(['Ada'])
    end

    it 'keeps the records with any related record for {}, and filters nothing for null' do
      expect(names('withPosts', 'hasPosts: {}')).to contain_exactly('Ada', 'Alan')
      expect(names('withPosts', 'hasPosts: null')).to contain_exactly('Ada', 'Alan', 'Grace')
    end

    it 'takes the relation from relation:' do
      expect(names('withWork', 'work: { column: "difficulty", operator: GTE, value: 5 }')).to eq(['Ada'])
    end
  end

  describe 'a handler' do
    let(:sdl) do
      <<~GRAPHQL
        type Query { users(where: _ @whereConditions(columns: ["name"], handler: "NameStarts")): [User!]! @all }
        type User { name: String }
      GRAPHQL
    end

    it 'applies the conditions with the class handler: names' do
      stub_const('Builders::NameStarts', Class.new do
        def self.call(relation, conditions) = relation.where('name LIKE ?', "#{conditions[:value]}%")
      end)

      expect(names('users', 'where: { column: NAME, value: "Gr" }')).to eq(['Grace'])
    end
  end
end
