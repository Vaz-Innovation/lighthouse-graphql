require 'rails_helper'

# End to end: a client subscribes over ActionCable (GraphqlChannel), another
# request runs a mutation through POST /graphql, and the update reaches the
# subscriber through ActionCable's pub/sub.
RSpec.describe 'Subscriptions over ActionCable', :live_cable, type: :request do
  let(:author) { create(:user) }
  let(:admin) { create(:user, :admin) }
  let(:reader) { create(:user) }

  def titles(client, field)
    client.updates.pluck(field).pluck('title')
  end

  describe 'postCreated, broadcast by createPost' do
    let(:query) { 'subscription { postCreated { title published author { id } } }' }

    it 'delivers a published post to a signed-in subscriber' do
      client = live_client(user: reader)
      client.execute(query)

      graphql('mutation { createPost(input: { title: "Hello", published: true }) { id } }', as: author)

      expect(wait_until { client.updates.any? }).to be(true)
      expect(client.updates.first).to eq(
        'postCreated' => { 'title' => 'Hello', 'published' => true, 'author' => { 'id' => author.id.to_s } }
      )
    end

    it 'keeps a draft to its author and admins, through the policy' do
      mine = live_client(user: author)
      admins = live_client(user: admin)
      others = live_client(user: reader)
      [mine, admins, others].each { |client| client.execute(query) }

      graphql('mutation { createPost(input: { title: "Draft" }) { id } }', as: author)

      expect(wait_until { mine.updates.any? && admins.updates.any? }).to be(true)
      settle
      expect(titles(mine, 'postCreated')).to eq(['Draft'])
      expect(titles(admins, 'postCreated')).to eq(['Draft'])
      expect(others.updates).to be_empty
    end

    it 'broadcasts nothing for a mutation that failed' do
      client = live_client(user: reader)
      client.execute(query)

      graphql('mutation { createPost(input: { title: "" }) { id } }', as: author)

      settle
      expect(client.updates).to be_empty
    end
  end

  describe 'postPublished, broadcast by publishPost' do
    let(:draft) { create(:post, :draft, author: author) }
    let(:publish) { "mutation { publishPost(id: #{draft.id}) { id } }" }

    it 'delivers to a guest, with the fields they asked for' do
      guest = live_client
      guest.execute('subscription { postPublished { id title } }')

      graphql(publish, as: author)

      expect(wait_until { guest.updates.any? }).to be(true)
      expect(guest.updates).to eq([{ 'postPublished' => { 'id' => draft.id.to_s, 'title' => draft.title } }])
    end

    it 'delivers only to the subscribers of that author (or of every author)' do
      everyone = live_client
      of_author = live_client
      of_someone_else = live_client
      everyone.execute('subscription { postPublished { title } }')
      of_author.execute("subscription { postPublished(authorId: #{author.id}) { title } }")
      of_someone_else.execute("subscription { postPublished(authorId: #{reader.id}) { title } }")

      graphql(publish, as: author)

      expect(wait_until { everyone.updates.any? && of_author.updates.any? }).to be(true)
      settle
      expect(titles(everyone, 'postPublished')).to eq([draft.title])
      expect(titles(of_author, 'postPublished')).to eq([draft.title])
      expect(of_someone_else.updates).to be_empty
    end

    it 'broadcasts nothing when the policy refuses the mutation' do
      guest = live_client
      guest.execute('subscription { postPublished { title } }')

      graphql(publish, as: reader)

      settle
      expect(guest.updates).to be_empty
      expect(draft.reload.published).to be(false)
    end
  end

  describe 'closing the socket' do
    it 'unregisters its subscriptions, so nothing is delivered any more' do
      client = live_client
      client.execute('subscription { postPublished { title } }')
      subscription_id = client.subscription_ids.first
      expect(AppSchema.subscriptions.read_subscription(subscription_id)).to be_present

      client.close
      graphql("mutation { publishPost(id: #{create(:post, :draft, author: author).id}) { id } }", as: author)

      settle
      expect(AppSchema.subscriptions.read_subscription(subscription_id)).to be_nil
      expect(client.updates).to be_empty
    end
  end
end
