# Resolves Query.searchPosts. Keyword arguments are the field's arguments in
# snake_case; `object` and `context` are available. Logic that is more than a
# filter lives in a class like this one, not in the schema.
class Resolvers::SearchPosts < Resolvers::BaseResolver
  MAX_RESULTS = 20

  # graphql-ruby's `complexity`, which Lighthouse applies to the field this class
  # resolves: what is selected on each post, once per result it may return.
  complexity ->(_context, _args, child_complexity) { 1 + (child_complexity * MAX_RESULTS) }

  def resolve(term:)
    pattern = "%#{Post.sanitize_sql_like(term.strip)}%"
    Post.published
        .where(Post.arel_table[:title].matches(pattern).or(Post.arel_table[:body].matches(pattern)))
        .order(created_at: :desc)
        .limit(MAX_RESULTS)
  end
end
