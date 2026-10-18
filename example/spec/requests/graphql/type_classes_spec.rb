require 'rails_helper'

RSpec.describe 'GraphQL type classes (app/graphql/types)', type: :request do
  let(:body_of_450_words) { (['word'] * 450).join(' ') }

  it "resolves Post.readingTime with Types::PostType, and the ReadingTime type's fields with Types::ReadingTimeType" do
    post_record = create(:post, body: body_of_450_words)

    body = graphql("{ post(id: #{post_record.id}) { title readingTime { words minutes slow: minutes(wordsPerMinute: 100) } } }")

    expect(body.dig('data', 'post')).to eq('title' => post_record.title,
                                           'readingTime' => { 'words' => 450, 'minutes' => 3, 'slow' => 5 })
  end

  it 'resolves it for every post in a list, beside the fields directives and @field classes resolve' do
    create(:post, title: 'Long', body: body_of_450_words, tags: [create(:tag)], created_at: 1.day.ago)
    create(:post, title: 'Empty', body: nil, created_at: 2.days.ago)

    body = graphql('{ posts { data { title tagsCount commentsCount readingTime { words minutes } } } }')

    expect(body.dig('data', 'posts', 'data')).to eq(
      [{ 'title' => 'Long', 'tagsCount' => 1, 'commentsCount' => 0, 'readingTime' => { 'words' => 450, 'minutes' => 3 } },
       { 'title' => 'Empty', 'tagsCount' => 0, 'commentsCount' => 0, 'readingTime' => { 'words' => 0, 'minutes' => 1 } }]
    )
  end

  it 'leaves the fields Types::PostType does not define to the model and the directives' do
    post_record = create(:post, title: 'Plain')

    expect(graphql("{ post(id: #{post_record.id}) { title published author { id } } }").dig('data', 'post'))
      .to eq('title' => 'Plain', 'published' => true, 'author' => { 'id' => post_record.author_id.to_s })
  end
end
