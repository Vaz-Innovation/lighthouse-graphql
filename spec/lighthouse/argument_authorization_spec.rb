# frozen_string_literal: true

# Users are hashes: { role: :admin | :reader }.
class SoftTaskPolicy
  def initialize(user, _record)
    @user = user || {}
  end

  def view_trashed? = @user[:role] == :admin
end

# @canModel on an argument or input field: who may use it, checked only when
# the client gives it a value. @softDeletes(ability:) puts one on `trashed`.
RSpec.describe '@canModel on arguments' do
  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Query {
        tasks: [SoftTask!]! @all @softDeletes(ability: "view_trashed")
        search(filter: TaskFilter): [SoftTask!]! @all
        each(filters: [TaskFilter!]): [SoftTask!]! @all
        quiet(trashed: Trashed @trashed @canModel(ability: "view_trashed", model: "SoftTask", action: RETURN_VALUE, returnValue: [])): [SoftTask!]! @all
      }

      input TaskFilter {
        name: String @eq
        trashed: Trashed @trashed @canModel(ability: "view_trashed", model: "SoftTask")
      }

      type SoftTask { id: ID! name: String }
    GRAPHQL
  end
  let(:admin) { { role: :admin } }
  let(:reader) { { role: :reader } }

  before do
    Lighthouse.configure { |config| config.policy_user = ->(ctx) { ctx[:current_user] } }
    SoftTask.create!(name: 'live')
    SoftTask.create!(name: 'gone', deleted_at: Time.current)
  end

  def run(query, user) = schema.execute(query, context: { current_user: user }).to_h
  def names(query, user, field) = run(query, user).dig('data', field).pluck('name')
  def messages(query, user) = run(query, user)['errors'].pluck('message')

  it '@softDeletes(ability:) lets only who the policy allows pass trashed' do
    expect(names('{ tasks { name } }', reader, 'tasks')).to eq(%w[live gone])
    expect(messages('{ tasks(trashed: ONLY) { name } }', reader)).to eq(['This action is unauthorized.'])
    expect(names('{ tasks(trashed: ONLY) { name } }', admin, 'tasks')).to eq(%w[gone])
  end

  it 'checks an input field, in one input or each of a list, only when the client gives it' do
    expect(names('{ search(filter: { name: "live" }) { name } }', reader, 'search')).to eq(%w[live])
    expect(messages('{ search(filter: { trashed: WITH }) { name } }', reader)).to eq(['This action is unauthorized.'])
    expect(messages('{ each(filters: [{ name: "live" }, { trashed: ONLY }]) { name } }', reader)).to eq(['This action is unauthorized.'])
    expect(names('{ each(filters: [{ trashed: ONLY }]) { name } }', admin, 'each')).to eq(%w[gone])
  end

  it "follows the directive's action:" do
    expect(run('{ quiet(trashed: WITH) { name } }', reader)).to eq('data' => { 'quiet' => [] })
  end
end
