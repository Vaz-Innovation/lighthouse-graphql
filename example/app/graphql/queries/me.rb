# Resolves Query.me. @guard on the field already refused guests, so there is
# always a user here.
class Queries::Me < GraphQL::Schema::Resolver
  def resolve
    context[:current_user]
  end
end
