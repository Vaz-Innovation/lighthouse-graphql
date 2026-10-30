# frozen_string_literal: true

require_relative 'base'

# Rewrites the arguments a field receives, before it resolves, as PHP
# Lighthouse's argument directives do. On an argument or an input field, in the
# order the SDL lists them:
#
#   @globalId(decode:)  a Relay global id, decoded ([type, id], the type or the id)
#   @trim               leading and trailing whitespace removed
#   @hash               the value hashed with BCrypt, for a password column
#   @drop               the value removed: the resolver never sees it
#   @bind(class:)       the value replaced by the record(s) it identifies
#   @upload             the uploaded file stored with ActiveStorage (UploadStore), its blob's signed id passed
#
#   type Mutation {
#     signUp(email: String! @trim, password: String! @trim @hash, captcha: String @drop): User! @create
#     assign(task: ID! @bind(class: "Task"), user: ID! @bind(class: "User")): Task! @field(resolver: "Assign")
#   }
#
# @trim on a field trims every string it takes, nested inputs included. Lists
# and input objects are walked; input objects that change are copied, never
# mutated. Not a directive resolver: FieldResolverStack installs it twice, as
# two phases. :rewrite (@globalId, @trim, @drop) is outermost, so @guard, the
# @can* family and @validator see the rewritten values. :effects (@hash, @bind,
# @upload) runs once those have let the call through, around whatever resolves
# the field: a validator sees the password before it is hashed, and nothing is
# stored or looked up for a call that is refused.
class Lighthouse::GraphQL::DirectiveResolvers::ArgumentTransformsResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  PHASES = { rewrite: %w[globalId trim drop], effects: %w[hash bind upload] }.freeze
  NAMES = PHASES.values.flatten.freeze
  DROP = Object.new.freeze

  DEFINITIONS = {
    'trim' => <<~GRAPHQL.chomp,
      """
      Remove whitespace from the beginning and end of a given input.
      On a field, of every string input it takes.
      """
      directive @trim on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | FIELD_DEFINITION
    GRAPHQL
    'hash' => <<~GRAPHQL.chomp,
      """
      Hash an argument value with BCrypt (has_secure_password's), e.g. a password.
      """
      directive @hash on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
    'drop' => <<~GRAPHQL.chomp,
      """
      Ignore the user given value, don't pass it to the resolver.
      """
      directive @drop on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
    'bind' => <<~GRAPHQL.chomp,
      """
      Replace argument values with the corresponding model (or some other value)
      before passing them to the resolver.
      """
      directive @bind(
        "A model class, or a class whose `call(value, context)` returns what the value stands for."
        class: String!
        "The column the value is matched against, for a model."
        column: String = "id"
        "Relations to eager-load on the bound records."
        with: [String!] = []
        "Pass null instead of failing when no record matches."
        optional: Boolean = false
      ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
    'upload' => <<~GRAPHQL.chomp
      """
      Store the file an Upload argument carries with ActiveStorage, and pass along the
      signed id of its blob instead, which an attachment attribute (has_one_attached)
      attaches. This does not change the schema from a client perspective.
      """
      directive @upload(
        "The ActiveStorage service to store the file on (config/storage.yml). Defaults to config.active_storage.service."
        disk: String
        "The directory the stored file's key starts with."
        path: String = "/"
        "Whether the file is public. ActiveStorage sets that per service, so it must agree with the service's."
        public: Boolean = false
      ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
  }.freeze

  # Does the field take anything to rewrite in `phase`: @trim on the field
  # itself, or an argument at any depth of input types carrying one of the
  # phase's directives?
  def self.transforms?(field_def, phase)
    (phase == :rewrite && trims_all?(field_def)) || carried?(field_def.arguments, PHASES.fetch(phase))
  end

  def self.trims_all?(field_def)
    (field_def.ast_node&.directives || []).any? { |d| d.name == 'trim' }
  end

  def self.carried?(argument_defs, names, seen = Set.new)
    argument_defs.each_value.any? do |argument|
      type = argument.type.unwrap
      directives(argument, names).any? || (type.kind.input_object? && seen.add?(type.graphql_name) && carried?(type.arguments, names, seen))
    end
  end

  def self.directives(argument, names = NAMES)
    (argument.ast_node&.directives || []).select { |d| names.include?(d.name) }
  end

  def define_resolver(target_type_class)
    me = self
    argument_defs = @field_def.arguments
    trim_all = phase == :rewrite && self.class.trims_all?(@field_def)
    inner = capture_inner(target_type_class)

    resolve = lambda do |obj, args, ctx|
      inner.call(obj, args.is_a?(Hash) ? me.transform_hash(argument_defs, args, ctx, trim_all) : args, ctx)
    end
    return install(target_type_class, resolve) if phase == :rewrite

    # A field that fails leaves no file @upload stored for it behind.
    install(target_type_class, lambda do |obj, args, ctx|
      Lighthouse::GraphQL::UploadStore.purge_on_failure(ctx) { resolve.call(obj, args, ctx) }
    end)
  end

  # The values with every argument's directives applied; a dropped one removed.
  def transform_hash(argument_defs, values, ctx, trim_all)
    by_keyword = Lighthouse::Support::Arguments.keyword_index(argument_defs)
    values.each_with_object({}) do |(key, value), result|
      transformed = transform_argument(by_keyword[key.to_sym], value, ctx, trim_all)
      result[key] = transformed unless transformed.equal?(DROP)
    end
  end

  private

  def phase
    @opts.fetch(:phase, :rewrite)
  end

  def transform_argument(argument, value, ctx, trim_all)
    return value if argument.nil?

    value = nested(argument.type, value, ctx, trim_all)
    value = trim(value) if trim_all
    self.class.directives(argument, PHASES.fetch(phase)).reduce(value) do |current, directive|
      break DROP if current.equal?(DROP)

      apply(directive, argument, current, ctx)
    end
  end

  # Each directive's transform, a method taking (directive, argument, value, context).
  TRANSFORMS = { 'globalId' => :decode_global_id, 'trim' => :trim_value, 'hash' => :hash_value, 'bind' => :bind, 'upload' => :upload }.freeze

  def apply(directive, argument, value, ctx)
    return DROP if directive.name == 'drop'
    return value if value.nil?

    send(TRANSFORMS.fetch(directive.name), directive, argument, value, ctx)
  end

  def decode_global_id(directive, argument, value, ctx)
    mode = Lighthouse::Support::DirectiveArgs.literal(directive, 'decode') || 'ARRAY'
    decode(value, mode, ctx, global_id_types.model(directive, argument, mode, ctx))
  end

  def global_id_types
    @global_id_types ||= Lighthouse::GraphQL::DirectiveResolvers::GlobalIdTypes.new(self, @field_def)
  end

  def trim_value(_directive, _argument, value, _ctx) = trim(value)

  def hash_value(_directive, _argument, value, _ctx) = hash(value)

  def upload(directive, argument, value, ctx)
    return value.map { |item| upload(directive, argument, item, ctx) } if value.is_a?(Array)

    options = %w[disk path public].to_h { |name| [name.to_sym, Lighthouse::Support::DirectiveArgs.literal(directive, name)] }
    Lighthouse::GraphQL::UploadStore.call(value, argument: argument.graphql_name, **options)
  end

  # `model`: the class the id must be of, if any (GlobalIdTypes).
  def decode(value, mode, ctx = nil, model = nil)
    return value.map { |item| decode(item, mode, ctx, model) } if value.is_a?(Array)

    type, id = Lighthouse::GraphQL::GlobalId.decode!(value, ctx)
    if model && !Lighthouse::GraphQL::GlobalId.of_model?(value, type, model, ctx)
      raise ::GraphQL::ExecutionError, "#{value.inspect} is not a valid global id for #{model.name}."
    end

    { 'TYPE' => type, 'ID' => id }.fetch(mode.to_s, [type, id])
  end

  def trim(value)
    case value
    when String then value.strip
    when Array then value.map { |item| trim(item) }
    else value
    end
  end

  def hash(value)
    return value.map { |item| hash(item) } if value.is_a?(Array)

    begin
      require 'bcrypt'
    rescue LoadError
      raise Lighthouse::DefinitionError, '@hash needs the bcrypt gem (gem "bcrypt", as has_secure_password does).'
    end
    BCrypt::Password.create(value.to_s).to_s
  end

  def bind(directive, argument, value, ctx)
    Lighthouse::GraphQL::DirectiveResolvers::ArgumentBinding.new(directive, argument, @field_def).bind(value, ctx)
  end

  # An input object's own arguments, transformed in a copy.
  def nested(type, value, ctx, trim_all)
    type = type.unwrap
    return value unless type.kind.input_object? && !value.nil?
    return value.map { |item| nested(type, item, ctx, trim_all) } if value.is_a?(Array)

    transform_input(type, value, ctx, trim_all)
  end

  def transform_input(type, value, ctx, trim_all)
    values = value.respond_to?(:to_kwargs) ? value.to_kwargs : value
    return value unless values.is_a?(Hash)

    transformed = transform_hash(type.arguments, values, ctx, trim_all)
    return transformed unless value.respond_to?(:to_kwargs)

    value.dup.tap { |copy| copy.instance_variable_set(:@ruby_style_hash, transformed) }
  end
end
