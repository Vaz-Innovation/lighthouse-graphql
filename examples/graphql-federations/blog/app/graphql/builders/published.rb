# Applied by @builder(class: "Published") before the field resolves: receives
# the relation, the field's arguments and the GraphQL context, and returns the
# relation to use. Builders compose onto a query; they never resolve a field.
# The order is the field's: @orderBy(column: "created_at", direction: DESC)
# after whatever orderBy the client sends.
class Builders::Published
  def self.call(relation, _args, _context)
    relation.published
  end
end
