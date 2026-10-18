require 'rails_helper'

RSpec.describe 'GraphQL file uploads', type: :request do
  let(:user) { create(:user) }
  let(:avatar) { Rack::Test::UploadedFile.new(StringIO.new('png bytes'), 'image/png', original_filename: 'me.png') }
  let(:mutation) { 'mutation($avatar: Upload!) { updateAvatar(avatar: $avatar) { id avatarUrl } }' }

  # A multipart request, as the GraphQL multipart request specification has clients send files.
  def upload(operations, map, files, as: nil)
    post '/graphql', params: { operations: operations.to_json, map: map.to_json, **files }, headers: auth_headers(as)
    response.parsed_body
  end

  it 'stores the file with @upload and attaches it with @update' do
    body = upload({ query: mutation, variables: { avatar: nil } }, { '0' => ['variables.avatar'] }, { '0' => avatar }, as: user)

    expect(body['errors']).to be_nil
    expect(body.dig('data', 'updateAvatar', 'avatarUrl')).to end_with('/me.png')
    expect(user.reload.avatar).to be_attached
    expect(user.avatar.blob.key).to start_with('avatars/')
    expect(user.avatar.download).to eq('png bytes')
  end

  it 'refuses a request that sends no file, and a guest' do
    no_file = upload({ query: mutation, variables: { avatar: 'not a file' } }, {}, {}, as: user)
    guest = upload({ query: mutation, variables: { avatar: nil } }, { '0' => ['variables.avatar'] }, { '0' => avatar })

    expect(no_file.dig('errors', 0, 'extensions', 'problems').to_s).to include('Could not get uploaded file')
    expect(error_messages(guest)).to eq(['Unauthenticated.'])
    expect(ActiveStorage::Blob.count).to eq(0)
  end
end
