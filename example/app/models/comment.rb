class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :author, class_name: 'User', inverse_of: :comments

  validates :body, presence: true

  # A stable order, so cursors keep pointing at the same comments between pages.
  scope :chronological, -> { order(:created_at, :id) }
end
