# Resolves Query.popularTags, named by @field(resolver: "Tags::Popular"): on Query
# the name is looked up in the resolvers namespace, so the field's name and the
# class's need not match. A root field has no parent, so `object` is nil; the
# class finds what it returns on its own, as Resolvers::Me and SearchPosts do.
class Resolvers::Tags::Popular < Resolvers::BaseResolver
  def resolve(limit:)
    Tag.joins(:posts)
       .merge(Post.published)
       .group(:id)
       .order(Arel.sql('COUNT(posts.id) DESC'), :name)
       .limit(limit)
  end
end
