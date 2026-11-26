class UserPolicy < ApplicationPolicy
  # An email address is shown to its owner and to admins only (`@canRoot`).
  def view_email?
    user.present? && (user.admin? || record.id == user.id)
  end
end
