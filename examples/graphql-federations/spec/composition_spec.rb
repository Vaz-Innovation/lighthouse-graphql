# frozen_string_literal: true

require 'lighthouse-graphql'

# The SDL each subgraph answers (`_service { sdl }`, which Lighthouse prints) and
# the supergraph rover composes from it: every federation directive the
# subgraphs apply reaches the supergraph, and nothing of Lighthouse's leaks.
RSpec.describe 'Composition' do
  # Lighthouse's own directives: what the subgraphs use, which the router must never see.
  let(:lighthouse_directives) { Lighthouse::DirectiveRegistry.default.directive_definitions.keys }

  def checked_in(name) = File.read(File.join(Stack::ROOT, 'router', name))

  # The names of the directives an SDL applies (not those its descriptions mention).
  def applied_directives(sdl)
    names = []
    visitor = Class.new(GraphQL::Language::StaticVisitor) do
      define_method(:on_directive) do |node, parent|
        names << node.name
        super(node, parent)
      end
    end
    visitor.new(GraphQL.parse(sdl)).visit
    names.uniq
  end

  describe 'the subgraphs' do
    %w[accounts blog].each do |name|
      it "#{name} answers the SDL router/#{name}.graphql holds (bin/compose writes it)" do
        expect(Stack.sdl(name)).to eq(checked_in("#{name}.graphql"))
      end

      it "#{name}'s SDL has none of Lighthouse's directives, nor what the spec adds" do
        expect(applied_directives(Stack.sdl(name)) & lighthouse_directives).to eq([])
        definitions = GraphQL.parse(Stack.sdl(name)).definitions
        query_fields = definitions.find { |definition| definition.try(:name) == 'Query' }.fields.map(&:name)

        expect(definitions.filter_map do |definition|
          definition.try(:name)
        end).not_to include('_Any', '_Entity', '_Service', 'FieldSet', 'link__Import')
        expect(query_fields).not_to include('_entities', '_service')
      end
    end
  end

  describe 'the supergraph', if: Stack.rover? do
    let(:supergraph) { File.read(Stack.composed) }

    it 'is what router/supergraph.graphql holds (bin/compose writes it)' do
      expect(supergraph).to eq(checked_in('supergraph.graphql'))
    end

    it 'has the entities, with every key of each subgraph' do
      expect(supergraph).to include('type User @join__type(graph: ACCOUNTS, key: "id") @join__type(graph: ACCOUNTS, key: "email") ' \
                                    '@join__type(graph: BLOG, key: "id")')
      expect(supergraph).to include('type ReadingTime @join__type(graph: BLOG, key: "postId")')
      expect(supergraph).to include('type Tag implements Node @join__implements(graph: BLOG, interface: "Node") @join__type(graph: BLOG, key: "id")')
    end

    it 'has the entity interface, and the @interfaceObject accounts extends it with' do
      expect(supergraph).to include('interface Authored @join__type(graph: ACCOUNTS, key: "id", isInterfaceObject: true) ' \
                                    '@join__type(graph: BLOG, key: "id")')
      expect(supergraph).to include('likesCount: Int! @join__field(graph: ACCOUNTS)')
    end

    it 'has @override, @requires, @provides and @external' do
      expect(supergraph).to include('postsCount: Int! @join__field(graph: BLOG, override: "accounts")')
      expect(supergraph).to include('signature: String! @join__field(graph: BLOG, requires: "name")')
      expect(supergraph).to include('author: User! @join__field(graph: BLOG, provides: "name")')
      expect(supergraph).to include('name: String! @join__field(graph: ACCOUNTS) @join__field(graph: BLOG, external: true)')
    end

    it 'has the generated pagination types, @shareable, from both subgraphs' do
      expect(supergraph).to include('type PaginatorInfo @join__type(graph: ACCOUNTS) @join__type(graph: BLOG)')
    end

    it 'has @tag and @inaccessible wherever they are applied' do
      expect(supergraph).to include('@tag(name: "public")', '@tag(name: "filters")', '@tag(name: "content")')
      expect(supergraph).to include('internalNotes: String @inaccessible')
      expect(supergraph).to include('SUSPENDED @inaccessible @join__enumValue(graph: ACCOUNTS)')
    end

    it "has the app's own directive @composeDirective keeps (@audit)" do
      expect(supergraph).to include('@link(url: "https://lighthouse-graphql.dev/audit/v1.0", import: ["@audit"])')
      expect(supergraph).to include('email: String @join__field(graph: ACCOUNTS) @audit(reason: "personal data")')
    end

    it 'has @context and @fromContext, @cost and @listSize' do
      expect(supergraph).to match(/type Post implements Authored .*@context\(name: "blog__post"\)/)
      expect(supergraph).to include('caption: String! @join__field(graph: BLOG, contextArguments: ' \
                                    '[{context: "blog__post", name: "postTitle", type: "String", selection: "{ title }"}])')
      expect(supergraph).to include('@cost(weight: 2)', '@listSize(slicingArguments: ["first"], sizedFields: ["data"]')
    end

    # The access-control directives are GraphOS features of the router, which does
    # not start with them unlicensed: a third subgraph, built by Lighthouse here,
    # shows they reach the supergraph too.
    it 'has @authenticated, @requiresScopes and @policy, as a Lighthouse subgraph applies them' do
      vault = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: <<~GRAPHQL)
        extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key", "@authenticated", "@requiresScopes", "@policy"])
        type Query { secrets: [Secret!]! @authenticated @field(resolver: "Secrets") }
        type Secret @key(fields: "id") @requiresScopes(scopes: [["read:secrets"]]) {
          id: ID!
          value: String @policy(policies: [["admin"]])
        }
      GRAPHQL
      File.write(File.join(Stack::TMP, 'vault.graphql'), vault.federation_sdl)
      config = YAML.load_file(File.join(Stack::TMP, 'supergraph.yaml'))
      config['subgraphs']['vault'] = { 'routing_url' => 'http://vault/graphql', 'schema' => { 'file' => File.join(Stack::TMP, 'vault.graphql') } }
      File.write(File.join(Stack::TMP, 'with-vault.yaml'), config.to_yaml)

      composed, log, status = Open3.capture3(Stack.rover_bin, 'supergraph', 'compose', '--config', File.join(Stack::TMP, 'with-vault.yaml'),
                                             '--elv2-license', 'accept')

      expect(status).to be_success, log
      expect(composed).to match(/secrets: \[Secret!\]! .*@authenticated/)
      expect(composed).to match(/type Secret .*@requiresScopes\(scopes: \[\["read:secrets"\]\]\)/)
      expect(composed).to include('value: String @policy(policies: [["admin"]])')
    end
  end
end
