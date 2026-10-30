# frozen_string_literal: true

# Pages are cut by position, so the order of a paginated query ends with the
# primary key: rows the field's order ties stay in one order from page to page.
RSpec.describe 'The order of a paginated query' do
  include_context 'with PHP Lighthouse models'

  let(:schema) do
    build_schema(<<~GRAPHQL, dataloader: true)
      type Query {
        widgets(orderBy: _ @orderBy(columns: ["rank"])): [Widget!]! @paginate(defaultCount: 2)
        byId: [Widget!]! @paginate(defaultCount: 2) @orderBy(column: "id", direction: DESC)
        users: [User!]! @all(model: "LH::User")
      }

      type Widget { id: ID! name: String }
      type User { name: String tasks: [Task!]! @hasMany(type: PAGINATOR, defaultCount: 2) @orderBy(column: "difficulty") }
      type Task { name: String }
    GRAPHQL
  end

  def selects(table, &block)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT .*#{table}/i) && payload[:sql].exclude?('COUNT') }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    queries
  end

  def names(query, *path) = schema.execute(query).to_h.dig('data', *path).pluck('name')

  it 'ends the ORDER BY of a page with the primary key, so tied rows keep their order across pages' do
    %w[d c b a].each { |name| Widget.create!(name: name, rank: 1) }
    query = ->(page) { "{ widgets(orderBy: [{ column: RANK, order: ASC }], page: #{page}) { data { name } } }" }

    sql = selects('widgets') { names(query.call(1), 'widgets', 'data') }
    expect(sql.first).to match(/ORDER BY "widgets"."rank" ASC, "widgets"."id" ASC/)
    expect(names(query.call(1), 'widgets', 'data') + names(query.call(2), 'widgets', 'data')).to eq(%w[d c b a])
  end

  it 'leaves an order that already ends with the primary key alone' do
    Widget.create!(name: 'a')

    expect(selects('widgets') { names('{ byId { data { name } } }', 'byId', 'data') }.first).to match(/ORDER BY "widgets"."id" DESC LIMIT/)
  end

  it "numbers each parent's rows by the order, then the primary key, in a batched relation" do
    ada = LH::User.create!(name: 'ada')
    %w[z y x].each { |name| ada.tasks.create!(name: name, difficulty: 1) }

    sql = selects('lh_tasks') { schema.execute('{ users { tasks { data { name } } } }') }
    expect(sql.join).to match(/ORDER BY "lh_tasks"."difficulty" ASC, "lh_tasks"."id" ASC\)/)
  end
end
