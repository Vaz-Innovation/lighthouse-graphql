# Applied by @builder(class: "Published") before the field resolves: receives
# the relation, the field's arguments and the GraphQL context, and returns the
# relation to use. Builders compose onto a query; they never resolve a field.
class Builders::Published
  def self.call(relation, _args, _context)
    relation.published.order(created_at: :desc, id: :desc)
  end
end
