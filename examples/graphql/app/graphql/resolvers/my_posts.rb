# Resolves Query.myPosts. The class builds the query itself — the signed-in
# user's posts, which no directive could scope — and resolve_info.enhance_builder
# applies what the field declares on top: its @like on `title` and its @orderBy,
# as @all or @paginate would.
class Resolvers::MyPosts < Resolvers::BaseResolver
  def resolve(**)
    resolve_info.enhance_builder(context[:current_user].posts)
  end
end
