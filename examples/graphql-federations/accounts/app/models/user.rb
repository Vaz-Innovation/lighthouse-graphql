class User < ApplicationRecord
  ROLES = %w[member admin suspended].freeze

  has_many :likes, dependent: :destroy
  has_secure_token :api_token
  has_one_attached :avatar

  validates :name, presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }

  def admin?
    role == 'admin'
  end
end
