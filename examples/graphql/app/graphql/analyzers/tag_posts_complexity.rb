# frozen_string_literal: true

# The analyzer Tag.posts names with @complexity(resolver: "TagPostsComplexity"),
# installed on AppSchema by Lighthouse. Its `complexity` (from the concern
# Analyzers::BaseComplexity includes) is what Tag.posts costs in the score
# max_complexity checks. With no `result` of its own, it adds no analysis of its own.
class Analyzers::TagPostsComplexity < Analyzers::BaseComplexity
  # A tag's posts are not paginated: assume a popular tag's worth of them.
  POSTS_PER_TAG = 25

  complexity ->(_context, _args, child_complexity) { 1 + (child_complexity * POSTS_PER_TAG) }
end
