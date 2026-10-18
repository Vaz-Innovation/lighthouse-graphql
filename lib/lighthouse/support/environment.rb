# frozen_string_literal: true

# The application's environment, for @hide and @show: Rails.env, else
# RAILS_ENV or RACK_ENV, else "development".
module Lighthouse::Support::Environment
  module_function

  def current
    return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)

    ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
  end
end
