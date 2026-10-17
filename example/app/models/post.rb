class Post < ApplicationRecord
  belongs_to :author, class_name: 'User', inverse_of: :posts
  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  validates :title, presence: true, length: { maximum: 120 }

  scope :published, -> { where(published: true) }
end
