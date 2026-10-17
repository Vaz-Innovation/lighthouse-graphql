# frozen_string_literal: true

require 'spec_helper'

RSpec.describe '@withoutGlobalScopes' do
  def titles(schema, query)
    result = schema.execute(query).to_h
    raise result['errors'].inspect if result['errors']

    result['data']['posts'].map { |row| row['title'] }
  end

  def sdl(names)
    <<~GRAPHQL
      type ScheduledPost { id: ID! title: String }
      type Query {
        posts(includeUnscheduled: Boolean @withoutGlobalScopes(names: #{names.inspect})): [ScheduledPost!]! @all
      }
    GRAPHQL
  end

  before do
    ScheduledPost.unscoped.create!(title: 'scheduled', schedule_at: Time.current)
    ScheduledPost.unscoped.create!(title: 'draft', archived: true)
  end

  context 'with a model scope and a default scope' do
    let(:schema) { build_schema(sdl(['scheduled'])) }

    it 'keeps the default scope when the argument is omitted' do
      expect(titles(schema, '{ posts { title } }')).to eq(['scheduled'])
    end

    it 'keeps the default scope when the client passes false' do
      expect(titles(schema, '{ posts(includeUnscheduled: false) { title } }')).to eq(['scheduled'])
    end

    it 'removes the scope when the client passes true, through without_<name>' do
      expect(titles(schema, '{ posts(includeUnscheduled: true) { title } }')).to contain_exactly('scheduled', 'draft')
    end
  end

  it 'unscopes a column of that name, in camelCase' do
    schema = build_schema(sdl(['scheduleAt']))

    expect(titles(schema, '{ posts { title } }')).to eq(['scheduled'])
    expect(titles(schema, '{ posts(includeUnscheduled: true) { title } }')).to contain_exactly('scheduled', 'draft')
  end

  it 'prefers an app-defined without_<name> scope over the column' do
    # without_archived lifts the default scope and keeps the archived rows; unscoping the archived column would change nothing.
    schema = build_schema(sdl(['archived']))

    expect(titles(schema, '{ posts(includeUnscheduled: true) { title } }')).to eq(['draft'])
  end

  it 'accepts the name of a scope class, with its Scope suffix' do
    schema = build_schema(sdl(['ScheduledScope']))

    expect(titles(schema, '{ posts(includeUnscheduled: true) { title } }')).to contain_exactly('scheduled', 'draft')
  end

  it 'omits any number of scopes' do
    schema = build_schema(sdl(%w[scheduled archived]))

    expect(titles(schema, '{ posts(includeUnscheduled: true) { title } }')).to eq(['draft'])
  end

  it 'includes trashed records for a soft-delete name' do
    HiddenTask.create!(name: 'kept')
    HiddenTask.unscoped.create!(name: 'trashed', deleted_at: Time.current)
    schema = build_schema(<<~GRAPHQL)
      type HiddenTask { id: ID! name: String }
      type Query { posts(withTrashed: Boolean @withoutGlobalScopes(names: ["softDeletes"])): [HiddenTask!]! @all(model: "HiddenTask") }
    GRAPHQL

    expect(schema.execute('{ posts { name } }').to_h['data']['posts'].size).to eq(1)
    expect(schema.execute('{ posts(withTrashed: true) { name } }').to_h['data']['posts'].size).to eq(2)
  end

  it 'reports a name that matches no scope or column' do
    schema = build_schema(sdl(['nonsense']))

    message = schema.execute('{ posts(includeUnscheduled: true) { title } }').to_h['errors'].first['message']

    expect(message).to eq('Cannot omit the global scope nonsense: ScheduledPost has no without_nonsense scope or nonsense column.')
  end

  it 'composes with the other argument filters' do
    schema = build_schema(<<~GRAPHQL)
      type ScheduledPost { id: ID! title: String }
      type Query {
        posts(title: String @eq, all: Boolean @withoutGlobalScopes(names: ["scheduled"])): [ScheduledPost!]! @all
      }
    GRAPHQL

    result = schema.execute('{ posts(title: "draft", all: true) { title } }').to_h

    expect(result['data']['posts']).to eq([{ 'title' => 'draft' }])
  end

  it 'works on a paginated field' do
    schema = build_schema(<<~GRAPHQL)
      type ScheduledPost { id: ID! title: String }
      type Query {
        posts(all: Boolean @withoutGlobalScopes(names: ["scheduled"])): [ScheduledPost!]! @paginate(defaultCount: 10)
      }
    GRAPHQL

    result = schema.execute('{ posts(all: true) { paginatorInfo { total } } }').to_h

    expect(result.dig('data', 'posts', 'paginatorInfo', 'total')).to eq(2)
  end
end
