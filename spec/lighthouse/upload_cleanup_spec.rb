# frozen_string_literal: true

require 'stringio'

# @upload stores a file before the field resolves; when the field then fails
# (the model refuses it, the resolver raises or reports an error), the blobs
# it stored are purged, so no file is left behind.
RSpec.describe '@upload when the field fails' do
  let(:file_class) { Struct.new(:original_filename, :content_type, :io) { def read(*) = io.read } }
  let(:image) { file_class.new('image.png', 'image/png', StringIO.new('png')) }
  let(:blobs) { [] }

  let(:schema) do
    build_schema(<<~GRAPHQL)
      scalar Upload

      type Query { x: Int }

      type Mutation {
        createPost(title: String!, cover: Upload @upload): Post @create(model: "UploadCleanupSpecPost")
        raising(file: Upload! @upload): String @field(resolver: "UploadCleanupSpecRaise")
        returning(file: Upload! @upload): String @field(resolver: "UploadCleanupSpecReturn")
        reporting(files: [Upload!]! @upload): String @field(resolver: "UploadCleanupSpecReport")
      }

      type Post { title: String cover: String }
    GRAPHQL
  end

  before do
    stored = blobs
    blob_class = Class.new do
      define_singleton_method(:service) { Struct.new(:name) { def public? = false }.new('test') }
      define_singleton_method(:create_and_upload!) do |**|
        Struct.new(:signed_id, :purged) { def purge_later = self.purged = true }.new("blob-#{stored.size}", false).tap { |blob| stored << blob }
      end
    end
    stub_const('ActiveStorage::Blob', blob_class)
    post_class = Class.new(ApplicationRecord) do
      self.table_name = 'posts'
      attribute :cover, :string
      validates :title, length: { maximum: 5 }
    end
    stub_const('UploadCleanupSpecPost', post_class)
    stub_const('UploadCleanupSpecRaise', ->(*) { raise GraphQL::ExecutionError, 'no' })
    stub_const('UploadCleanupSpecReturn', ->(*) { GraphQL::ExecutionError.new('no') })
    stub_const('UploadCleanupSpecReport', ->(_obj, _args, ctx) { ctx.add_error(GraphQL::ExecutionError.new('no')) && nil })
  end

  def run(query, variables) = schema.execute(query, variables: variables).to_h

  it 'keeps the blob of a mutation that succeeds' do
    result = run('mutation($f: Upload) { createPost(title: "Hi", cover: $f) { cover } }', { 'f' => image })

    expect(result).to eq('data' => { 'createPost' => { 'cover' => 'blob-0' } })
    expect(blobs.map(&:purged)).to eq([false])
  end

  it 'purges the blob of a mutation the model refuses' do
    result = run('mutation($f: Upload) { createPost(title: "Far too long", cover: $f) { cover } }', { 'f' => image })

    expect(result['errors']).to be_present
    expect(blobs.map(&:purged)).to eq([true])
  end

  it 'purges them when the resolver raises, returns an error, or adds one to the context' do
    run('mutation($f: Upload!) { raising(file: $f) }', { 'f' => image })
    run('mutation($f: Upload!) { returning(file: $f) }', { 'f' => image })
    run('mutation($f: [Upload!]!) { reporting(files: $f) }', { 'f' => [image, image] })

    expect(blobs.map(&:purged)).to eq([true, true, true, true])
  end
end
