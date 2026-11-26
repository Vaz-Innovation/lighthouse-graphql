require 'rails_helper'

RSpec.describe 'GraphQL authentication and authorization', type: :request do
  let(:user) { create(:user, name: 'Ada', email: 'ada@example.com') }

  describe '@guard' do
    it 'refuses guests' do
      body = graphql('{ me { id } }')

      expect(error_messages(body)).to eq(['Unauthenticated.'])
      expect(body.dig('errors', 0, 'extensions')).to eq('code' => 'UNAUTHENTICATED')
      expect(body['data']).to be_nil
    end

    it 'resolves the signed-in user from the bearer token' do
      expect(graphql('{ me { name } }', as: user)).to eq('data' => { 'me' => { 'name' => 'Ada' } })
    end
  end

  describe '@canRoot' do
    let(:query) { "{ user(id: #{user.id}) { email } }" }

    it 'shows an email to its owner and to admins' do
      expect(graphql(query, as: user).dig('data', 'user', 'email')).to eq('ada@example.com')
      expect(graphql(query, as: create(:user, :admin)).dig('data', 'user', 'email')).to eq('ada@example.com')
    end

    it 'hides it from everyone else' do
      body = graphql(query, as: create(:user))

      expect(error_messages(body)).to eq(['This action is unauthorized.'])
      expect(body.dig('data', 'user', 'email')).to be_nil
    end
  end

  describe '@canFind' do
    let(:post_record) { create(:post, author: user, title: 'Mine') }
    let(:mutation) { "mutation { updatePost(input: { id: #{post_record.id}, title: \"Changed\" }) { title } }" }

    it 'lets the author edit their post' do
      expect(graphql(mutation, as: user)).to eq('data' => { 'updatePost' => { 'title' => 'Changed' } })
    end

    it "lets an admin edit anyone's post" do
      expect(graphql(mutation, as: create(:user, :admin)).dig('data', 'updatePost', 'title')).to eq('Changed')
    end

    it 'refuses other users, and changes nothing' do
      body = graphql(mutation, as: create(:user))

      expect(error_messages(body)).to eq(['This action is unauthorized.'])
      expect(post_record.reload.title).to eq('Mine')
    end
  end
end
