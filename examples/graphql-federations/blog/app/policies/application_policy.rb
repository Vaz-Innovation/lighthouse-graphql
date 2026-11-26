# Pundit policies back Lighthouse's @can* directives: `@canFind(ability: "update")`
# calls `PostPolicy#update?` with the post the argument identifies.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def create?
    user.present?
  end

  def update?
    false
  end

  def destroy?
    update?
  end
end
