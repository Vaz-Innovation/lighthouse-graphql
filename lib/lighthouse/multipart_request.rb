# frozen_string_literal: true

require 'json'

# The GraphQL multipart request specification
# (https://github.com/jaydenseric/graphql-multipart-request-spec), which file
# uploads use: a multipart form with `operations` (the JSON operation, or a
# batch of them), `map` (each file's form key => the paths in `operations` it
# goes to, e.g. { "0": ["variables.avatar"] }) and the files. The controller
# concern reads it into the operation(s), with every file in place.
module Lighthouse::GraphQL::MultipartRequest
  module_function

  # The operation (a Hash) or batch (an Array), with the files in place; nil
  # when the request is not a multipart one.
  def operations(params)
    raw = param(params, 'operations')
    return unless raw

    operations = parse(raw)
    parse(param(params, 'map') || '{}').each do |key, paths|
      Array(paths).each { |path| place(operations, path.to_s.split('.'), param(params, key)) }
    end
    operations
  end

  def param(params, key)
    params[key.to_s] || params[key.to_sym]
  end

  def parse(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    value.is_a?(String) ? JSON.parse(value) : value
  end

  def place(target, segments, file)
    *parents, last = segments
    container = parents.reduce(target) { |node, segment| node.is_a?(Array) ? node[Integer(segment)] : node[segment] }
    raise ArgumentError, "The multipart map names a path that is not in the operations: #{segments.join('.')}" unless container

    container.is_a?(Array) ? container[Integer(last)] = file : container[last] = file
  end
end
