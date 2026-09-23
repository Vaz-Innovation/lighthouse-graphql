# frozen_string_literal: true

RSpec.describe Lighthouse::DirectiveRegistry do
  it 'resolves built-in directive resolver classes by name' do
    registry = described_class.new.register_defaults

    expect(registry.resolution_class('hasMany'))
      .to eq(Lighthouse::GraphQL::DirectiveResolvers::HasManyDirectiveResolver)
    expect(registry.resolution_class('paginate'))
      .to eq(Lighthouse::GraphQL::DirectiveResolvers::PaginateDirectiveResolver)
    expect(registry.resolution_class('auth'))
      .to eq(Lighthouse::GraphQL::DirectiveResolvers::AuthDirectiveResolver)
  end

  it 'registers the argument builders and new field-resolver directives' do
    registry = described_class.new.register_defaults

    %w[eq neq in notIn like where orderBy].each do |name|
      expect(registry.arg_builder_class(name)).to be_truthy
    end
    %w[rename count first hasOne].each do |name|
      expect(registry.resolution_class(name)).to be_truthy
    end
  end

  it 'registers a custom self-describing directive class without editing the generator' do
    custom = Class.new do
      def self.directive_name = 'customThing'
      def initialize(*); end
      def define_resolver(_target); end
    end

    registry = described_class.new
    registry.register(custom)

    expect(registry.resolution_class('customThing')).to eq(custom)
  end

  it 'ignores classes that are neither field resolvers, middleware, nor arg builders' do
    plain = Class.new do
      def self.directive_name = 'plain'
    end

    registry = described_class.new
    registry.register(plain)

    expect(registry.resolution_class('plain')).to be_nil
    expect(registry.arg_builder_class('plain')).to be_nil
  end
end
