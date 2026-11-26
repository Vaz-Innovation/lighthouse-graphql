require 'rails_helper'

RSpec.describe 'GraphQL mutations', type: :request do
  let(:user) { create(:user) }

  describe '@create with @validator' do
    let(:mutation) { 'mutation SignUp($name: String!, $email: String!) { signUp(name: $name, email: $email) { name email } }' }

    it 'creates the user' do
      body = graphql(mutation, variables: { name: 'Linus', email: 'linus@example.com' })

      expect(body.dig('data', 'signUp', 'name')).to eq('Linus')
      expect(User.find_by(email: 'linus@example.com')).to be_present
    end

    it "reports the contract's errors by argument, before touching the model" do
      body = graphql(mutation, variables: { name: 'Linus', email: 'linus@example.org' })

      expect(error_messages(body)).to eq(['Validation failed for the field [signUp].'])
      expect(validation_errors(body)).to eq('email' => ['uses a reserved domain'])
      expect(User.count).to eq(0)
    end

    it "reports the model's own validations the same way" do
      create(:user, email: 'taken@example.com')

      body = graphql(mutation, variables: { name: 'Linus', email: 'taken@example.com' })

      expect(validation_errors(body)).to eq('email' => ['Email has already been taken'])
    end
  end

  describe 'a nested mutation' do
    it 'creates a post for the signed-in user and tags it in one request' do
      rails = create(:tag, name: 'rails')
      body = graphql(<<~GRAPHQL, as: user)
        mutation {
          createPost(input: { title: "Nested", tags: { connect: [#{rails.id}], create: [{ name: "graphql" }] } }) {
            title
            published
            author { id }
            tags { name }
          }
        }
      GRAPHQL

      expect(body.dig('data', 'createPost')).to include('title' => 'Nested', 'published' => false, 'author' => { 'id' => user.id.to_s })
      expect(body.dig('data', 'createPost', 'tags').pluck('name')).to contain_exactly('rails', 'graphql')
    end

    it 'rolls everything back when part of it is invalid' do
      body = graphql('mutation { createPost(input: { title: "", tags: { create: [{ name: "orphan" }] } }) { id } }', as: user)

      expect(validation_errors(body)).to eq('input.title' => ["Title can't be blank"])
      expect(Tag.count).to eq(0)
    end

    it 'replaces the tags with sync' do
      post_record = create(:post, author: user)
      post_record.tags << create(:tag, name: 'old')
      keep = create(:tag, name: 'keep')

      body = graphql("mutation { updatePost(input: { id: #{post_record.id}, tags: { sync: [#{keep.id}] } }) { tags { name } } }", as: user)

      expect(body.dig('data', 'updatePost', 'tags')).to eq([{ 'name' => 'keep' }])
    end
  end

  describe '@delete' do
    it 'deletes the post the argument identifies' do
      post_record = create(:post, author: user, title: 'Bye')

      body = graphql("mutation { deletePost(id: #{post_record.id}) { title } }", as: user)

      expect(body).to eq('data' => { 'deletePost' => { 'title' => 'Bye' } })
      expect(Post.exists?(post_record.id)).to be(false)
    end
  end

  describe 'a Mutations:: class' do
    let(:draft) { create(:post, :draft, author: user) }

    it 'resolves Mutation.publishPost by convention, after the policy check' do
      body = graphql("mutation { publishPost(id: #{draft.id}) { published } }", as: user)

      expect(body).to eq('data' => { 'publishPost' => { 'published' => true } })
    end

    it 'reports its own errors to the client' do
      draft.update!(published: true)

      expect(error_messages(graphql("mutation { publishPost(id: #{draft.id}) { id } }", as: user))).to eq(['This post is already published.'])
    end

    it 'never runs for someone the policy refuses' do
      body = graphql("mutation { publishPost(id: #{draft.id}) { id } }", as: create(:user))

      expect(error_messages(body)).to eq(['This action is unauthorized.'])
      expect(draft.reload.published).to be(false)
    end
  end

  describe '@inject and @rename' do
    it 'comments as the signed-in user' do
      post_record = create(:post)

      body = graphql("mutation { addComment(postId: #{post_record.id}, body: \"Great\") { body author { id } post { id } } }", as: user)

      expect(body.dig('data', 'addComment')).to eq('body' => 'Great', 'author' => { 'id' => user.id.to_s }, 'post' => { 'id' => post_record.id.to_s })
    end
  end
end
