class Post < ApplicationRecord
  include PgSearch::Model

  belongs_to :author, class_name: 'User', inverse_of: :posts
  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  # Set by Mutation.createPost's images: @upload stores each file, and @create attaches the blobs.
  has_many_attached :images

  validates :title, presence: true, length: { maximum: 120 }

  scope :published, -> { where(published: true) }

  # Query.posts(search:) runs through it (@search): PostgreSQL full-text search, a match
  # in the title ranking above one in the body, and "Rail" finding "Rails".
  pg_search_scope :search, against: { title: 'A', body: 'B' }, using: { tsearch: { prefix: true } }

  # Post.summary(words:) calls it through @method, with the field's argument.
  def summary(words:)
    body.to_s.split.first(words).join(' ')
  end

  # Post.tagNames calls it through @method. Where User.posts' @lazyLoad has loaded
  # every post's tags at once, it reads them without a query.
  def tag_names
    tags.map(&:name).sort
  end
end
