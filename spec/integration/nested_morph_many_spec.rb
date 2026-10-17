# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/MorphManyTest.php
RSpec.describe 'Nested mutations: morphMany' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task { id: ID! name: String! images: [Image!]! @morphMany }
      type Image { id: ID! url: String }

      type Mutation {
        createTask(input: CreateTaskInput! @spread): Task @create
        updateTask(input: UpdateTaskInput! @spread): Task @update
        upsertTask(input: UpsertTaskInput! @spread): Task @upsert
      }

      input CreateTaskInput { name: String! images: CreateImageRelation }
      input CreateImageRelation { create: [CreateImageInput!] upsert: [UpsertImageInput!] connect: [ID!] }
      input CreateImageInput { url: String }
      input UpdateTaskInput { id: ID name: String images: UpdateImageRelation }
      input UpdateImageRelation {
        create: [CreateImageInput!]
        update: [UpdateImageInput!]
        upsert: [UpsertImageInput!]
        delete: [ID!]
        connect: [ID!]
        disconnect: [ID!]
      }
      input UpdateImageInput { id: ID! url: String }
      input UpsertTaskInput { id: ID name: String images: UpsertImageRelation }
      input UpsertImageRelation {
        create: [CreateImageInput!]
        update: [UpdateImageInput!]
        upsert: [UpsertImageInput!]
        delete: [ID!]
        connect: [ID!]
        disconnect: [ID!]
      }
      input UpsertImageInput { id: ID url: String }
    GRAPHQL
  end

  before { LH::Image.saves = 0 }

  def task_mutation(action, input)
    if input.is_a?(Hash)
      return graphql("mutation ($input: #{action.to_s.capitalize}TaskInput!) { #{action}Task(input: $input) { id name images { id url } } }",
                     { 'input' => input })
    end

    graphql("mutation { #{action}Task(input: #{input}) { id name images { id url } } }")
  end

  def task_with_image
    LH::Task.create!(name: 'task').tap { |task| task.images.create!(url: 'old') }
  end

  it 'creates with new morphMany models' do
    expect_data(task_mutation(:create, '{ name: "foo", images: { create: [{ url: "foo" }] } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'id' => '1', 'url' => 'foo' }] })
    expect(LH::Image.first.imageable_type).to eq('LH::Task')
  end

  it 'creates with upserted morphMany models' do
    expect_data(task_mutation(:create, '{ name: "foo", images: { upsert: [{ id: 1, url: "foo" }] } }'),
                'createTask' => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'url' => 'foo' }] })
  end

  it 'creates and connects existing models' do
    image = LH::Image.create!(url: 'loose')

    expect_data(task_mutation(:create, { 'name' => 'foo', 'images' => { 'connect' => [image.id] } }),
                'createTask' => { 'name' => 'foo', 'images' => [{ 'url' => 'loose' }] })
  end

  it 'upserts morphMany models without an id' do
    expect_data(task_mutation(:upsert, '{ name: "foo", images: { upsert: [{ url: "foo" }] } }'),
                'upsertTask' => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'id' => '1', 'url' => 'foo' }] })
  end

  it 'allows null operations' do
    LH::Task.create!(name: 'task')

    expect_data(task_mutation(:update, '{ id: 1, name: "foo", images: { create: null, update: null, upsert: null, delete: null } }'),
                'updateTask' => { 'name' => 'foo', 'images' => [] })
  end

  %w[update upsert].each do |action|
    it "#{action}s with new morphMany models" do
      LH::Task.create!(name: 'task')

      expect_data(task_mutation(action, '{ id: 1, name: "foo", images: { create: [{ url: "foo" }] } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'url' => 'foo' }] })
    end

    it "#{action}s and updates morphMany models" do
      task_with_image

      expect_data(task_mutation(action, '{ id: 1, name: "foo", images: { update: [{ id: 1, url: "foo" }] } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'url' => 'foo' }] })
    end

    it "#{action}s and upserts morphMany models" do
      task_with_image

      expect_data(task_mutation(action, '{ id: 1, name: "foo", images: { upsert: [{ id: 1, url: "foo" }] } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'images' => [{ 'url' => 'foo' }] })
    end

    it "#{action}s and deletes morphMany models" do
      task_with_image

      expect_data(task_mutation(action, '{ id: 1, name: "foo", images: { delete: [1] } }'),
                  "#{action}Task" => { 'id' => '1', 'name' => 'foo', 'images' => [] })
      expect(LH::Image.count).to eq(0)
    end

    it "#{action}s and connects existing models" do
      task = LH::Task.create!(name: 'task')
      image = LH::Image.create!(url: 'loose')

      expect_data(task_mutation(action, { 'id' => task.id, 'name' => 'foo', 'images' => { 'connect' => [image.id] } }),
                  "#{action}Task" => { 'id' => task.id.to_s, 'name' => 'foo', 'images' => [{ 'url' => 'loose' }] })
    end

    it "#{action}s and disconnects morphMany models" do
      task = task_with_image

      expect_data(task_mutation(action, { 'id' => task.id, 'name' => 'foo', 'images' => { 'disconnect' => [1] } }),
                  "#{action}Task" => { 'id' => task.id.to_s, 'name' => 'foo', 'images' => [] })
      expect(LH::Image.find(1).imageable_id).to be_nil
    end
  end

  it 'fires model events when disconnecting' do
    task = task_with_image
    expect { task_mutation(:update, { 'id' => task.id, 'images' => { 'disconnect' => [1] } }) }
      .to change(LH::Image, :saves).by(1)
  end
end
