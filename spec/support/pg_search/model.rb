# frozen_string_literal: true

# What `include PgSearch::Model` stands for when the gem is not in the bundle,
# laid out as the gem is: `pg_search_scope` defines each scope as a class method
# from pg_search/model.rb, which Search::PgSearch tells a pg_search scope by.
module FakeSearch; end

module FakeSearch::PgSearchModel
  def self.included(model) = model.extend(ClassMethods)

  module ClassMethods
    def pg_search_scope(name, scope)
      define_singleton_method(name) { |*args| instance_exec(*args, &scope) }
    end
  end
end
