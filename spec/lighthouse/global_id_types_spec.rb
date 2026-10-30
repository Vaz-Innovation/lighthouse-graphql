# frozen_string_literal: true

require 'global_id'

# Issue #6: a decoded id is of the type it is for, so another type's id fails
# the field instead of finding the record with the same number.
RSpec.describe '@globalId checks the type of the ids it decodes' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        post(id: ID! @globalId(decode: ID) @eq): Post @find
        widget(by: WidgetBy!): Widget @find
        posts(ids: [ID!]! @globalId(decode: ID) @whereKey): [Post!]! @all
        byAuthor(authorId: ID! @globalId(decode: ID) @eq(key: "author_id")): [Post!]! @all(model: "Post")
        byWidget(authorId: ID! @globalId(decode: ID, type: "Widget") @eq(key: "author_id")): [Post!]! @all(model: "Post")
        story(id: ID! @globalId(decode: ID) @eq): RelayStory @find
      }

      type Mutation {
        deletePost(id: ID! @globalId(decode: ID) @whereKey): Post @delete
      }

      input WidgetBy @oneOf {
        id: ID @globalId(decode: ID) @eq
        name: String @eq
      }

      type Post { id: ID! @globalId title: String }
      type Widget { id: ID! @globalId name: String }
      type RelayStory @model(class: "Post") { id: ID! @globalId title: String }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl) }
  let!(:widget) { Widget.create!(name: 'w') }
  let!(:post) { Post.create!(id: widget.id, title: 'Hello', author_id: widget.id) } # the same number, of two types

  def gid(type, record) = Lighthouse::GraphQL::GlobalId.encode(type, record.id)
  def run(query) = schema.execute(query).to_h
  def errors(result) = result['errors']&.pluck('message')

  it "fails a field given another type's id, where it found the record of that number" do
    result = run(%({ post(id: "#{gid('Widget', widget)}") { title } }))

    expect(result['data']).to eq('post' => nil)
    expect(errors(result)).to eq([%("#{gid('Widget', widget)}" is not a valid global id for Post.)])
    expect(run(%({ post(id: "#{gid('Post', post)}") { title } }))['data']).to eq('post' => { 'title' => 'Hello' })
  end

  it 'checks the field of an input the field takes, and each id of a list' do
    expect(errors(run(%({ widget(by: { id: "#{gid('Post',
                                                  post)}" }) { name } })))).to eq([%("#{gid('Post', post)}" is not a valid global id for Widget.)])
    expect(run(%({ widget(by: { id: "#{gid('Widget', widget)}" }) { name } }))['data']).to eq('widget' => { 'name' => 'w' })
    expect(errors(run(%({ posts(ids: ["#{gid('Post', post)}", "#{gid('Widget', widget)}"]) { title } })))).to be_present
  end

  it 'refuses to act on a record the client did not name' do
    result = run(%(mutation { deletePost(id: "#{gid('Widget', widget)}") { title } }))

    expect(errors(result)).to eq([%("#{gid('Widget', widget)}" is not a valid global id for Post.)])
    expect(Post.exists?(post.id)).to be(true)
  end

  it "takes the id of a type whose @model is the field's model" do
    expect(run(%({ story(id: "#{gid('RelayStory', post)}") { title } }))['data']).to eq('story' => { 'title' => 'Hello' })
    expect(run(%({ post(id: "#{gid('RelayStory', post)}") { title } }))['data']).to eq('post' => { 'title' => 'Hello' })
  end

  it 'leaves an id of another model alone, unless type: names the model it must be of' do
    expect(run(%({ byAuthor(authorId: "#{gid('Widget', widget)}") { title } }))['data']).to eq('byAuthor' => [{ 'title' => 'Hello' }])
    expect(run(%({ byWidget(authorId: "#{gid('Widget', widget)}") { title } }))['data']).to eq('byWidget' => [{ 'title' => 'Hello' }])
    expect(errors(run(%({ byWidget(authorId: "#{gid('Post',
                                                    post)}") { title } })))).to eq([%("#{gid('Post', post)}" is not a valid global id for Widget.)])
  end

  context 'with Rails GlobalIDs, as graphql-ruby install writes them' do
    let(:schema) do
      Class.new(build_schema(sdl)) do
        def self.id_from_object(object, _type, _context) = object.to_gid_param
        def self.object_from_id(global_id, _context) = GlobalID.find(global_id)
      end
    end

    before do
      GlobalID.app ||= 'lighthouse-spec'
      [Post, Widget].each { |model| model.include(GlobalID::Identification) unless model.include?(GlobalID::Identification) }
    end

    it "fails a field given another model's GlobalID (#6)" do
      expect(errors(run(%({ post(id: "#{widget.to_gid_param}") { title } })))).to eq([%("#{widget.to_gid_param}" is not a valid global id for Post.)])
      expect(errors(run(%({ widget(by: { id: "#{post.to_gid_param}" }) { name } })))).to be_present
      expect(run(%({ post(id: "#{post.to_gid_param}") { title } }))['data']).to eq('post' => { 'title' => 'Hello' })
    end

    it 'takes the GlobalID of a subclass (STI)' do
      stub_const('SpecialPost', Class.new(Post))
      special = SpecialPost.find(post.id)

      expect(run(%({ post(id: "#{special.to_gid_param}") { title } }))['data']).to eq('post' => { 'title' => 'Hello' })
    end
  end
end
