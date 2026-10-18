# File Uploads

Clients send files with the [GraphQL multipart request specification](https://github.com/jaydenseric/graphql-multipart-request-spec),
which Apollo Upload Client, urql and most GraphQL clients speak: a multipart form with
the operation as JSON, a map of where each file goes, and the files.
`Lighthouse::GraphQL::Controller` reads it, so the endpoint needs nothing more.

## The `Upload` scalar

Declare it, and use it for arguments:

```graphql
"A file sent with a multipart request."
scalar Upload

type Mutation {
  updateAvatar(avatar: Upload!): User! @update @inject(context: "current_user.id", name: "id")
}
```

Lighthouse reads its values itself (`Lighthouse::GraphQL::Upload`): the resolver gets
the uploaded file, an `ActionDispatch::Http::UploadedFile`. A value that is not a file
makes the argument invalid. `Upload` is for arguments only, never a field's result.

An ActiveStorage attachment takes the file as it is: with `has_one_attached :avatar`
on `User`, the mutation above attaches it.

## `@upload`

`@upload` stores the file first, and passes along what was stored instead:

```graphql
type Mutation {
  updateAvatar(avatar: Upload! @upload(path: "avatars")): User!
    @guard
    @update
    @inject(context: "current_user.id", name: "id")
}
```

By default the file becomes an ActiveStorage blob: on the service `disk:` names (the
default service without it), with its key under `path:`. The argument then holds the
blob's **signed id**, which an attachment attribute attaches (`user.avatar = signed_id`)
and `ActiveStorage::Blob.find_signed` finds. Lists of files are stored one by one.

`@upload` runs once `@guard`, the `@can*` family and `@validator` have let the call
through, so a refused call stores nothing.

To store files elsewhere, give [`upload_store`](configuration.md#upload_store) an
object with `call(file, disk:, path:, public:)`; the argument holds what it returns:

```ruby
Lighthouse.configure do |config|
  config.upload_store = ->(file, path: '/', **) { S3Uploader.put(file, prefix: path) }   # returns the key
end
```

## The request

```shell
curl localhost:3000/graphql \
  -H 'Authorization: Bearer <token>' \
  -F operations='{ "query": "mutation($avatar: Upload!) { updateAvatar(avatar: $avatar) { avatarUrl } }", "variables": { "avatar": null } }' \
  -F map='{ "0": ["variables.avatar"] }' \
  -F 0=@me.png
```

A batch sends an array as `operations`, and maps files to `"0.variables.avatar"`,
`"1.variables.files.0"`, and so on.

In a request spec:

```ruby
avatar = Rack::Test::UploadedFile.new('spec/fixtures/me.png', 'image/png')
post '/graphql', params: {
  operations: { query: mutation, variables: { avatar: nil } }.to_json,
  map: { '0' => ['variables.avatar'] }.to_json,
  '0' => avatar
}
```
