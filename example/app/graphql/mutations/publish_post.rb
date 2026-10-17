# Resolves Mutation.publishPost. Keyword arguments are the field's arguments in
# snake_case; `object` and `context` are available. Authorization already ran:
# the field's @canFind(ability: "publish") checked PostPolicy#publish?.
class Mutations::PublishPost < GraphQL::Schema::Mutation
  def resolve(id:)
    post = Post.find(id)
    raise GraphQL::ExecutionError, 'This post is already published.' if post.published?

    post.update!(published: true)
    post
  end
end
