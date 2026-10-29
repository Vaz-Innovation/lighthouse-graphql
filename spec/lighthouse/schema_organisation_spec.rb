# frozen_string_literal: true

require 'tmpdir'

# PHP Lighthouse's schema organisation: one entrypoint that #imports the
# other files, every type defined once, and `extend type` to add to it.
RSpec.describe 'schema organisation' do
  describe Lighthouse::GraphQL::SchemaStitcher do
    let(:dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(dir) }

    def write(path, content)
      file = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
      file
    end

    def stitched(path = 'schema.graphql')
      described_class.new(File.join(dir, path)).schema_string
    end

    it 'pastes each imported file where it is imported, relative to the importing file' do
      write('schema.graphql', "type Query\n#import user.graphql\n")
      write('user.graphql', "type User { name: String }\n#import user/post.graphql\n")
      write('user/post.graphql', "type Post { title: String }\n")

      expect(stitched).to eq("type Query\ntype User { name: String }\ntype Post { title: String }\n")
    end

    it 'imports every file a glob matches, in name order' do
      write('schema.graphql', "  #import blog/*.graphql\n")
      write('blog/post.graphql', "type Post { id: ID }\n")
      write('blog/category.graphql', "type Category { id: ID }\n")

      expect(stitched).to eq("type Category { id: ID }\ntype Post { id: ID }\n")
    end

    it 'imports every file below the folder with **, the entrypoint once' do
      write('schema.graphql', "type Query { a: Int }\n#import **/*.graphql\n")
      write('users.graphql', "type User { id: ID }\n")
      write('blog/posts/post.graphql', "type Post { id: ID }\n")

      expect(stitched).to eq("type Query { a: Int }\ntype Post { id: ID }\ntype User { id: ID }\n")
    end

    it 'reads a file once, however often it is imported' do
      write('schema.graphql', "#import a.graphql\n#import b.graphql\n#import a.graphql\n")
      write('a.graphql', "type A { id: ID }\n#import b.graphql\n")
      write('b.graphql', "type B { id: ID }\n#import schema.graphql\n")

      expect(stitched).to eq("type A { id: ID }\ntype B { id: ID }\n")
      expect(described_class.new(File.join(dir, 'schema.graphql')).files.map { |f| File.basename(f) })
        .to eq(%w[schema.graphql a.graphql b.graphql])
    end

    it 'leaves out the files of the folder it does not import' do
      write('schema.graphql', "type Query { a: Int }\n")
      write('unused.graphql', "type Unused { id: ID }\n")

      expect(stitched).not_to include('Unused')
    end

    it 'fails on an import that names no file' do
      write('schema.graphql', "#import missing.graphql\n")

      expect { stitched }.to raise_error(Lighthouse::DefinitionError, %r{Did not find GraphQL schema import at .*/missing\.graphql})
    end

    it 'fails without the entrypoint' do
      expect { stitched('nope.graphql') }.to raise_error(Lighthouse::DefinitionError, /Failed to find a GraphQL schema file at .*nope\.graphql/)
    end

    it 'is what get_schema reads from Config.schema_path' do
      write('schema.graphql', "type Query\n#import posts.graphql\n")
      write('posts.graphql', "extend type Query { answer: Int @field(resolver: \"LH::Answer\") }\n")
      stub_const('LH::Answer', ->(*) { 42 })
      Lighthouse.configure { |c| c.schema_path = File.join(dir, 'schema.graphql') }

      expect(Lighthouse::GraphQL::RbLightHouse.get_schema.execute('{ answer }').to_h).to eq('data' => { 'answer' => 42 })
    end
  end

  describe 'type definitions and extensions' do
    include_context 'with PHP Lighthouse models'

    def build_sdl(sdl)
      build_schema(sdl)
    end

    it 'fails on a type defined twice, pointing at extend' do
      sdl = "type Query { a: Int }\ntype Query { b: Int }\n"

      expect do
        build_sdl(sdl)
      end.to raise_error(Lighthouse::DefinitionError, /Duplicate definition Query found when parsing the schema.*`extend type Query`/)
    end

    it 'fails on an input defined twice, pointing at extend input' do
      sdl = "type Query { a(i: I): Int }\ninput I { a: Int }\ninput I { b: Int }\n"

      expect { build_sdl(sdl) }.to raise_error(Lighthouse::DefinitionError, /`extend input I`/)
    end

    it 'merges each extension into the type it extends' do
      schema = build_sdl(<<~GRAPHQL)
        type Query { users: [User!]! @all(model: "LH::User") }
        type User { id: ID! }
        extend type User { name: String }
        extend type Query { usersCount: Int! @count(model: "LH::User") }
      GRAPHQL
      LH::User.create!(name: 'Ada')

      expect(schema.types['User'].fields.keys).to eq(%w[id name])
      expect(schema.execute('{ users { name } usersCount }').to_h).to eq('data' => { 'users' => [{ 'name' => 'Ada' }], 'usersCount' => 1 })
    end

    it 'applies the directives of an extension to its fields, as on the type' do
      schema = build_sdl(<<~GRAPHQL)
        type Query
        type User { id: ID! }
        extend type Query {
          users: [User!]! @paginate(model: "LH::User", defaultCount: 5)
        }
      GRAPHQL

      expect(schema.types['Query'].fields['users'].type.unwrap.graphql_name).to eq('UserPaginator')
    end

    it 'defines a root type an extension extends without a definition' do
      schema = build_sdl("extend type Query { a: Int }\nextend type Query { b: Int }\n")

      expect(schema.types['Query'].fields.keys).to eq(%w[a b])
    end

    it 'extends inputs, enums, unions and interfaces' do
      schema = build_sdl(<<~GRAPHQL)
        type Query { a(i: I, e: E): U, n: Named }
        input I { a: Int }
        extend input I { b: Int }
        enum E { A }
        extend enum E { B }
        type X { id: ID }
        type Y { id: ID }
        union U = X
        extend union U = Y
        interface Named { id: ID }
        extend interface Named { name: String }
      GRAPHQL

      expect(schema.types['I'].arguments.keys).to eq(%w[a b])
      expect(schema.types['E'].values.keys).to eq(%w[A B])
      expect(schema.types['U'].possible_types.map(&:graphql_name)).to eq(%w[X Y])
      expect(schema.types['Named'].fields.keys).to eq(%w[id name])
    end

    it 'fails on an extension of a type that is not defined' do
      expect { build_sdl("type Query { a: Int }\nextend type User { name: String }\n") }
        .to raise_error(Lighthouse::DefinitionError, 'Could not find a base definition User of kind ObjectTypeExtension to extend.')
    end

    it 'fails on an extension of another kind of type' do
      expect { build_sdl("type Query { a(i: I): Int }\ninput I { a: Int }\nextend type I { b: Int }\n") }
        .to raise_error(Lighthouse::DefinitionError,
                        'The type extension I of kind ObjectTypeExtension can not extend a definition of kind InputObjectTypeDefinition.')
    end

    it 'fails on an extension redefining a field' do
      expect { build_sdl("type Query { a: Int }\nextend type Query { a: String }\n") }
        .to raise_error(Lighthouse::DefinitionError, 'Duplicate definition a found when merging.')
    end

    it 'fails on the `_` placeholder no directive replaces' do
      expect { build_sdl("type Query { a(b: _): Int }\n") }
        .to raise_error(Lighthouse::DefinitionError, /Query.a\(b:\) has the placeholder type `_`/)
    end

    it 'leaves no `_` in the schema, the IDE helper being the only one to declare it' do
      sdl = "scalar _\ntype Query { a(where: _ @whereConditions(columns: [\"id\"])): [Int!]! @all(model: \"Widget\") }\n"

      expect(Lighthouse::GraphQL::ASTBuilder.build(sdl)).not_to match(/scalar _\b|:\s*_\b/)
      expect(build_schema(sdl).types).not_to have_key('_')
    end
  end
end
