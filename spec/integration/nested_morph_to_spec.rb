# frozen_string_literal: true

# Ported from PHP Lighthouse: tests/Integration/Execution/MutationExecutor/MorphToTest.php
RSpec.describe 'Nested mutations: morphTo' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL + LH::PLACEHOLDER_QUERY
      type Task { id: ID name: String }
      type Image { id: ID url: String imageable: Task @morphTo }

      enum ImageableType { TASK }

      type Mutation {
        createImage(input: CreateImageInput! @spread): Image @create
        createImageWithEnumType(input: CreateImageWithEnumTypeInput! @spread): Image @create
        updateImage(input: UpdateImageInput! @spread): Image @update
        upsertImage(input: UpsertImageInput! @spread): Image @upsert
      }

      input CreateImageInput { url: String imageable: CreateImageableOperations }
      input CreateImageableOperations { connect: ConnectImageableInput }
      input ConnectImageableInput { type: String! id: ID! }
      input CreateImageWithEnumTypeInput { url: String imageable: CreateImageableOperationsWithEnumType }
      input CreateImageableOperationsWithEnumType { connect: ConnectImageableWithEnumTypeInput }
      input ConnectImageableWithEnumTypeInput { type: ImageableType! id: ID! }
      input UpdateImageInput { id: ID! url: String imageable: UpdateImageableOperations }
      input UpdateImageableOperations { connect: ConnectImageableInput disconnect: Boolean delete: Boolean }
      input UpsertImageInput { id: ID! url: String imageable: UpsertImageableOperations }
      input UpsertImageableOperations { connect: ConnectImageableInput disconnect: Boolean delete: Boolean }
    GRAPHQL
  end

  let!(:task) { LH::Task.create!(name: 'first_task') }

  def image_with_task
    LH::Image.create!(url: 'bar', imageable: task)
  end

  it 'connects a morphTo by type and id' do
    result = graphql('mutation { createImage(input: { url: "foo", imageable: { connect: { type: "LH::Task", id: 1 } } }) { id url imageable { id name } } }')

    expect_data(result, 'createImage' => { 'id' => '1', 'url' => 'foo', 'imageable' => { 'id' => '1', 'name' => 'first_task' } })
    expect(LH::Image.first.imageable_type).to eq('LH::Task')
  end

  it 'connects a morphTo with an enum type' do
    result = graphql('mutation { createImageWithEnumType(input: { url: "foo", imageable: { connect: { type: TASK, id: 1 } } }) { id url imageable { id name } } }')

    expect_data(result, 'createImageWithEnumType' => { 'id' => '1', 'url' => 'foo', 'imageable' => { 'id' => '1', 'name' => 'first_task' } })
  end

  it 'connects a morphTo while upserting' do
    result = graphql('mutation { upsertImage(input: { id: 1, url: "foo", imageable: { connect: { type: "Task", id: 1 } } }) { id url imageable { id name } } }')

    expect_data(result, 'upsertImage' => { 'id' => '1', 'url' => 'foo', 'imageable' => { 'id' => '1', 'name' => 'first_task' } })
  end

  it 'refuses to connect a type that is not a model' do
    result = graphql('mutation { createImage(input: { url: "foo", imageable: { connect: { type: "Kernel", id: 1 } } }) { id } }')

    expect(error_messages(result)).to eq(['Unknown type Kernel to connect.'])
  end

  it 'allows null operations' do
    LH::Image.create!(url: 'bar')

    expect_data(graphql('mutation { updateImage(input: { id: 1, url: "foo", imageable: { connect: null, disconnect: null, delete: null } }) { url imageable { id } } }'),
                'updateImage' => { 'url' => 'foo', 'imageable' => nil })
  end

  %w[update upsert].each do |action|
    it "#{action}s and disconnects the morphTo" do
      image_with_task

      expect_data(graphql("mutation { #{action}Image(input: { id: 1, url: \"foo\", imageable: { disconnect: true } }) { url imageable { id } } }"),
                  "#{action}Image" => { 'url' => 'foo', 'imageable' => nil })
      expect(LH::Task.count).to eq(1)
    end

    it "#{action}s and deletes the morphTo" do
      image_with_task

      expect_data(graphql("mutation { #{action}Image(input: { id: 1, url: \"foo\", imageable: { delete: true } }) { url imageable { id } } }"),
                  "#{action}Image" => { 'url' => 'foo', 'imageable' => nil })
      expect(LH::Task.count).to eq(0)
    end
  end
end
