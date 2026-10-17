# Resolves Subscription.commentAdded(postId: ID). Without `postId` a subscriber
# hears every new comment; with it, only the comments on that post.
#
# The optional argument is why this class includes Lighthouse's concern: plain
# graphql-ruby matches a trigger to the subscribers with equal arguments, so one
# trigger could not reach both `commentAdded` and `commentAdded(postId: 3)`. With
# the concern every subscriber of the field shares one topic, and `filter?` drops
# the comments a subscriber did not ask for.
class Subscriptions::CommentAdded < GraphQL::Schema::Subscription
  include Lighthouse::GraphQL::Subscription

  # The subscriber's own `postId` argument (snake_case here), or none for every post.
  # The comments on a draft stay with those who may see the draft (PostPolicy#update?:
  # its author and admins), as postCreated keeps the draft itself.
  def filter?(comment, post_id: nil)
    return false unless post_id.nil? || comment.post_id.to_s == post_id.to_s

    comment.post.published? || PostPolicy.new(context[:current_user], comment.post).update?
  end
end
