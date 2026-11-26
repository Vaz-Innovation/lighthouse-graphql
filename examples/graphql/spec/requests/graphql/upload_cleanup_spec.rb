require 'rails_helper'

# Issue #1: @upload stores the files before @create validates the post, so a
# post the model refuses must not leave them in the storage service.
RSpec.describe 'GraphQL @upload when the mutation fails', type: :request do
  let(:user) { create(:user) }
  let(:mutation) { 'mutation($title: String!, $images: [Upload!]) { createPost(input: { title: $title, images: $images }) { imageUrls } }' }

  def image(name) = Rack::Test::UploadedFile.new(StringIO.new('png bytes'), 'image/png', original_filename: name)

  def create_post(title)
    operations = { query: mutation, variables: { title: title, images: [nil, nil] } }
    map = { '0' => ['variables.images.0'], '1' => ['variables.images.1'] }
    post '/graphql', params: { 'operations' => operations.to_json, 'map' => map.to_json, '0' => image('a.png'), '1' => image('b.png') },
                     headers: auth_headers(user)
    response.parsed_body
  end

  # The files the test service holds under @upload's posts/ path.
  def stored_files = Dir.glob(Rails.root.join('tmp/storage/**/posts/*').to_s)

  it 'leaves no blob, and no file, behind when the model refuses the post' do
    files = stored_files

    expect { create_post('') }.not_to change(ActiveStorage::Blob, :count)
    expect(validation_errors(response.parsed_body)).to eq('input.title' => ["Title can't be blank"])
    expect(stored_files).to eq(files)
  end

  it 'attaches them to a post the model accepts, and serves them through @attachment' do
    urls = create_post('With images').dig('data', 'createPost', 'imageUrls')

    expect(urls).to contain_exactly(end_with('/a.png'), end_with('/b.png'))
    expect(Post.last.images.map { |attachment| attachment.blob.key }).to all(start_with('posts/'))
  end
end
