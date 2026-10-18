require 'rails_helper'

RSpec.describe 'GraphQL Relay ids, eager loading and resolver classes', type: :request do
  # graphql-ruby's global ids: AppSchema.id_from_object, which its install writes on Rails' GlobalID.
  def global_id(record) = record.to_gid_param

  describe "@node and @globalId, on graphql-ruby's Relay" do
    it "answers a tag's global id, and finds the tag through graphql-ruby's Query.node and nodes with it" do
      tag = create(:tag, name: 'rails')

      expect(graphql('{ tags { id name } }').dig('data', 'tags')).to eq([{ 'id' => global_id(tag), 'name' => 'rails' }])
      expect(graphql(%({ node(id: "#{global_id(tag)}") { __typename id ... on Tag { name } } })).dig('data', 'node'))
        .to eq('__typename' => 'Tag', 'id' => global_id(tag), 'name' => 'rails')
      expect(graphql(%({ nodes(ids: ["#{global_id(tag)}"]) { ... on Tag { name } } })).dig('data', 'nodes')).to eq([{ 'name' => 'rails' }])
    end

    it "makes Tag implement graphql-ruby's Node interface, the only Node" do
      expect(AppSchema.types['Node']).to equal(Types::NodeType)
      expect(AppSchema.types['Tag'].interfaces).to include(Types::NodeType)
      expect(AppSchema.query.fields['node'].owner).to equal(Types::QueryType)
    end
  end

  describe '@withCount' do
    it "counts every tag's published posts in one query, for Tag#usage to read" do
      rails = create(:tag)
      create_list(:post, 2, tags: [rails])
      create(:post, :draft, tags: [rails])
      create(:tag)

      counts = sql_queries { graphql('{ tags { usage } }') }.grep(/COUNT/i)

      expect(graphql('{ tags { usage } }').dig('data', 'tags').pluck('usage')).to contain_exactly('2 published posts', '0 published posts')
      expect(counts.size).to eq(1)
    end
  end

  describe '@with' do
    it "loads every user's posts at once for User#latest_post_title" do
      query = '{ users { data { latestPostTitle } } }'
      create(:post, author: create(:user), title: 'Only')
      few = sql_queries { graphql(query) }.size
      create_list(:user, 3).each { |user| create_list(:post, 2, author: user) }

      expect(sql_queries { graphql(query) }.size).to eq(few)
      expect(graphql(query).dig('data', 'users', 'data').pluck('latestPostTitle')).to include('Only')
    end
  end

  describe '@lazyLoad' do
    it "loads the tags of every user's posts at once for Post#tag_names" do
      query = '{ users { data { posts { tagNames } } } }'
      create(:post, tags: [create(:tag, name: 'ruby')])
      few = sql_queries { graphql(query) }.size
      create_list(:post, 3, tags: [create(:tag)])

      expect(sql_queries { graphql(query) }.size).to eq(few)
      expect(graphql(query).dig('data', 'users', 'data').flat_map { |user| user['posts'] }.first).to eq('tagNames' => ['ruby'])
    end
  end

  it 'resolves a field with the method @field(resolver: "Class@method") names' do
    create_list(:post, 2)
    create(:post, :draft)

    expect(graphql('{ counts { posts users } }').dig('data', 'counts')).to eq('posts' => 2, 'users' => 3)
  end

  describe 'resolve_info.enhance_builder' do
    let(:user) { create(:user) }

    it "applies the field's @like and @orderBy to the query the class builds" do
      create(:post, author: user, title: 'GraphQL b')
      create(:post, :draft, author: user, title: 'GraphQL a')
      create(:post, author: user, title: 'Ruby')
      create(:post, title: 'GraphQL elsewhere')

      body = graphql('{ myPosts(title: "GraphQL", orderBy: [{ column: TITLE, order: ASC }]) { title } }', as: user)

      expect(body.dig('data', 'myPosts').pluck('title')).to eq(['GraphQL a', 'GraphQL b'])
    end

    it 'still sits behind the field’s @guard' do
      expect(error_messages(graphql('{ myPosts { title } }'))).to eq(['Unauthenticated.'])
    end
  end
end
