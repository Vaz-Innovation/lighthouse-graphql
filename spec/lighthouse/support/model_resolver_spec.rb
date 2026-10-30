# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Lighthouse::Support::ModelResolver do
  describe '.model?' do
    it 'tells an Active Record model class from anything else' do
      expect([Widget, Post].map { |value| described_class.model?(value) }).to eq([true, true])
      expect([ActiveRecord::Base, String, Widget.new, 'Widget', nil].map { |value| described_class.model?(value) }).to all(be(false))
    end
  end

  describe '.model_class' do
    it 'answers the model a class or a name names, else nil' do
      expect([Widget, 'Widget', String, 'String', 'NoSuchThing', nil].map { |value| described_class.model_class(value) })
        .to eq([Widget, Widget, nil, nil, nil, nil])
    end
  end
end
