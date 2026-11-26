# Resolves Mutation.like(id:) by convention. The like is accounts'; the post or
# comment is the blog subgraph's, so it answers the Authored entity by id, and the
# router asks each subgraph for the fields it has.
class Mutations::Like < Mutations::BaseMutation
  def resolve(id:)
    context[:current_user].likes.find_or_create_by!(authored_id: id)
    { id: id }
  end
end
