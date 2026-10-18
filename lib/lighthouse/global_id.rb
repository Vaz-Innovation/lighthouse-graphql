# frozen_string_literal: true

require 'base64'

# Relay global ids, as PHP Lighthouse's Base64GlobalId writes them: the type
# name and the id, joined by a colon, in base64 ("User:1" -> "VXNlcjox").
# Config.global_id takes another object with `encode(type, id)` and
# `decode(global_id)` -> [type, id], as PHP Lighthouse lets the GlobalId
# contract be rebound.
module Lighthouse::GraphQL::GlobalId
  module_function

  def encode(type, id)
    Base64.strict_encode64("#{type}:#{id}")
  end

  def decode(global_id)
    Base64.strict_decode64(global_id.to_s).split(':', 2)
  rescue ArgumentError
    []
  end

  # [type, id] for a global id a client sent, through Config.global_id; a
  # GraphQL::ExecutionError when it is not one.
  def decode!(global_id)
    type, id = Lighthouse::Config.global_id.decode(global_id)
    return [type, id] if type.present? && !id.nil?

    raise ::GraphQL::ExecutionError, "#{global_id.inspect} is not a valid global id."
  end
end
