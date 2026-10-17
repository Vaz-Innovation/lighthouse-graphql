# frozen_string_literal: true

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
class Lighthouse::DirectiveRegistry
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
    @definitions = {}
    @type_definitions = {}
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
  # (outermost, so it executes first). From the outside in: empty strings
  # converted to null (so everything below sees the converted arguments), authentication,
  # authorization, argument validation, then @cache (so a cache hit is still
  # authorized and validated), @clearCache (which acts once the resolver
  # succeeded), @event (likewise), and finally the data resolver (0).
  RESOLUTION_ORDER = {
    'convertEmptyStringsToNull' => 6,
    'guard' => 5, 'auth' => 5,
    'canFind' => 4, 'canModel' => 4, 'canQuery' => 4, 'canResolved' => 4, 'canRoot' => 4,
    'validator' => 3,
    'cache' => 2,
    'clearCache' => 1, 'event' => 1
  }.freeze

  def resolution_order(name)
    RESOLUTION_ORDER.fetch(name.to_s, 0)
  end

  # A wrapper decorates whatever resolves the field; anything else resolves it.
  def wrapper?(name)
    resolution_order(name).positive?
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
    definitions = @definitions.dup
    (@resolution.values + @arg_builders.values).uniq.each do |klass|
      next unless klass.respond_to?(:directive_name) && klass.respond_to?(:definition)

      text = safe_definition(klass)
      definitions[klass.directive_name.to_s] = text if text
    end
    definitions
  end

  # Contribute the SDL definition of a directive that has no registered class
  # of its own — one implemented inside another directive or manipulator
  # (e.g. @builder, @whereConditions) — so it is injected like the rest.
  def register_definition(name, definition)
    @definitions[name.to_s] = definition
    self
  end

  # Types that directive definitions refer to (`enum CanAction`, `input
  # ClearCacheIdSource`, ...), contributed by a class's `type_definitions`
  # ({ "Name" => "enum Name { ... }" }) or registered here. Injected next to
  # the directives that need them; shared by name, so declared only once.
  def register_type_definition(name, definition)
    @type_definitions[name.to_s] = definition
    self
  end

  def type_definitions
    types = @type_definitions.dup
    (@resolution.values + @arg_builders.values).uniq.each do |klass|
      types.merge!(klass.type_definitions) if klass.respond_to?(:type_definitions)
    end
    types
  end

  # Register an SDL manipulator: any object responding to `manipulate(sdl)` and
  # returning the (possibly transformed) SDL string. These run before the
  # schema is built to inject Connection/Paginator types, whereConditions
  # inputs, orderBy enums, etc. Order of registration is preserved.
  def register_manipulator(manipulator)
    @sdl_manipulators << manipulator unless @sdl_manipulators.include?(manipulator)
    self
  end

  attr_reader :sdl_manipulators

  # Fold every registered manipulator over the SDL string.
  def manipulate_sdl(sdl)
    @sdl_manipulators.reduce(sdl) { |acc, manipulator| manipulator.manipulate(acc) }
  end

  # The built-in directives, by constant name under DirectiveResolvers (and
  # Directives::Arguments for the argument builders). Names rather than
  # classes, so the classes are looked up only when the defaults are
  # registered, after every file has loaded.
  NAMED_RESOLVERS = {
    'all' => :AllDirectiveResolver,
    'find' => :FindDirectiveResolver,
    'first' => :FirstDirectiveResolver,
    'paginate' => :PaginateDirectiveResolver,
    'aggregate' => :AggregateDirectiveResolver,
    'count' => :CountDirectiveResolver,
    'field' => :FieldDirectiveResolver,
    'rename' => :RenameDirectiveResolver,
    'method' => :MethodDirectiveResolver,
    'auth' => :AuthDirectiveResolver,
    'guard' => :GuardDirectiveResolver
  }.freeze

  # Relationships, mutations, authorization, caching and validation: self-describing classes.
  SELF_DESCRIBING_RESOLVERS = %i[
    HasManyDirectiveResolver BelongsToManyDirectiveResolver MorphManyDirectiveResolver
    MorphToManyDirectiveResolver HasOneDirectiveResolver MorphOneDirectiveResolver
    BelongsToDirectiveResolver MorphToDirectiveResolver
    CreateDirectiveResolver CreateManyDirectiveResolver
    UpdateDirectiveResolver UpdateManyDirectiveResolver
    UpsertDirectiveResolver UpsertManyDirectiveResolver DeleteDirectiveResolver
    ForceDeleteDirectiveResolver RestoreDirectiveResolver
    CanFindDirectiveResolver CanModelDirectiveResolver CanQueryDirectiveResolver
    CanResolvedDirectiveResolver CanRootDirectiveResolver
    CacheDirectiveResolver ClearCacheDirectiveResolver EventDirectiveResolver
    ValidatorDirectiveResolver ConvertEmptyStringsToNullDirectiveResolver
  ].freeze

  # Argument-builder filter/sort directives.
  ARG_BUILDERS = %i[Eq Neq In NotIn Like Where WhereKey OrderBy Trashed WithoutGlobalScopes].freeze

  # Read by other directives rather than resolving anything themselves.
  PASSIVE_DEFINITIONS = {
    'spread' => 'directive @spread on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION',
    'inject' => 'directive @inject(context: String!, name: String!) repeatable on FIELD_DEFINITION',
    'cacheKey' => 'directive @cacheKey on FIELD_DEFINITION'
  }.freeze

  def register_defaults
    resolvers = Lighthouse::GraphQL::DirectiveResolvers
    NAMED_RESOLVERS.each { |name, constant| register(name, resolvers.const_get(constant, false)) }
    SELF_DESCRIBING_RESOLVERS.each { |constant| register(resolvers.const_get(constant, false)) }
    ARG_BUILDERS.each { |constant| register(Lighthouse::GraphQL::Directives::Arguments.const_get(constant, false)) }

    # SDL manipulators run in registration order during the manipulation phase.
    register_manipulator(Lighthouse::GraphQL::Directives::PaginationManipulator)
    register_manipulator(Lighthouse::GraphQL::Directives::WhereConditionsDirective)
    register_manipulator(Lighthouse::GraphQL::Directives::SoftDeletesDirective)

    register_default_definitions
    self
  end

  private

  # SDL of the directives (and the types they refer to) that no registered
  # class contributes.
  def register_default_definitions
    register_definition('builder', Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier::DEFINITION)
    PASSIVE_DEFINITIONS.each { |name, definition| register_definition(name, definition) }
    register_definition('cacheControl', Lighthouse::GraphQL::CacheControl::DEFINITION)
    Lighthouse::GraphQL::CacheControl::TYPE_DEFINITIONS.each { |name, sdl| register_type_definition(name, sdl) }
    register_definition('feature', Lighthouse::GraphQL::FeatureDirective::DEFINITION)
    Lighthouse::GraphQL::FeatureDirective::TYPE_DEFINITIONS.each { |name, sdl| register_type_definition(name, sdl) }
    Lighthouse::GraphQL::Directives::WhereConditionsDirective::DEFINITIONS.each do |name, definition|
      register_definition(name, definition)
    end
    Lighthouse::GraphQL::Directives::SoftDeletesDirective::DEFINITIONS.each { |name, definition| register_definition(name, definition) }
  end

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
