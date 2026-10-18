# frozen_string_literal: true

# Analyzers @complexity(resolver:) names: graphql-ruby's own, some with the
# concern that gives the fields naming them their cost.
module ComplexitySpec
  # A plain graphql-ruby analyzer: installed on the schema, it runs on every query.
  class FieldCounter < GraphQL::Analysis::Analyzer
    def on_enter_field(_node, _parent, visitor)
      @count = (@count || 0) + 1 unless visitor.skipping?
    end

    def result
      query.context[:fields_counted] = @count
      nil
    end
  end

  class LimitCost < GraphQL::Analysis::QueryComplexity
    include Lighthouse::GraphQL::ComplexityAnalyzer

    complexity ->(_context, args, child_complexity) { 2 + (child_complexity * args[:limit]) }
  end

  class FlatCost < GraphQL::Analysis::Analyzer
    include Lighthouse::GraphQL::ComplexityAnalyzer

    complexity 7
  end

  class InheritedCost < FlatCost; end

  class NoCost < GraphQL::Analysis::QueryComplexity
    include Lighthouse::GraphQL::ComplexityAnalyzer
  end

  # Gives its field a cost, and refuses a query over the context's budget.
  class Budget < GraphQL::Analysis::QueryComplexity
    include Lighthouse::GraphQL::ComplexityAnalyzer

    complexity 50

    def result
      budget = query.context[:budget]
      cost = max_possible_complexity
      GraphQL::AnalysisError.new("Over budget: #{cost} > #{budget}") if budget && cost > budget
    end
  end

  class Report < GraphQL::Schema::Resolver
    complexity 30

    def resolve = []
  end

  # Query.expensiveReport and Mutation.recompute resolve to these by convention.
  class ExpensiveReport < GraphQL::Schema::Resolver
    complexity 25

    def resolve = 'report'
  end

  class Recompute < GraphQL::Schema::Mutation
    complexity ->(_context, args, child_complexity) { (args[:times] * 10) + child_complexity }

    def resolve(times:) = times
  end
end

