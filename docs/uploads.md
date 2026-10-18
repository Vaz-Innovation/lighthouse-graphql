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

`@upload` stores the file first, and passes along what was stored instead, as PHP
Lighthouse's `@upload` does on a Laravel disk. The file goes to your app's
ActiveStorage, the way the rest of the app stores files:

```graphql
type Mutation {
  updateAvatar(avatar: Upload! @upload(path: "avatars")): User!
    @guard
    @update
    @inject(context: "current_user.id", name: "id")
}
```

| | PHP Lighthouse (Laravel) | lighthouse-graphql (ActiveStorage) |
| --- | --- | --- |
| `disk` | a disk of `config/filesystems.php`; `filesystems.default` without it | a service of `config/storage.yml`; `config.active_storage.service` without it |
| `path` (`"/"`) | the directory the file is stored in | the directory the blob's key starts with (`avatars/<token>`); at `"/"`, ActiveStorage's own key |
| `public` (`false`) | the file's visibility | must agree with the service's (see below) |
| the argument holds | the stored path | the blob's **signed id** |

The signed id is what an attachment attribute attaches (`user.avatar = signed_id`) and
`ActiveStorage::Blob.find_signed` finds; the blob keeps the file's name and content
type. Lists of files are stored one by one, and `null` stays `null`.

ActiveStorage makes a whole service public (`public: true` in `config/storage.yml`)
or private, never one file. So `public:` must agree with the service's, and the schema
never says a file is private that anyone can read: `@upload(public: true)` on a private
service fails, and so does `@upload` (`public: false`) on a public one. A service
`config/storage.yml` does not declare fails too.

To store files somewhere else (S3, GCS, Azure or a service of your own), declare an
ActiveStorage service for it and name it with `disk:`, as a Laravel app declares a disk:

```yaml
# config/storage.yml
avatars:
  service: S3
  bucket: my-app-avatars
  region: us-east-1
  public: true
```

```graphql
updateAvatar(avatar: Upload! @upload(disk: "avatars", path: "users", public: true)): User!
```

`@upload` runs once `@guard`, the `@can*` family and `@validator` have let the call
through, so a refused call stores nothing.

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

A multipart request is also what an HTML form on another site can send. If the GraphQL
controller authenticates with the session cookie, keep Rails' CSRF protection on it
(`protect_from_forgery`, on by default in `ActionController::Base`) and have clients send
the `X-CSRF-Token` header, as PHP Lighthouse has them send `X-Requested-With` for its
`EnsureXHR` middleware. A controller that authenticates with a token header is not exposed.

In a request spec:

```ruby
avatar = Rack::Test::UploadedFile.new('spec/fixtures/me.png', 'image/png')
post '/graphql', params: {
  operations: { query: mutation, variables: { avatar: nil } }.to_json,
  map: { '0' => ['variables.avatar'] }.to_json,
  '0' => avatar
}
```
