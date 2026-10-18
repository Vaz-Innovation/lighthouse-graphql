# frozen_string_literal: true

# The counts @withCount loads, read off the record as Laravel's withCount
# attributes are: `user.posts_count`. The record is extended with this module
# (named, so it still marshals for @cache) and keeps them in an instance
# variable; a real column of the same name wins.
module Lighthouse::GraphQL::RelationCounts
  def self.write(record, relation, count)
    record.extend(self) unless record.is_a?(self)
    counts = record.instance_variable_get(:@lighthouse_relation_counts) || {}
    record.instance_variable_set(:@lighthouse_relation_counts, counts.merge("#{relation}_count" => count))
  end

  def respond_to_missing?(name, include_private = false)
    lighthouse_relation_count?(name) || super
  end

  def method_missing(name, *args, &block)
    return super unless args.empty? && lighthouse_relation_count?(name)

    @lighthouse_relation_counts[name.to_s]
  end

  private

  def lighthouse_relation_count?(name)
    @lighthouse_relation_counts&.key?(name.to_s)
  end
end
