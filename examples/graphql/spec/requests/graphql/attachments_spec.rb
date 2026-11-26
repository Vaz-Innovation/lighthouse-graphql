require 'rails_helper'

# @attachment: the URL of an ActiveStorage attachment, every parent's loaded at once.
RSpec.describe 'GraphQL @attachment', type: :request do
  def attach(user, name)
    user.avatar.attach(io: StringIO.new('png bytes'), filename: name, content_type: 'image/png')
    user
  end

  it "answers the redirect URL of each user's avatar, null without one, in two queries for any number of users" do
    users = [attach(create(:user), 'a.png'), attach(create(:user), 'b.png'), create(:user)]

    body = nil
    queries = sql_queries { body = graphql('{ users(first: 10) { data { id avatarUrl } } }') }
    urls = body.dig('data', 'users', 'data').to_h { |user| [user['id'].to_i, user['avatarUrl']] }

    expect(urls[users[0].id]).to match(%r{\Ahttp://www.example.com/rails/active_storage/blobs/redirect/.+/a\.png\z})
    expect(urls[users[1].id]).to end_with('/b.png')
    expect(urls[users[2].id]).to be_nil
    expect(queries.grep(/active_storage_(attachments|blobs)/).size).to eq(2)
  end

  it "answers the storage service's own URL with url: DIRECT" do
    user = attach(create(:user), 'a.png')

    url = graphql("{ user(id: #{user.id}) { avatarDirectUrl } }").dig('data', 'user', 'avatarDirectUrl')

    expect(url).to match(%r{\Ahttp://www.example.com/rails/active_storage/disk/.+/a\.png})
    expect(get(url)).to eq(200)
    expect(response.body).to eq('png bytes')
  end
end
