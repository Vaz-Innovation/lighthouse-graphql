# A user of the accounts subgraph, read from its database. In the blog's schema
# User is that subgraph's entity, to which the blog adds what users wrote:
# `_entities` finds them here by id, and Post.author / Comment.author load them
# with @belongsTo, across the two databases.
class User < AccountsRecord
  # Never destroyed here: users are accounts'.
  has_many :posts, foreign_key: :author_id, inverse_of: :author, dependent: nil
  has_many :comments, foreign_key: :author_id, inverse_of: :author, dependent: nil

  def admin?
    role == 'admin'
  end

  # User.signature, which @requires(fields: "name"): the router sends the name
  # accounts holds with the representation, which Lighthouse sets on the record.
  def signature
    "#{name} · #{posts.size} #{'post'.pluralize(posts.size)}"
  end
end
