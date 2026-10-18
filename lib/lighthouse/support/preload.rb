# frozen_string_literal: true

# Eager loading for @with and @lazyLoad: ActiveRecord's preloader, over records
# of any classes, with relation names as PHP Lighthouse writes them
# ("comments.author" is comments, and each comment's author).
module Lighthouse::Support::Preload
  module_function

  # ["comments.author", "tags"] -> [{ comments: :author }, :tags]
  def associations(names)
    Array(names).map do |name|
      *path, last = name.to_s.split('.').map(&:to_sym)
      path.reverse.reduce(last) { |nested, segment| { segment => nested } }
    end
  end

  # Load `associations` into `records`, grouped by class; a class that has no
  # such association is left alone. `scopes` (model scope names) narrow the
  # loaded records, as Laravel's constrained eager loads do.
  def records(records, associations, scopes = [])
    records.grep(::ActiveRecord::Base).group_by(&:class).each do |klass, group|
      own = associations.select { |association| klass.reflect_on_association(root(association)) }
      own.each { |association| preload(klass, group, association, scopes) }
    end
    records
  end

  def root(association)
    association.is_a?(Hash) ? association.keys.first : association
  end

  def preload(klass, records, association, scopes)
    scope = scoped(klass, association, scopes)
    preloader = ::ActiveRecord::Associations::Preloader
    if preloader.method_defined?(:call)
      preloader.new(records: records, associations: association, scope: scope).call # Rails >= 7
    else
      preloader.new.preload(records, association, scope)                             # Rails 6
    end
  end

  # The scopes applied to the association's model, or nil for none.
  def scoped(klass, association, scopes)
    return if scopes.blank?

    target = klass.reflect_on_association(root(association)).klass
    scopes.reduce(target.all) { |relation, scope| relation.public_send(scope) }
  end
end
