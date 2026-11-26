# ReadingTime is not a model: Types::PostType#reading_time answers `{ post_id:, words: }`,
# and these methods compute the rest from it.
class Types::ReadingTimeType < Types::BaseObject
  def self.of(post) = { post_id: post.id, words: post.body.to_s.split.size }

  # The router asks for ReadingTime entities by their post's id (`_entities`),
  # to resolve `caption` with the contextual argument: every post of the group in one query.
  def self.resolve_references(representations, _context)
    posts = Post.where(id: representations.pluck(:postId)).index_by(&:id)
    representations.map { |representation| posts[representation[:postId]]&.then { |post| of(post) } }
  end

  def minutes(words_per_minute:)
    [(object[:words] / words_per_minute.to_f).ceil, 1].max
  end

  # The router passes the title of the post this reading time belongs to (@fromContext).
  def caption(post_title: nil)
    "#{post_title || 'This post'}: #{minutes(words_per_minute: 200)} min read"
  end
end
