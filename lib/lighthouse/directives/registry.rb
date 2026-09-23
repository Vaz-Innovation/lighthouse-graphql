# frozen_string_literal: true

module Lighthouse
  # Maps directive names to the classes that implement them, so the
  # SchemaGenerator can dispatch by iterating the registry instead of a
  # hardcoded `case` statement. Adding a directive is "write one class and
  # register it" — no generator edits.
  #
  # Two registration styles are supported during the migration to clean,
  # self-describing directive classes:
  #
  #   register('hasMany', SomeLegacyResolverClass)   # explicit name
  #   register(MyDirectiveClass)                      # class responds to .directive_name
  #
  # A registered class is classified as a field resolver when it includes
  # Contracts::FieldResolver OR responds to the legacy `#define_resolver`
  # instance method.
  class DirectiveRegistry
    class << self
      def default
        @default ||= new.tap(&:register_defaults)
      end

      # Allow the host app to extend the default registry from an initializer.
      def register(name_or_klass, klass = nil)
        default.register(name_or_klass, klass)
      end
    end

    def initialize
      @resolution = {}
      @arg_builders = {}
      @sdl_manipulators = []
    end

    def register(name_or_klass, klass = nil)
      if klass.nil? && name_or_klass.respond_to?(:directive_name)
        klass = name_or_klass
        name = klass.directive_name
      else
        name = name_or_klass
      end

      if arg_builder?(klass)
        @arg_builders[name.to_s] = klass
      elsif resolver?(klass)
        @resolution[name.to_s] = klass
      end
      self
    end

    def resolution_class(name)
      @resolution[name.to_s]
    end

    # Application order for wrapping/resolution directives on a field. Lower is
    # applied first (innermost, closest to the data); higher is applied last
    # (outermost, so it executes first). Authentication guards run outermost;
    # @can wraps the resolver to authorize its result.
    def resolution_order(name)
      case name.to_s
      when 'guard', 'auth' then 2
      when 'can' then 1
      else 0
      end
    end

    def resolution_names
      @resolution.keys
    end

    # Argument-builder directives (@eq, @neq, @in, @notIn, @like, @where,
    # @orderBy) compose constraints onto a relation at resolve time.
    def arg_builder_class(name)
      @arg_builders[name.to_s]
    end

    def arg_builder_names
      @arg_builders.keys
    end

    # SDL `directive @name(...) on ...` definitions contributed by registered,
    # self-describing directive classes. The generator injects these so the app
    # does not have to hand-declare every directive it uses.
    # Returns { "name" => "directive @name(...) on ..." }.
    def directive_definitions
      definitions = {}
      (@resolution.values + @arg_builders.values).uniq.each do |klass|
        next unless klass.respond_to?(:directive_name) && klass.respond_to?(:definition)

        text = safe_definition(klass)
        definitions[klass.directive_name.to_s] = text if text
      end
      definitions
    end

    # Register an SDL manipulator: any object responding to `manipulate(sdl)` and
    # returning the (possibly transformed) SDL string. These run before the
    # schema is built to inject Connection/Paginator types, whereConditions
    # inputs, orderBy enums, etc. Order of registration is preserved.
    def register_manipulator(manipulator)
      @sdl_manipulators << manipulator unless @sdl_manipulators.include?(manipulator)
      self
    end

    def sdl_manipulators
      @sdl_manipulators
    end

    # Fold every registered manipulator over the SDL string.
    def manipulate_sdl(sdl)
      @sdl_manipulators.reduce(sdl) { |acc, manipulator| manipulator.manipulate(acc) }
    end

    def register_defaults
      dr = Lighthouse::GraphQL::DirectiveResolvers
      {
        'hasMany' => dr::HasManyDirectiveResolver,
        'belongsTo' => dr::BelongsToDirectiveResolver,
        'belongsToMany' => dr::BelongsToManyDirectiveResolver,
        'hasOne' => dr::HasOneDirectiveResolver,
        'all' => dr::AllDirectiveResolver,
        'find' => dr::FindDirectiveResolver,
        'first' => dr::FirstDirectiveResolver,
        'paginate' => dr::PaginateDirectiveResolver,
        'aggregate' => dr::AggregateDirectiveResolver,
        'count' => dr::CountDirectiveResolver,
        'field' => dr::FieldDirectiveResolver,
        'rename' => dr::RenameDirectiveResolver,
        'method' => dr::MethodDirectiveResolver,
        'auth' => dr::AuthDirectiveResolver,
        'guard' => dr::GuardDirectiveResolver,
        'can' => dr::CanDirectiveResolver
      }.each { |name, k| register(name, k) }

      # Argument-builder filter/sort directives.
      args = Lighthouse::GraphQL::Directives::Arguments
      [args::Eq, args::Neq, args::In, args::NotIn, args::Like, args::Where, args::OrderBy]
        .each { |k| register(k) }

      # SDL manipulators run in registration order during the manipulation phase.
      register_manipulator(Lighthouse::GraphQL::Directives::RelationDirective)
      register_manipulator(Lighthouse::GraphQL::Directives::WhereConditionsDirective)

      self
    end

    private

    def safe_definition(klass)
      klass.definition
    rescue StandardError
      nil
    end

    def arg_builder?(klass)
      klass.respond_to?(:include?) && klass.include?(Lighthouse::Contracts::ArgBuilder)
    end

    def resolver?(klass)
      return false unless klass

      (klass.respond_to?(:include?) && klass.include?(Lighthouse::Contracts::FieldResolver)) ||
        klass.method_defined?(:define_resolver) ||
        klass.method_defined?(:resolve_field)
    end
  end
end
