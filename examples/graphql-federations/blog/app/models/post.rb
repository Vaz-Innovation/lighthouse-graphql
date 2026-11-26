class Post < ApplicationRecord
  include PgSearch::Model

  belongs_to :author, class_name: 'User', inverse_of: :posts
  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  validates :title, presence: true, length: { maximum: 120 }

  scope :published, -> { where(published: true) }

  # Query.posts(search:) ranks matches with this scope (@search).
  pg_search_scope :search, against: { title: 'A', body: 'B' }, using: { tsearch: { prefix: true } }

  def summary(words:)
    body.to_s.split.first(words).join(' ')
  end
end
