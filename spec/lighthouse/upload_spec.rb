# frozen_string_literal: true

require 'stringio'

# The Upload scalar, @upload, and the GraphQL multipart request specification.
RSpec.describe 'File uploads' do
  let(:file_class) { Struct.new(:original_filename, :content_type, :io) { def read(*) = io.read } }
  let(:avatar) { file_class.new('avatar.png', 'image/png', StringIO.new('png')) }
  let(:stored) { [] }

  let(:schema) do
    build_schema(<<~GRAPHQL)
      scalar Upload

      type Query { x: Int }

      type Mutation {
        name(file: Upload!): String @field(resolver: "UploadSpecName")
        store(file: Upload! @upload(disk: "s3", path: "avatars")): String @field(resolver: "UploadSpecEcho")
        storeMany(files: [Upload!]! @upload): String @field(resolver: "UploadSpecEcho")
        guarded(file: Upload! @upload): String @guard @field(resolver: "UploadSpecEcho")
      }
    GRAPHQL
  end

  before do
    stub_const('UploadSpecName', ->(_obj, args, _ctx) { args[:file].original_filename })
    stub_const('UploadSpecEcho', ->(_obj, args, _ctx) { args.values.first.inspect })
    calls = stored
    Lighthouse.configure { |c| c.upload_store = ->(file, **options) { (calls << [file, options]) && "stored:#{file.original_filename}" } }
  end

  def run(query, variables) = schema.execute(query, variables: variables).to_h

  it 'hands the resolver the uploaded file, from a variable' do
    expect(run('mutation($f: Upload!) { name(file: $f) }', { 'f' => avatar })).to eq('data' => { 'name' => 'avatar.png' })
  end

  it 'refuses a value that is not a file' do
    result = run('mutation($f: Upload!) { name(file: $f) }', { 'f' => 'not a file' })

    expect(result['errors'].first.dig('extensions', 'problems').to_s).to include('Could not get uploaded file')
  end

  it '@upload stores the file through Config.upload_store and passes what it answers, for lists too' do
    expect(run('mutation($f: Upload!) { store(file: $f) }', { 'f' => avatar })).to eq('data' => { 'store' => '"stored:avatar.png"' })
    expect(stored).to eq([[avatar, { disk: 's3', path: 'avatars' }]])

    expect(run('mutation($f: [Upload!]!) { storeMany(files: $f) }', { 'f' => [avatar, avatar] }).dig('data', 'storeMany'))
      .to eq('["stored:avatar.png", "stored:avatar.png"]')
  end

  it 'stores nothing for a call @guard refuses: @upload runs once the call is let through' do
    result = run('mutation($f: Upload!) { guarded(file: $f) }', { 'f' => avatar })

    expect(result['errors'].pluck('message')).to eq(['Unauthenticated.'])
    expect(stored).to be_empty
  end

  describe Lighthouse::GraphQL::MultipartRequest do
    it 'puts each file where the map says, in an operation' do
      params = { 'operations' => '{"query":"mutation($f: Upload!) { name(file: $f) }","variables":{"f":null}}',
                 'map' => '{"0":["variables.f"]}', '0' => avatar }

      expect(described_class.operations(params)).to eq('query' => 'mutation($f: Upload!) { name(file: $f) }', 'variables' => { 'f' => avatar })
    end

    it 'into lists and batches too' do
      params = { 'operations' => '[{"variables":{"fs":[null,null]}},{"variables":{"f":null}}]',
                 'map' => '{"a":["0.variables.fs.0","1.variables.f"],"b":["0.variables.fs.1"]}', 'a' => avatar, 'b' => :other }

      expect(described_class.operations(params)).to eq([{ 'variables' => { 'fs' => [avatar, :other] } }, { 'variables' => { 'f' => avatar } }])
    end

    it 'is nil for a request that is not multipart' do
      expect(described_class.operations({ 'query' => '{ x }' })).to be_nil
    end
  end
end
