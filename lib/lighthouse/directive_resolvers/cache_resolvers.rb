# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::DirectiveResolvers
  # @cache — keep a field's resolved value in Rails.cache (Caching.store).
  #
  # The key covers the parent type and its key (the field marked @cacheKey,
  # else the first `ID` field; none on Query/Mutation), the field, and its
  # arguments; `private: true` adds the authenticated user, so each user gets
  # their own entry (guests share one). `maxAge` is in seconds; without it
  # entries live until @clearCache or eviction. Lists and relations are
  # cached as arrays; a value the store cannot serialize (e.g. a connection)
  # is reported through Config.on_error and returned uncached.
  class CacheDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
    def self.directive_name = 'cache'
    def self.definition = 'directive @cache(maxAge: Int, private: Boolean = false) on FIELD_DEFINITION'

    ROOT_TYPES = %w[Query Mutation Subscription].freeze

    def define_resolver(target_type_class)
      type_name = @type_def.graphql_name
      field_name = @field_def.name
      max_age = directive_arg('maxAge')
      per_user = directive_arg('private') == true
      parent_key = parent_key_reader
      inner = capture_inner(target_type_class)

      install(target_type_class, lambda do |obj, args, ctx|
        user_key = per_user ? CacheDirectiveResolver.user_key(ctx) : nil
        key = Lighthouse::GraphQL::Caching.entry_key(type_name, parent_key&.call(obj), field_name, args, user_key)
        cached = Lighthouse::GraphQL::Caching.store.read(key)
        next cached[:value] if cached.is_a?(Hash) && cached.key?(:value)

        value = CacheDirectiveResolver.materialize(inner.call(obj, args, ctx))
        CacheDirectiveResolver.write(key, value, max_age, ctx)
        value
      end)
    end

    def self.user_key(ctx)
      user = Lighthouse::Support::Authorization.authenticated_user(ctx)
      return nil if user.nil?

      "user:#{user.respond_to?(:id) ? user.id : user}"
    end

    def self.materialize(value)
      Lighthouse::Support::Arguments.list(value) || value
    end

    def self.write(key, value, max_age, ctx)
      Lighthouse::GraphQL::Caching.store.write(key, { value: value }, expires_in: max_age)
    rescue TypeError, ArgumentError, NoMethodError => e
      Lighthouse::Config.handle_error(e, ctx)
    end

    private

    # A callable reading the parent's cache key, or nil on root types.
    def parent_key_reader
      return nil if ROOT_TYPES.include?(@type_def.graphql_name)

      key_field = cache_key_field
      return nil unless key_field

      name = key_field.name
      ->(obj) { obj.nil? ? nil : Lighthouse::Support::Arguments.read(obj, name) }
    end

    # The field marked @cacheKey, else the first `ID` field.
    def cache_key_field
      fields = @type_def.fields.values
      fields.find { |f| cache_key?(f) } || fields.find { |f| f.type.unwrap.graphql_name == 'ID' }
    end

    def cache_key?(field)
      field.ast_node&.directives&.any? { |d| d.name == 'cacheKey' }
    end
  end

  # @clearCache — on a mutation, invalidate @cache entries once the field
  # resolved successfully. `type` alone clears all of that type's entries;
  # `idSource` narrows it to the ids found at an argument path
  # (`{ argument: "input.id" }`) or a result path (`{ field: "*.id" }`), and
  # `field` to a single field.
  class ClearCacheDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
    def self.directive_name = 'clearCache'

    def self.definition
      'directive @clearCache(type: String!, idSource: ClearCacheIdSource, field: String) ' \
        'repeatable on FIELD_DEFINITION'
    end

    def self.type_definitions
      {
        'ClearCacheIdSource' => <<~GRAPHQL.chomp
          "Where @clearCache finds the ids to clear. Exactly one of the fields must be given."
          input ClearCacheIdSource {
            "Path of an argument the field is applied to, e.g. \\"input.id\\"."
            argument: String
            "Path of a field in the result, e.g. \\"*.id\\" for a list."
            field: String
          }
        GRAPHQL
      }
    end

    def define_resolver(target_type_class)
      type = directive_arg('type')
      field = directive_arg('field')
      source = directive_arg('idSource') || {}
      inner = capture_inner(target_type_class)

      install(target_type_class, lambda do |obj, args, ctx|
        result = inner.call(obj, args, ctx)
        ids =
          if source['argument']
            Lighthouse::Support::Arguments.dig(Lighthouse::Support::Arguments.plain(args), source['argument'])
          elsif source['field']
            Lighthouse::Support::Arguments.dig(result, source['field'])
          end

        if ids.nil?
          Lighthouse::GraphQL::Caching.clear(type, field: field)
        else
          ids.flatten.uniq.each { |id| Lighthouse::GraphQL::Caching.clear(type, id: id, field: field) }
        end
        result
      end)
    end
  end
end
