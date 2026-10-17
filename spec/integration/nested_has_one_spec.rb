# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/HasOneTest.php
RSpec.describe 'Nested mutations: hasOne' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task {
        id: ID!
        name: String!
        post: Post @hasOne
      }

      type Post {
        id: ID!
        title: String!
        body: String
      }

      type Mutation {
        createTask(input: CreateTaskInput! @spread): Task @create
        updateTask(input: UpdateTaskInput! @spread): Task @update
        upsertTask(input: UpsertTaskInput! @spread): Task @upsert
      }

      input CreateTaskInput { name: String! post: CreatePostRelation }
      input CreatePostRelation { create: CreatePostInput upsert: UpsertPostInput }
      input CreatePostInput { title: String! }
      input UpdateTaskInput { id: ID! name: String post: UpdatePostHasOne }
      input UpdatePostHasOne { create: CreatePostInput update: UpdatePostInput upsert: UpsertPostInput delete: ID }
      input UpdatePostInput { id: ID! title: String }
      input UpsertTaskInput { id: ID name: String post: UpsertPostHasOne }
      input UpsertPostHasOne { create: CreatePostInput update: UpdatePostInput upsert: UpsertPostInput delete: ID }
      input UpsertPostInput { id: ID title: String }
    GRAPHQL
  end

  def task_mutation(action, input)
    graphql("mutation { #{action}Task(input: #{input}) { id name post { id title } } }")
  end

  def task_with_post
    LH::Task.create!(name: 'task').tap { |task| LH::Post.create!(title: 'old', task: task) }
  end

  it 'creates with a new hasOne' do
    expect_data(task_mutation(:create, '{ name: "foo", post: { create: { title: "bar" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
  end

  it 'creates with an upserted hasOne that does not exist yet, keeping its id' do
    expect_data(task_mutation(:create, '{ name: "foo", post: { upsert: { id: 2, title: "bar" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '2', 'title' => 'bar' } })
  end

  it 'upserts (creating) with an upserted hasOne' do
    expect_data(task_mutation(:upsert, '{ id: 2, name: "foo", post: { upsert: { id: 3, title: "bar" } } }'),
                'upsertTask' => { 'id' => '2', 'name' => 'foo', 'post' => { 'id' => '3', 'title' => 'bar' } })
  end

  it 'upserts a hasOne without an id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", post: { upsert: { title: "bar" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
  end

  it 'upserts a hasOne with a null id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", post: { upsert: { id: null, title: "bar" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
  end

  it 'allows null operations' do
    LH::Task.create!(name: 'task')

    expect_data(task_mutation(:update, '{ id: 1, name: "foo", post: { create: null, update: null, upsert: null, delete: null } }'),
                'updateTask' => { 'name' => 'foo', 'post' => nil })
  end

  %w[update upsert].each do |action|
    it "#{action}s with a new hasOne" do
      LH::Task.create!(name: 'task')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", post: { create: { title: "bar" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
    end

    it "#{action}s refusing to create a second hasOne" do
      task_with_post

      result = task_mutation(action, '{ id: 1, name: "foo", post: { create: { title: "bar" } } }')

      expect(error_messages(result)).to eq(['Cannot create a related model: a Post already exists for this Task. ' \
                                            'Use upsert to modify the existing model.'])
      expect(LH::Post.count).to eq(1)
    end

    it "#{action}s and updates the hasOne" do
      task_with_post

      expect_data(task_mutation(action, '{ id: 1, name: "foo", post: { update: { id: 1, title: "bar" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
    end

    it "#{action}s and upserts the hasOne" do
      task_with_post

      expect_data(task_mutation(action, '{ id: 1, name: "foo", post: { upsert: { id: 1, title: "bar" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
    end

    it "#{action}s and upserts the existing hasOne when no id is given" do
      task_with_post

      expect_data(task_mutation(action, '{ id: 1, name: "foo", post: { upsert: { title: "bar" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'post' => { 'id' => '1', 'title' => 'bar' } })
      expect(LH::Post.count).to eq(1)
    end

    it "#{action}s and deletes the hasOne" do
      task_with_post

      expect_data(task_mutation(action, '{ id: 1, name: "foo", post: { delete: 1 } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'post' => nil })
      expect(LH::Post.count).to eq(0)
    end
  end
end
