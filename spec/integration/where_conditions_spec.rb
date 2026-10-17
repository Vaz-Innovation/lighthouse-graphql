# frozen_string_literal: true

# @whereConditions through a real schema: graphql-ruby hands the generated
# input over with Ruby-style keys (:and, :or, :has), which must still combine.
RSpec.describe '@whereConditions' do
  include_context 'with PHP Lighthouse models'

  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Query {
        users(where: _ @whereConditions(columns: ["name", "email", "title"])): [User!]! @all
      }

      type User { name: String }
    GRAPHQL
  end

  before do
    ada = LH::User.create!(name: 'Ada', email: 'ada@a.io')
    LH::User.create!(name: 'Alan', email: 'alan@b.io')
    LH::User.create!(name: 'Grace', email: 'grace@a.io')
    LH::Post.create!(title: 'Notes', user: ada)
  end

  def names(where)
    result = schema.execute("{ users(where: #{where}) { name } }").to_h
    raise result['errors'].inspect if result['errors']

    result.dig('data', 'users').pluck('name')
  end

  it 'filters by a single condition' do
    expect(names('{ column: NAME, operator: STARTS_WITH, value: "A" }')).to contain_exactly('Ada', 'Alan')
  end

  it 'narrows with AND' do
    expect(names('{ AND: [{ column: NAME, operator: STARTS_WITH, value: "A" }, { column: EMAIL, operator: ENDS_WITH, value: "a.io" }] }'))
      .to eq(['Ada'])
  end

  it 'widens with OR' do
    expect(names('{ OR: [{ column: NAME, value: "Alan" }, { column: NAME, value: "Grace" }] }')).to contain_exactly('Alan', 'Grace')
  end

  it 'nests OR inside AND' do
    where = '{ AND: [{ column: EMAIL, operator: ENDS_WITH, value: "a.io" }, ' \
            '{ OR: [{ column: NAME, value: "Grace" }, { column: NAME, value: "Alan" }] }] }'

    expect(names(where)).to eq(['Grace'])
  end

  it 'filters by related records with HAS' do
    expect(names('{ HAS: { relation: "posts", condition: { column: TITLE, value: "Notes" } } }')).to eq(['Ada'])
  end
end
