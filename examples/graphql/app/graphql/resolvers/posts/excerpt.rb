# Resolves Post.excerpt(length:), named by @field(resolver: "Posts::Excerpt").
# A field of a type takes arguments as a Query field does: they arrive as keyword
# arguments to `resolve`, with the SDL's default when the client leaves one out,
# and `object` is the parent Post.
class Resolvers::Posts::Excerpt < Resolvers::BaseResolver
  def resolve(length:)
    object.body&.truncate(length, separator: ' ')
  end
end
