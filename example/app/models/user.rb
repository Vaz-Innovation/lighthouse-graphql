class User < ApplicationRecord
  ROLES = %w[member admin].freeze

  has_many :posts, foreign_key: :author_id, inverse_of: :author, dependent: :destroy
  has_many :comments, foreign_key: :author_id, inverse_of: :author, dependent: :destroy

  has_secure_token :api_token
  # Set by Mutation.updateAvatar: @upload stores the file, and @update attaches its blob.
  has_one_attached :avatar

  validates :name, presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }

  def admin?
    role == 'admin'
  end

  # User.latestPostTitle calls it through @method, once @with has loaded every
  # user's posts in one query.
  def latest_post_title
    posts.max_by(&:created_at)&.title
  end

  # User.avatarUrl calls it through @method.
  def avatar_url
    Rails.application.routes.url_helpers.rails_blob_path(avatar, only_path: true) if avatar.attached?
  end
end
