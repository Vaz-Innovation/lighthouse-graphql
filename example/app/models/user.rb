class User < ApplicationRecord
  ROLES = %w[member admin].freeze

  has_many :posts, foreign_key: :author_id, inverse_of: :author, dependent: :destroy
  has_many :comments, foreign_key: :author_id, inverse_of: :author, dependent: :destroy

  has_secure_token :api_token

  validates :name, presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }

  def admin?
    role == 'admin'
  end
end
