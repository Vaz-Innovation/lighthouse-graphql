# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/MorphToManyTest.php
# Task has_many :tags, through: :taggables (a polymorphic join, as: :taggable).
RSpec.describe 'Nested mutations: morphToMany' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Mutation {
        createTask(input: CreateTaskInput! @spread): Task @create
        upsertTask(input: UpsertTaskInput! @spread): Task @upsert
      }

      input CreateTaskInput { name: String! tags: CreateTagRelation }
      input CreateTagRelation { create: [CreateTagInput!] upsert: [UpsertTagInput!] sync: [ID!] connect: [ID!] }
      input CreateTagInput { name: String! }
      input UpsertTaskInput { id: ID name: String! tags: UpsertTagRelation }
      input UpsertTagRelation { create: [CreateTagInput!] upsert: [UpsertTagInput!] sync: [ID!] connect: [ID!] }
      input UpsertTagInput { id: ID name: String! }

      type Task { id: ID! name: String! tags: [Tag!]! @morphToMany }
      type Tag { id: ID! name: String! }
    GRAPHQL
  end

  def task_mutation(action, input)
    graphql("mutation { #{action}Task(input: #{input}) { id name tags { id name } } }")
  end

  %w[connect sync].each do |operation|
    it "creates a task with existing tags using #{operation}" do
      LH::Tag.create!(name: 'php')

      expect_data(task_mutation(:create, "{ name: \"Finish tests\", tags: { #{operation}: [1] } }"),
                  'createTask' => { 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
      expect(LH::Taggable.first.attributes.slice('tag_id', 'taggable_id', 'taggable_type'))
        .to eq('tag_id' => 1, 'taggable_id' => 1, 'taggable_type' => 'LH::Task')
    end

    it "upserts a task with existing tags using #{operation}" do
      LH::Tag.create!(name: 'php')

      expect_data(task_mutation(:upsert, "{ id: 1, name: \"Finish tests\", tags: { #{operation}: [1] } }"),
                  'upsertTask' => { 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
    end
  end

  it 'allows null operations' do
    expect_data(task_mutation(:create, '{ name: "Finish tests", tags: { create: null, upsert: null, sync: null, connect: null } }'),
                'createTask' => { 'name' => 'Finish tests', 'tags' => [] })
  end

  it 'creates a new tag while creating' do
    expect_data(task_mutation(:create, '{ name: "Finish tests", tags: { create: [{ name: "php" }] } }'),
                'createTask' => { 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
  end

  it 'creates a new tag while upserting' do
    expect_data(task_mutation(:upsert, '{ id: 1, name: "Finish tests", tags: { create: [{ name: "php" }] } }'),
                'upsertTask' => { 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
  end

  it 'upserts a new tag while upserting' do
    expect_data(task_mutation(:upsert, '{ id: 1, name: "Finish tests", tags: { upsert: [{ id: 1, name: "php" }] } }'),
                'upsertTask' => { 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
  end

  it 'upserts tags without an id' do
    expect_data(task_mutation(:upsert, '{ name: "Finish tests", tags: { upsert: [{ name: "php" }] } }'),
                'upsertTask' => { 'id' => '1', 'tags' => [{ 'id' => '1', 'name' => 'php' }] })
  end

  it 'syncs a polymorphic join without touching other owners' do
    LH::Tag.create!(name: 'php')
    LH::Tag.create!(name: 'ruby')
    other = LH::Task.create!(name: 'other')
    other.tags << LH::Tag.find(1)

    task_mutation(:create, '{ name: "mine", tags: { sync: [1, 2] } }')
    task_mutation(:upsert, '{ id: 2, name: "mine", tags: { sync: [2] } }')

    expect(LH::Task.find(2).tags.pluck(:id)).to eq([2])
    expect(other.tags.reload.pluck(:id)).to eq([1])
  end
end
