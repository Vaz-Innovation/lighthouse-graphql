# Resolves Post.tagsCount, named by @field(resolver: "Posts::TagsCount").
# On a field of a type other than Query or Mutation, `object` is the parent: the
# Post this field belongs to (PHP Lighthouse's `$root`). dataload_association
# batches the tags of every post in the response into one query, so listing
# posts with their tagsCount does not run one query per post.
class Resolvers::Posts::TagsCount < Resolvers::BaseResolver
  def resolve
    dataload_association(object, :tags).size
  end
end
