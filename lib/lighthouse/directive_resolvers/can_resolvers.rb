# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::DirectiveResolvers
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
  class CanDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
    COMMON_ARGUMENTS = [
      argument_sdl(
        'ability: String!',
        'The ability to check, which the policy answers with a predicate: "update" calls `PostPolicy#update?`.'
      ),
      argument_sdl('injectArgs: Boolean = false', "Pass the field's arguments to the policy method, as its first extra argument."),
      argument_sdl('args: CanArgs', 'Constant values to pass to the policy method, after the injected arguments.'),
      argument_sdl('action: CanAction = EXCEPTION_PASS', 'What to do when the check fails.'),
      argument_sdl('returnValue: CanArgs', 'The value to return, when `action` is RETURN_VALUE.')
    ].freeze

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

    # The SDL of a @can* directive: `description`, the arguments they share, then the `extra` ones.
    def self.definition_with(description, extra = [], locations: 'FIELD_DEFINITION')
      <<~GRAPHQL.chomp
        """
        #{description}
        """
        directive @#{directive_name}(
        #{[*COMMON_ARGUMENTS, *extra].join("\n")}
        ) repeatable on #{locations}
      GRAPHQL
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

    def self.definition
      definition_with(<<~TEXT.chomp, [FIND_ARGUMENT, MODEL_ARGUMENT, FIND_OR_FAIL_ARGUMENT, SCOPES_ARGUMENT])
        Check a policy against the models whose primary keys an argument holds, before the field resolves.
      TEXT
    end

    FIND_ARGUMENT = argument_sdl(
      'find: String!',
      'The path of the argument holding the id, or a list of ids, of the models to check: "id", or "input.ids".'
    )
    FIND_OR_FAIL_ARGUMENT = argument_sdl(
      'findOrFail: Boolean = true',
      'Fail when an id matches no model. With false, only the models found are checked.'
    )

    protected

    def authorize_before(_obj, args, ctx)
      model = model_class
      ids = ids_to_find(Lighthouse::Support::Arguments.plain(args))
      records = scoped(model.where(model.primary_key => ids)).to_a
      if directive_arg('findOrFail') != false && records.size < ids.size
        missing = ids.map(&:to_s) - records.map { |r| r.public_send(model.primary_key).to_s }
        raise ::GraphQL::ExecutionError, "Couldn't find #{model.name} with '#{model.primary_key}'=#{missing.join(', ')}"
      end

      authorize_each!(ctx, records, args)
    end

    # The ids at the `find:` path. Nothing there (a misspelt path, an argument
    # the client left out) is an error, as in PHP Lighthouse, so the field never
    # resolves with nothing checked. A `*` over an empty list finds no model to check.
    def ids_to_find(args)
      find = directive_arg('find').to_s
      ids = Lighthouse::Support::Arguments.dig(args, find)
      return ids.flatten.uniq unless ids.empty? && !empty_list_at?(args, find)

      raise ::GraphQL::ExecutionError, "Got no key to find a model at the expected input path: #{find}."
    end

    def empty_list_at?(args, find)
      return false unless find.include?('*')

      lists = Lighthouse::Support::Arguments.dig(args, find.split('.*').first)
      lists.any? && lists.all? { |list| list.respond_to?(:empty?) && list.empty? }
    end
  end

  class CanModelDirectiveResolver < CanDirectiveResolver
    def self.directive_name = 'canModel'

    def self.definition
      definition_with(<<~TEXT.chomp, [MODEL_ARGUMENT], locations: 'FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION')
        Check a policy against the model class itself, before the field resolves,
        e.g. `create?` before a @create. On an argument or input field, only when
        the client gives it a value: who may use it, e.g. `trashed`.
      TEXT
    end

    protected

    # On an argument (FieldResolverStack passes its path as `argument:`), only
    # when the client gave it a value.
    def authorize_before(_obj, args, ctx)
      path = @opts[:argument]
      return if path && Lighthouse::Support::Arguments.dig(Lighthouse::Support::Arguments.plain(args), path).empty?

      authorize!(ctx, model_class, args)
    end
  end

  class CanQueryDirectiveResolver < CanDirectiveResolver
    def self.directive_name = 'canQuery'

    def self.definition
      definition_with(<<~TEXT.chomp, [MODEL_ARGUMENT, SCOPES_ARGUMENT])
        Check a policy against each model the field's query would return,
        narrowed by the field's argument filters (@eq, @where, ...), before the field resolves.
      TEXT
    end

    protected

    # The records the field's argument filters (@eq, @where, ...) select. When the
    # client searches (@search), the records the search finds: all of them, not
    # only the page the field returns, as PHP Lighthouse checks what its Scout
    # builder gets. An engine outside the database (Searchkick) answers 10,000 at
    # most, and more that a page could reach is an error (Search::Result#every_record).
    def authorize_before(_obj, args, ctx)
      found = apply_where_filters(scoped(model_class.all), args, ctx, search_results: true, model_relation: true)
      authorize_each!(ctx, found.is_a?(Lighthouse::Search::Result) ? found.every_record : found.to_a, args)
    end
  end

  class CanResolvedDirectiveResolver < CanDirectiveResolver
    def self.directive_name = 'canResolved'

    def self.definition
      definition_with(<<~TEXT.chomp)
        Check a policy against whatever the field resolved to, each item of a list, after it resolves.
        The field runs first: only use it on fields that do not change data.
      TEXT
    end

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
      when Lighthouse::GraphQL::Pagination::Paginator then result.data
      when Lighthouse::GraphQL::Pagination::Connection then result.edges.pluck('node')
      when Hash then result.key?('data') ? Array(result['data']) : [result] # a simple paginator, or a record as a Hash
      else Lighthouse::Support::Arguments.list(result) || [result]
      end
    end
  end

  class CanRootDirectiveResolver < CanDirectiveResolver
    def self.directive_name = 'canRoot'

    def self.definition
      definition_with(<<~TEXT.chomp)
        Check a policy against the parent object of the field, before the field resolves.
      TEXT
    end

    protected

    def authorize_before(obj, args, ctx)
      authorize!(ctx, obj, args)
    end
  end
end
