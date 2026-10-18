# Resolves Query.search. It returns posts and users together: SearchResult is a
# union, and Lighthouse resolves each value to the type named after its model's
# class (a Post to Post, a User to User), as PHP Lighthouse does.
class Resolvers::Search < Resolvers::BaseResolver
  LIMIT = 10

  def resolve(term:)
    pattern = "%#{Post.sanitize_sql_like(term.strip)}%"
    # Arel's matches: LIKE, or ILIKE on PostgreSQL, so case never matters.
    Post.published.where(Post.arel_table[:title].matches(pattern)).limit(LIMIT).to_a +
      User.where(User.arel_table[:name].matches(pattern)).limit(LIMIT).to_a
  end
end
