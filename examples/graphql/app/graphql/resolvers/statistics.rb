# Holds methods that resolve Query fields, each named by @field(resolver:
# "Statistics@<method>"), as PHP Lighthouse's "Class@method": a plain class,
# not a Resolvers::BaseResolver, whose class method gets the root object, the
# arguments and the context.
class Resolvers::Statistics
  def self.counts(_root, _args, _context)
    { posts: Post.published.count, users: User.count, comments: Comment.count }
  end
end
