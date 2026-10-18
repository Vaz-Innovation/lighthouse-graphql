class Tag < ApplicationRecord
  has_many :taggings, dependent: :destroy
  has_many :posts, through: :taggings

  validates :name, presence: true, uniqueness: true

  # Tag.usage calls it through @method; @withCount has set posts_count, the
  # number of its published posts, on every tag at once.
  def usage
    "#{posts_count} published #{'post'.pluralize(posts_count)}"
  end
end
