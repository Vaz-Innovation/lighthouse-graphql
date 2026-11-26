class PostPolicy < ApplicationPolicy
  # Authors manage their own posts; admins manage everyone's.
  def update?
    user.present? && (user.admin? || record.author_id == user.id)
  end

  def publish?
    update?
  end
end
