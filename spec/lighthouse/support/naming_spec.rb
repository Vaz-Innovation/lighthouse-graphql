# frozen_string_literal: true

# A Rails-free unit spec for the gem. The Rails-integration specs (directives
# resolving against ActiveRecord, federation, etc.) live in the consuming app.
RSpec.describe Lighthouse::Support::Naming do
  describe '.attribute' do
    it 'maps camelCase to snake_case' do
      expect(described_class.attribute('customAttributes')).to eq('custom_attributes')
    end

    it 'is idempotent for snake_case' do
      expect(described_class.attribute('custom_attributes')).to eq('custom_attributes')
    end
  end

  describe '.column' do
    it 'downcases an ALLCAPS enum key' do
      expect(described_class.column('ID')).to eq('id')
    end
  end

  describe '.fetch_arg' do
    it 'finds a snake_case key from a camelCase name' do
      expect(described_class.fetch_arg({ 'has_contact' => 1 }, 'hasContact')).to eq(1)
    end
  end

  describe '.derive_relation_name' do
    it 'derives a plural relation from a has-prefixed argument' do
      expect(described_class.derive_relation_name('hasContact')).to eq('contacts')
    end
  end
end
