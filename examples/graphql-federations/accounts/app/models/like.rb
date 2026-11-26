# A user liked something written in the blog subgraph: a Post or a Comment, by its UUID.
class Like < ApplicationRecord
  belongs_to :user

  validates :authored_id, presence: true, uniqueness: { scope: :user_id }
end
