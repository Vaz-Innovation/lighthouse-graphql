# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # The @can* family — PHP Lighthouse's authorization directives, checked
      # with Pundit by default (Config.authorizer): `ability: "update"` calls
      # `PostPolicy#update?`. Each directive differs only in WHAT it authorizes:
      #
      #   @canFind      the models whose primary keys an argument holds
      #   @canModel     the model class (e.g. create? before a @create)
      #   @canQuery     the models the field's query would return
      #   @canResolved  whatever the field resolved to (each item of a list)
      #   @canRoot      the parent object
      #
      # Shared arguments: `injectArgs` passes the field's arguments to the policy
      # method, `args` passes static values after them, and `action` decides what
      # a denial (or a @canFind miss) does — pass the error, replace it with a
      # generic "This action is unauthorized.", or return `returnValue` instead.
      # All are repeatable; they run after @guard and before validation.
      class CanDirectiveResolver < BaseDirectiveResolver
        COMMON_ARGUMENTS = 'ability: String!, injectArgs: Boolean = false, args: CanArgs, ' \
                           'action: CanAction = EXCEPTION_PASS, returnValue: CanArgs'

        TYPE_DEFINITIONS = {
          'CanArgs' => '"Any constant literal value: https://graphql.github.io/graphql-spec/draft/#sec-Input-Values"' \
                       "\nscalar CanArgs",
          'CanAction' => <<~GRAPHQL.chomp
            "What a @can* directive does when the policy denies the ability."
            enum CanAction {
              "Pass the error to the client."
              EXCEPTION_PASS
              "Throw a generic \\"This action is unauthorized.\\" error, concealing the real one."
              EXCEPTION_NOT_AUTHORIZED
              "Return the value of returnValue instead of resolving the field."
              RETURN_VALUE
            }
          GRAPHQL
        }.freeze

        def self.type_definitions = TYPE_DEFINITIONS

        def self.definition_with(extra = nil)
          "directive @#{directive_name}(#{[COMMON_ARGUMENTS, extra].compact.join(', ')}) repeatable on FIELD_DEFINITION"
        end

        def define_resolver(target_type_class)
          me = self
          inner = capture_inner(target_type_class)
          install(target_type_class, lambda do |obj, args, ctx|
            catch(me) { me.send(:authorize_and_resolve, inner, obj, args, ctx) }
          end)
        end

        protected

        def authorize_and_resolve(inner, obj, args, ctx)
          check { authorize_before(obj, args, ctx) }
          inner.call(obj, args, ctx)
        end

        def authorize_before(_obj, _args, _ctx)
          raise NotImplementedError
        end

        # Run an authorization step, turning its failure into what `action:` asks for.
        def check
          yield
        rescue ::GraphQL::ExecutionError
          case directive_arg('action')
          when 'EXCEPTION_NOT_AUTHORIZED' then raise Lighthouse::AuthorizationError
          when 'RETURN_VALUE' then throw(self, directive_arg('returnValue'))
          else raise
          end
        end

        def authorize!(ctx, record, args)
          ability = directive_arg('ability')
          return if Lighthouse::Support::Authorization.authorized?(ctx, record, ability, policy_args(args))

          raise Lighthouse::AuthorizationError
        end

        def authorize_each!(ctx, records, args)
          records.each { |record| authorize!(ctx, record, args) }
        end

        def policy_args(args)
          values = []
          values << Lighthouse::Support::Arguments.plain(args) if directive_arg('injectArgs')
          static = directive_arg('args')
          values.concat(static.is_a?(Array) ? static : [static]) unless static.nil?
          values
        end

        def scoped(relation)
          Array(directive_arg('scopes')).reduce(relation) { |acc, scope| acc.public_send(scope) }
        end
      end

      class CanFindDirectiveResolver < CanDirectiveResolver
        def self.directive_name = 'canFind'
        def self.definition = definition_with('find: String!, model: String, findOrFail: Boolean = true, scopes: [String!]')

        protected

        def authorize_before(_obj, args, ctx)
          model = model_class
          ids = Lighthouse::Support::Arguments.dig(Lighthouse::Support::Arguments.plain(args), directive_arg('find')).flatten.uniq
          records = scoped(model.where(model.primary_key => ids)).to_a
          if directive_arg('findOrFail') != false && records.size < ids.size
            missing = ids.map(&:to_s) - records.map { |r| r.public_send(model.primary_key).to_s }
            raise ::GraphQL::ExecutionError, "Couldn't find #{model.name} with '#{model.primary_key}'=#{missing.join(', ')}"
          end

          authorize_each!(ctx, records, args)
        end
      end

      class CanModelDirectiveResolver < CanDirectiveResolver
        def self.directive_name = 'canModel'
        def self.definition = definition_with('model: String')

        protected

        def authorize_before(_obj, args, ctx)
          authorize!(ctx, model_class, args)
        end
      end

      class CanQueryDirectiveResolver < CanDirectiveResolver
        def self.directive_name = 'canQuery'
        def self.definition = definition_with('model: String, scopes: [String!]')

        protected

        # The records the field's argument filters (@eq, @where, ...) select.
        def authorize_before(_obj, args, ctx)
          authorize_each!(ctx, apply_where_filters(scoped(model_class.all), args).to_a, args)
        end
      end

      class CanResolvedDirectiveResolver < CanDirectiveResolver
        def self.directive_name = 'canResolved'
        def self.definition = definition_with

        protected

        # The resolver runs first: only use it on fields that do not mutate data.
        def authorize_and_resolve(inner, obj, args, ctx)
          result = inner.call(obj, args, ctx)
          check { authorize_each!(ctx, resolved_records(result), args) }
          result
        end

        def resolved_records(result)
          case result
          when nil then []
          when Pagination::Paginator then result.data
          when Pagination::Connection then result.edges.map { |edge| edge['node'] }
          when Hash then result.key?('data') ? Array(result['data']) : [result] # a simple paginator, or a record as a Hash
          else Lighthouse::Support::Arguments.list(result) || [result]
          end
        end
      end

      class CanRootDirectiveResolver < CanDirectiveResolver
        def self.directive_name = 'canRoot'
        def self.definition = definition_with

        protected

        def authorize_before(obj, args, ctx)
          authorize!(ctx, obj, args)
        end
      end
    end
  end
end
