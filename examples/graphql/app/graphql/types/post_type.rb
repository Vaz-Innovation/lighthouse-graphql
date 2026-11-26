# The Ruby side of the SDL's Post type, in graphql-ruby's folder structure. Types::BaseObject
# includes Lighthouse::GraphQL::Type, so it is Lighthouse's: a field of Post with no
# resolving directive calls the method of its snake_case name when this class defines it,
# with `object` the post and `context` the query's context. The SDL still declares every
# field; the rest are read off the model, or resolved by their directives.
class Types::PostType < Types::BaseObject
  # Post.readingTime: not a column nor a model, a value the fields of the
  # ReadingTime type are read from (words) or computed on (Types::ReadingTimeType).
  def reading_time
    { words: object.body.to_s.split.size }
  end
end
