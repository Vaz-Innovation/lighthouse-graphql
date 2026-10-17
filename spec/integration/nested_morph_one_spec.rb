# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/MorphOneTest.php
RSpec.describe 'Nested mutations: morphOne' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task { id: ID! name: String! image: Image @morphOne }
      type Image { id: ID! url: String }

      type Mutation {
        createTask(input: CreateTaskInput! @spread): Task @create
        updateTask(input: UpdateTaskInput! @spread): Task @update
        upsertTask(input: UpsertTaskInput! @spread): Task @upsert
      }

      input CreateTaskInput { name: String! image: CreateImageRelation }
      input CreateImageRelation { create: CreateImageInput upsert: UpsertImageInput }
      input CreateImageInput { url: String }
      input UpdateTaskInput { id: ID! name: String image: UpdateImageRelation }
      input UpdateImageRelation { create: CreateImageInput update: UpdateImageInput upsert: UpsertImageInput delete: ID }
      input UpdateImageInput { id: ID! url: String }
      input UpsertTaskInput { id: ID name: String image: UpsertImageRelation }
      input UpsertImageRelation { create: CreateImageInput update: UpdateImageInput upsert: UpsertImageInput delete: ID }
      input UpsertImageInput { id: ID url: String }
    GRAPHQL
  end

  def task_mutation(action, input, variables = {})
    if input.is_a?(Hash)
      return graphql("mutation ($input: #{action.to_s.capitalize}TaskInput!) { #{action}Task(input: $input) { id name image { id url } } }",
                     { 'input' => input }.merge(variables))
    end

    graphql("mutation { #{action}Task(input: #{input}) { id name image { id url } } }")
  end

  it 'creates with a new morphOne' do
    expect_data(task_mutation(:create, '{ name: "foo", image: { create: { url: "foo" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
    expect(LH::Image.first.imageable).to eq(LH::Task.first)
  end

  it 'creates with an upserted morphOne' do
    expect_data(task_mutation(:create, '{ name: "foo", image: { upsert: { id: 1, url: "foo" } } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
  end

  it 'upserts a morphOne without an id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", image: { upsert: { url: "foo" } } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'image' => { 'id' => '1', 'url' => 'foo' } })
  end

  it 'allows null operations' do
    LH::Task.create!(name: 'task')

    expect_data(task_mutation(:update, '{ id: 1, name: "foo", image: { create: null, update: null, upsert: null, delete: null } }'),
                'updateTask' => { 'name' => 'foo', 'image' => nil })
  end

  %w[update upsert].each do |action|
    it "#{action}s with a new morphOne" do
      LH::Task.create!(name: 'task')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", image: { create: { url: "foo" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
    end

    it "#{action}s with an upserted morphOne" do
      LH::Task.create!(name: 'task')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", image: { upsert: { id: 1, url: "foo" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
    end

    it "#{action}s and updates the morphOne" do
      task = LH::Task.create!(name: 'task')
      task.images.create!(url: 'old')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", image: { update: { id: 1, url: "foo" } } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
    end

    it "#{action}s and deletes the morphOne" do
      task = LH::Task.create!(name: 'task')
      task.images.create!(url: 'old')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", image: { delete: 1 } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'image' => nil })
      expect(LH::Image.count).to eq(0)
    end
  end

  it 'attaches an existing image through upsert' do
    task = LH::Task.create!(name: 'task')
    image = LH::Image.create!(url: 'loose')

    expect_data(task_mutation(:update, { 'id' => task.id, 'name' => 'foo', 'image' => { 'upsert' => { 'id' => image.id, 'url' => 'foo' } } }),
                'updateTask' => { 'id' => '1', 'name' => 'foo', 'image' => { 'url' => 'foo' } })
    expect(image.reload.imageable).to eq(task)
  end
end
