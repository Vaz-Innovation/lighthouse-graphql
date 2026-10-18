# Resolves Query.latestActivity: published posts and the comments on them,
# newest first. Authored is an interface Post and Comment implement, and
# Lighthouse resolves each value to its model's type, as for a union. `since`
# is a DateTime: Types::DateTimeType hands it over as a Time.
class Resolvers::LatestActivity < Resolvers::BaseResolver
  def resolve(first:, since: nil)
    posts = Post.published.order(created_at: :desc).limit(first)
    comments = Comment.joins(:post).merge(Post.published).order(created_at: :desc).limit(first)
    if since
      posts = posts.where(created_at: since..)
      comments = comments.where(created_at: since..)
    end
    (posts.to_a + comments.to_a).sort_by(&:created_at).reverse.first(first)
  end
end
