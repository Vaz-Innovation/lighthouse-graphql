# frozen_string_literal: true

# File uploads (the GraphQL multipart request specification) through the router,
# which streams the files to the subgraph whose field takes them (its
# `preview_file_uploads`): accounts' updateAvatar, where @upload stores them.
RSpec.describe 'Uploads through Apollo Router' do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  it 'stores an avatar (@upload) sent to the router, served at avatarUrl (@attachment)' do
    operations = { query: 'mutation($avatar: Upload!) { updateAvatar(avatar: $avatar) { name avatarUrl postsCount } }',
                   variables: { avatar: nil } }

    # The router refuses a multipart request with no preflight header (its CSRF prevention).
    result = router(token: ada[:token]).upload(operations, { '0' => ['variables.avatar'] }, { '0' => ['ada.png', 'PNGDATA', 'image/png'] },
                                               headers: { 'Apollo-Require-Preflight' => 'true' })

    avatar = data(result)['updateAvatar']
    expect(avatar).to include('name' => 'Ada Lovelace', 'postsCount' => 0)
    expect(avatar['avatarUrl']).to match(%r{/rails/active_storage/blobs/.+/ada\.png})
  end

  it 'refuses a field the upload cannot reach (a file for an argument that takes none)' do
    operations = { query: 'mutation { signUp(name: "x", email: "x@lighthouse.test") { id } }', variables: {} }

    result = router.upload(operations, { '0' => ['variables.nope'] }, { '0' => ['x.txt', 'x', 'text/plain'] },
                           headers: { 'Apollo-Require-Preflight' => 'true' })

    expect(result['errors']).not_to be_empty
  end
end