RSpec.describe '@complexity' do
  # FlatCost is named without its namespace, so it is looked up in Analyzers.
  before { stub_const('Analyzers::FlatCost', ComplexitySpec::FlatCost) }

  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Widget {
        id: ID!
        name: String
        parts: [Widget!]! @hasMany(type: PAGINATOR, defaultCount: 3)
      }

      type Query {
        widgets: [Widget!]! @paginate(model: "Widget", defaultCount: 5)
        widgetConnection: [Widget!]! @paginate(model: "Widget", type: CONNECTION, defaultCount: 5)
        widgetList: [Widget!]! @all(model: "Widget")
        search(first: Int): [Widget!]! @all(model: "Widget") @complexity
        limited(limit: Int!): [Widget!]! @all(model: "Widget") @complexity(resolver: "ComplexitySpec::LimitCost")
        flat: [Widget!]! @all(model: "Widget") @complexity(resolver: "FlatCost")
        pagedFlat: [Widget!]! @paginate(model: "Widget") @complexity(resolver: "FlatCost")
        inherited: [Widget!]! @all(model: "Widget") @complexity(resolver: "ComplexitySpec::InheritedCost")
        noCost(first: Int): [Widget!]! @all(model: "Widget") @complexity(resolver: "ComplexitySpec::NoCost")
        counted: [Widget!]! @all(model: "Widget") @complexity(resolver: "ComplexitySpec::FieldCounter")
        expensiveReport: String
        report: [Widget!]! @field(resolver: "ComplexitySpec::Report")
      }

      type Mutation {
        recompute(times: Int!): Int
      }
    GRAPHQL
  end

  # The score graphql-ruby's own analyzer gives the query.
  def complexity_of(query, **options)
    schema.complexity_cost_calculation_mode(:future)
    GraphQL::Analysis.analyze_query(GraphQL::Query.new(schema, query, **options), [GraphQL::Analysis::QueryComplexity]).first
  end

  describe 'on its own' do
    it 'costs the field plus its selection once per item asked for in `first`' do
      expect(complexity_of('{ search(first: 4) { id name } }')).to eq(1 + (2 * 4))
    end

    it 'costs graphql-ruby\'s default without `first`' do
      expect(complexity_of('{ search { id name } }')).to eq(1 + 2)
    end
  end

  describe 'on paginated fields, with no @complexity' do
    it 'scales a paginator by `first`' do
      expect(complexity_of('{ widgets(first: 10) { data { id name } } }')).to eq(1 + (3 * 10))
      expect(complexity_of('{ widgets(first: 100) { data { id name } } }')).to eq(1 + (3 * 100))
    end

    it 'scales by the page size when `first` is left out' do
      expect(complexity_of('{ widgets { data { id } } }')).to eq(1 + (2 * 5))
    end

    it "scales a connection by its page size, where graphql-ruby's own scaling cannot see defaultCount" do
      expect(complexity_of('{ widgetConnection { edges { node { id } } } }')).to eq(1 + (3 * 5))
    end

    it 'scales a paginated relationship' do
      expect(complexity_of('{ widgetList { parts(first: 4) { data { id } } } }')).to eq(1 + (1 + (2 * 4)))
      expect(complexity_of('{ widgetList { parts { data { id } } } }')).to eq(1 + (1 + (2 * 3)))
    end

    it "leaves a plain list to graphql-ruby's default" do
      expect(complexity_of('{ widgetList { id name } }')).to eq(1 + 2)
    end
  end

  describe 'naming an analyzer' do
    it 'installs it on the schema once, however many fields name it' do
      expect(schema.query_analyzers).to include(ComplexitySpec::FieldCounter, ComplexitySpec::LimitCost, ComplexitySpec::FlatCost)
      expect(schema.query_analyzers.count(ComplexitySpec::FlatCost)).to eq(1)
    end

    it 'runs a plain analyzer on every query, as graphql-ruby runs it' do
      result = schema.execute('{ widgetList { id name } }')

      expect(result.query.context[:fields_counted]).to eq(3)
    end

    it 'costs the field as a bare @complexity when the analyzer has no concern' do
      expect(complexity_of('{ counted { id } }')).to eq(1 + 1)
    end

    it "takes the concern's complexity, a proc given graphql-ruby's arguments" do
      expect(complexity_of('{ limited(limit: 3) { id name } }')).to eq(2 + (2 * 3))
      expect(complexity_of('query($n: Int!) { limited(limit: $n) { id } }', variables: { 'n' => 10 })).to eq(2 + 10)
    end

    it "takes the concern's complexity, a number added to the selection's, from the Analyzers namespace" do
      expect(complexity_of('{ flat { id name } }')).to eq(7 + 2)
    end

    it 'wins over the pagination default' do
      expect(complexity_of('{ pagedFlat(first: 10) { data { id } } }')).to eq(7 + 2)
    end

    it 'inherits the complexity of a superclass' do
      expect(complexity_of('{ inherited { id } }')).to eq(7 + 1)
    end

    it 'costs the field as a bare @complexity when the concern sets no complexity' do
      expect(complexity_of('{ noCost(first: 4) { id } }')).to eq(1 + (1 * 4))
    end

    it 'leaves a concern class without a `result` of its own out of the analysis' do
      query = GraphQL::Query.new(schema, '{ flat { id } }')

      expect(ComplexitySpec::LimitCost.new(query).analyze?).to be(false)
      expect(ComplexitySpec::Budget.new(query).analyze?).to be(true)
    end

    it 'runs the `result` of a concern class, which may refuse the query' do
      budgeted = build_schema(<<~GRAPHQL)
        type Widget { id: ID! }
        type Query { widgets: [Widget!]! @all(model: "Widget") @complexity(resolver: "ComplexitySpec::Budget") }
      GRAPHQL

      refused = budgeted.execute('{ widgets { id } }', context: { budget: 10 })
      allowed = budgeted.execute('{ widgets { id } }', context: { budget: 100 })

      expect(refused['errors'].pluck('message')).to eq(['Over budget: 51 > 10'])
      expect(allowed['errors']).to be_nil
    end

    it 'refuses to build with a class that cannot be found' do
      expect { build_schema('type Query { a: Int @complexity(resolver: "Nowhere") }') }
        .to raise_error(Lighthouse::DefinitionError, '@complexity on Query.a: no analyzer Nowhere (looked up in Analyzers)')
    end

    it 'refuses to build with a class that is not a GraphQL::Analysis::Analyzer' do
      expect { build_schema('type Query { a: Int @complexity(resolver: "Widget") }') }
        .to raise_error(Lighthouse::DefinitionError, '@complexity on Query.a: Widget must inherit from GraphQL::Analysis::Analyzer')
    end

    it 'refuses a complexity that is neither a number nor a three-argument proc' do
      analyzer = Class.new(GraphQL::Analysis::Analyzer) { include Lighthouse::GraphQL::ComplexityAnalyzer }

      expect { analyzer.complexity('10') }.to raise_error(ArgumentError, /takes a number or a proc/)
      expect { analyzer.complexity(->(child_complexity) { child_complexity }) }.to raise_error(ArgumentError)
    end
  end

  describe 'on fields a GraphQL::Schema::Resolver class resolves' do
    before do
      stub_const('Resolvers::ExpensiveReport', ComplexitySpec::ExpensiveReport)
      stub_const('Mutations::Recompute', ComplexitySpec::Recompute)
    end

    it 'takes the complexity of the class a root field resolves to by convention' do
      expect(complexity_of('{ expensiveReport }')).to eq(25)
    end

    it 'takes the complexity of a mutation class, a proc given the arguments' do
      expect(complexity_of('mutation { recompute(times: 3) }')).to eq(30)
    end

    it 'takes the complexity of the class @field names' do
      expect(complexity_of('{ report { id } }')).to eq(30 + 1)
    end
  end

  describe "with graphql-ruby's max_complexity" do
    before { schema.max_complexity(50) }

    it 'rejects a query over it before running it' do
      result = schema.execute('{ widgets(first: 100) { data { id } } }')

      expect(result['data']).to be_nil
      expect(result['errors'].pluck('message'))
        .to eq(['Query has complexity of 201, which exceeds max complexity of 50'])
    end

    it 'runs a query under it' do
      Widget.create!(name: 'w')

      result = schema.execute('{ widgets(first: 10) { data { name } } }')

      expect(result['errors']).to be_nil
      expect(result['data']['widgets']['data']).to eq([{ 'name' => 'w' }])
    end
  end

  describe 'BuildExtensionsResponse#query_complexity' do
    it 'is the score max_complexity is checked against' do
      seen = []
      Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) { |event| seen << event.query_complexity }

      schema.execute('{ widgets(first: 10) { data { id name } } }')

      expect(seen).to eq([1 + (3 * 10)])
    end

    it 'is nil for a query that failed validation' do
      seen = []
      Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) { |event| seen << event.query_complexity }

      schema.execute('{ nope }')

      expect(seen).to eq([nil])
    end

    it 'is not computed while nothing listens' do
      result = schema.execute('{ widgets(first: 10) { data { id } } }')

      expect(Lighthouse::GraphQL::Complexity.query_complexity(result.query)).to be_nil
    end
  end
end
