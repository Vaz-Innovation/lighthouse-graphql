# frozen_string_literal: true

class Lighthouse::ReferenceResolver
  @resolvers = {}

  class << self
    def register(typename, &block)
      @resolvers[typename.to_s] = block
    end

    def resolve(typename, reference, context)
      resolver = @resolvers[typename.to_s]
      return nil unless resolver

      resolver.call(reference, context)
    end

    def clear!
      @resolvers.clear
    end
  end
end
