# frozen_string_literal: true

# The response's data so far, as the client puts it together (Run): the first
# payload's data, then each later entry's merged in at its path.
#
# Nothing is copied whole, and no payload changes: the tree holds the first
# payload's data and the entries' as they are, and each Hash or list later data
# goes in is copied (shallowly) the first time it does, with the ones above it.
class Lighthouse::GraphQL::Incremental::Tree
  attr_reader :data

  # What `path` leads to in `data` (Hashes and lists), or nil where it leads nowhere.
  def self.at(data, path)
    path.reduce(data) { |value, key| (value.is_a?(Array) && key.is_a?(Integer)) || value.is_a?(Hash) ? value[key] : nil }
  end

  def initialize(data)
    @data = data
    @own = {}.compare_by_identity
  end

  def at(path) = self.class.at(@data, path)

  # The data as it is now, which later merges leave as it is (they copy what they change).
  def snapshot
    @own.clear
    @data
  end

  def present?(path) = !at(path).nil?

  # A fragment's data, at the path of its object.
  def merge(path, data)
    target = own_path(path) or return
    merge_into(target, data)
  end

  # A stream's items, after the list's.
  def append(path, items)
    own_path(path)&.concat(items)
  end

  private

  # The containers along `path`, the tree's own (copied where they were not yet); the last.
  def own_path(path)
    return nil unless @data.is_a?(Hash)

    container = @data = own(@data)
    path.each do |key|
      child = self.class.at(container, [key])
      return nil unless child.is_a?(Hash) || child.is_a?(Array)

      container = container[key] = own(child)
    end
    container
  end

  def merge_into(target, data)
    return unless target.is_a?(Hash)

    data.each { |key, value| target[key].is_a?(Hash) && value.is_a?(Hash) ? merge_into(target[key] = own(target[key]), value) : target[key] = value }
  end

  def own(container)
    @own.key?(container) ? container : container.dup.tap { |copy| @own[copy] = true }
  end
end
