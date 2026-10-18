# frozen_string_literal: true

# @field(resolver: "Class@method"), and the ResolveInfo every resolver can read.
class ResolveInfoSpecStatistics
  def self.posts_total(_obj, _args, _ctx) = Post.count

  def drafts_total(_obj, _args, _ctx) = Post.where(published: false).count
end

class ResolveInfoSpecFeed < GraphQL::Schema::Resolver
  def authorized?(**) = context[:viewer] ? true : raise(GraphQL::ExecutionError, 'Sign in.')

  def resolve(**) = 'never: the method after @ replaces it'

  def latest(limit:) = Post.order(id: :desc).limit(limit).pluck(:title)

  # The field's own directives, applied to the query this method builds.
  def search(**) = resolve_info.enhance_builder(Post.all, scopes: [:published]).order(:id).pluck(:title)
end

# A type class method reading it too.
class Types::InfoPostType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def where_am_i = "#{resolve_info.parent_type.graphql_name}.#{resolve_info.field_name} at #{resolve_info.path.join('.')}"
end

RSpec.describe 'ResolveInfo and @field(resolver: "Class@method")' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        postsTotal: Int @field(resolver: "ResolveInfoSpecStatistics@posts_total")
        draftsTotal: Int @field(resolver: "ResolveInfoSpecStatistics@drafts_total")
        latest(limit: Int = 2): [String!]! @field(resolver: "ResolveInfoSpecFeed@latest")
        search(title: String @eq, published: Boolean @eq): [String!]!
          @field(resolver: "ResolveInfoSpecFeed@search") @builder(class: "Published")
        info(term: String): String @field(resolver: "ResolveInfoSpecInfo")
        infoPost: InfoPost @first(model: "Post")
      }

      type InfoPost { title: String whereAmI: String }
    GRAPHQL
  end

  before do
    stub_const('ResolveInfoSpecInfo', lambda { |_obj, args, _ctx, info|
      "#{info.parent_type.graphql_name}.#{info.field_name}(#{args[:term]}) -> #{info.return_type.to_type_signature}"
    })
    Post.create!(title: 'Draft')
    Post.create!(title: 'Shown', published: true)
    Post.create!(title: 'Other', published: true)
  end

  def run(query, context = { viewer: true }) = build_schema(sdl).execute(query, context: context).to_h

  it 'calls the class method after @, or else the instance method, with (object, args, context)' do
    expect(run('{ postsTotal draftsTotal }')).to eq('data' => { 'postsTotal' => 3, 'draftsTotal' => 1 })
  end

  it 'calls the method after @ on a resolver class instead of resolve, still behind its authorized?' do
    expect(run('{ latest few: latest(limit: 1) }')).to eq('data' => { 'latest' => %w[Other Shown], 'few' => %w[Other] })
    expect(run('{ latest }', {})['errors'].pluck('message')).to eq(['Sign in.'])
  end

  it "applies the field's builders, argument directives and the scopes given with enhance_builder" do
    expect(run('{ all: search only: search(title: "Shown") none: search(title: "Draft") }'))
      .to eq('data' => { 'all' => %w[Shown Other], 'only' => %w[Shown], 'none' => [] })
  end

  it 'hands a plain callable taking four parameters the ResolveInfo' do
    expect(run('{ info(term: "x") }')).to eq('data' => { 'info' => 'Query.info(x) -> String' })
  end

  it "lets a type class's method read it" do
    expect(run('{ infoPost { whereAmI } }')).to eq('data' => { 'infoPost' => { 'whereAmI' => 'InfoPost.whereAmI at infoPost.whereAmI' } })
  end
end
