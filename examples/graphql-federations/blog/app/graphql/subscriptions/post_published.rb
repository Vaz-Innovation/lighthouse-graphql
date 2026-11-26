# Resolves Subscription.postPublished(authorId: ID). Open to guests: a published
# post is public.
#
# graphql-ruby updates only the subscribers whose arguments equal the trigger's, so
# a subscriber of `postPublished` and one of `postPublished(authorId: 3)` could not
# both be reached by one trigger. The Lighthouse concern Subscriptions::BaseSubscription
# includes follows PHP Lighthouse instead: one topic for the field, and `filter?`
# drops the posts a subscriber did not ask for. Compare Subscriptions::PostCreated,
# written with graphql-ruby's own hooks.
class Subscriptions::PostPublished < Subscriptions::BaseSubscription
  # Each subscriber's own `authorId` argument, or none for every author.
  def filter?(post, author_id: nil)
    author_id.nil? || post.author_id.to_s == author_id.to_s
  end
end
