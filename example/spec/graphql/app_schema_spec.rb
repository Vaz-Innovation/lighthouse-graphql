require 'rails_helper'

RSpec.describe AppSchema do
  let(:definition) { described_class.to_definition }

  it 'builds from every file in graphql/' do
    expect(described_class.query.fields.keys).to include('me', 'posts', 'feed', 'searchPosts')
    expect(described_class.mutation.fields.keys).to include('signUp', 'createPost', 'publishPost')
  end

  it 'has the pagination types and arguments Lighthouse generates' do
    expect(definition).to include('type PostPaginator', 'type PostConnection', 'type PostEdge', 'type PaginatorInfo', 'type PageInfo')
    expect(described_class.query.fields['posts'].arguments.keys).to include('first', 'page', 'where', 'orderBy')
    expect(described_class.query.fields['feed'].arguments.keys).to include('first', 'after')
  end

  it 'generates the input of @whereConditions' do
    expect(definition).to include('input QueryPostsWhereWhereConditions', 'enum QueryPostsWhereColumn')
  end
end
