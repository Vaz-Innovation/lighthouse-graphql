# frozen_string_literal: true

RSpec.describe 'Mutation directives (@create, @createMany, @update, @updateMany)' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts: [Post!]! @paginate
      }

      type Mutation {
        createPost(title: String, content: String @rename(attribute: "body")): Post @create
        createPostFromInput(input: CreatePostInput! @spread): Post @create
        createOwnPost(title: String!): Post @create @inject(context: "current_user.id", name: "author_id")
        createWidget(name: String!): Widget @create(model: "Widget")
        createPosts(inputs: [CreatePostInput!]!): [Post!]! @createMany

        updatePost(id: ID!, title: String): Post @update
        updatePostFromInput(input: UpdatePostInput! @spread): Post @update
        updatePosts(inputs: [UpdatePostInput!]!): [Post!]! @updateMany
      }

      input CreatePostInput {
        title: String
        content: String @rename(attribute: "body")
      }

      input UpdatePostInput {
        id: ID!
        title: String
      }

      type Post {
        id: ID!
        title: String
        body: String
        authorId: ID
      }

      type Widget {
        id: ID!
        name: String
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  def run(query, context = {})
    schema.execute(query, context: context).to_h
  end

  def validation(result)
    result['errors'].first['extensions']['validation']
  end

  describe '@create' do
    it 'creates the model the field returns from its arguments, honouring @rename' do
      result = run('mutation { createPost(title: "Hello", content: "World") { title body } }')

      expect(result).to eq('data' => { 'createPost' => { 'title' => 'Hello', 'body' => 'World' } })
      expect(Post.pluck(:title, :body)).to eq([%w[Hello World]])
    end

    it 'spreads an input object marked @spread' do
      run('mutation { createPostFromInput(input: { title: "Spread", content: "Body" }) { id } }')

      expect(Post.pluck(:title, :body)).to eq([%w[Spread Body]])
    end

    it 'sets server-side values with @inject' do
      result = run('mutation { createOwnPost(title: "Mine") { authorId } }', current_user: Struct.new(:id).new(42))

      expect(result).to eq('data' => { 'createOwnPost' => { 'authorId' => '42' } })
    end

    it 'uses model: when the model is not the return type' do
      run('mutation { createWidget(name: "Sprocket") { name } }')

      expect(Widget.pluck(:name)).to eq(['Sprocket'])
    end

    it "reports the model's validation errors by argument path" do
      result = run('mutation { createPost(title: "") { id } }')

      expect(result['data']).to eq('createPost' => nil)
      expect(result['errors'].first['message']).to eq('Validation failed for the field [createPost].')
      expect(validation(result)).to eq('title' => ["Title can't be blank"])
      expect(Post.count).to eq(0)
    end

    it 'keys the errors of a spread input by the path inside it' do
      result = run(%(mutation { createPostFromInput(input: { title: "#{'x' * 21}" }) { id } }))

      expect(validation(result)).to eq('input.title' => ['Title is too long (maximum is 20 characters)'])
    end
  end

  describe '@createMany' do
    it 'creates one model per input' do
      result = run('mutation { createPosts(inputs: [{ title: "One" }, { title: "Two", content: "2" }]) { title body } }')

      expect(result).to eq('data' => { 'createPosts' => [{ 'title' => 'One', 'body' => nil },
                                                         { 'title' => 'Two', 'body' => '2' }] })
    end

    it 'saves nothing when any input is invalid, and reports each by index' do
      result = run('mutation { createPosts(inputs: [{ title: "One" }, { title: "" }, { content: "x" }]) { id } }')

      expect(validation(result)).to eq('inputs.1.title' => ["Title can't be blank"],
                                       'inputs.2.title' => ["Title can't be blank"])
      expect(Post.count).to eq(0)
    end

    it 'saves the valid ones when transactional_mutations is off' do
      Lighthouse.configure { |c| c.transactional_mutations = false }

      run('mutation { createPosts(inputs: [{ title: "One" }, { title: "" }]) { id } }')

      expect(Post.pluck(:title)).to eq(['One'])
    end
  end

  describe '@update' do
    let!(:post) { Post.create!(title: 'Before', body: 'kept') }

    it 'finds the model by its primary key and updates the given attributes only' do
      result = run(%(mutation { updatePost(id: #{post.id}, title: "After") { title body } }))

      expect(result).to eq('data' => { 'updatePost' => { 'title' => 'After', 'body' => 'kept' } })
    end

    it 'takes the primary key from a spread input' do
      run(%(mutation { updatePostFromInput(input: { id: #{post.id}, title: "Spread" }) { id } }))

      expect(post.reload.title).to eq('Spread')
    end

    it 'fails when no model has that key' do
      result = run('mutation { updatePost(id: 0, title: "x") { id } }')

      expect(result['errors'].first['message']).to eq("Couldn't find Post with 'id'=0")
    end

    it 'leaves the record unchanged when validation fails' do
      result = run(%(mutation { updatePost(id: #{post.id}, title: "") { id } }))

      expect(validation(result)).to eq('title' => ["Title can't be blank"])
      expect(post.reload.title).to eq('Before')
    end
  end

  describe '@updateMany' do
    let!(:first) { Post.create!(title: 'First') }
    let!(:second) { Post.create!(title: 'Second') }

    it 'updates one model per input, all or nothing' do
      ok = run(%(mutation { updatePosts(inputs: [{ id: #{first.id}, title: "1st" }, { id: #{second.id}, title: "2nd" }]) { title } }))
      expect(ok).to eq('data' => { 'updatePosts' => [{ 'title' => '1st' }, { 'title' => '2nd' }] })

      failed = run(%(mutation { updatePosts(inputs: [{ id: #{first.id}, title: "one" }, { id: #{second.id}, title: "" }]) { id } }))
      expect(validation(failed)).to eq('inputs.1.title' => ["Title can't be blank"])
      expect([first.reload.title, second.reload.title]).to eq(%w[1st 2nd])
    end
  end

  it 'requires @createMany / @updateMany to take a single list argument' do
    broken = build_schema(<<~GRAPHQL)
      type Query { a: String }
      type Mutation { createPosts(title: String, body: String): [Post!]! @createMany }
      type Post { id: ID! }
    GRAPHQL

    expect { broken.execute('mutation { createPosts(title: "x") { id } }') }
      .to raise_error(Lighthouse::DefinitionError, /must ensure that clients pass exactly one field argument/)
  end
end
