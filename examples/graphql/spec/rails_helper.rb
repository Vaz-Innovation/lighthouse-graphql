require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative 'postgres_container'
require_relative '../config/environment'
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'

Rails.root.glob('spec/support/**/*.rb').each { |file| require file }
require_relative 'search_engines'

# Records reach a Searchkick index only when a spec reindexes them: no job, and no
# engine needed, for the specs that create comments without searching them.
Searchkick.disable_callbacks

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include GraphqlHelpers, type: :request
  config.include LiveCable, :live_cable
  config.after(:each, :live_cable) { close_live_clients }

  # @cache entries and persisted queries live in Rails.cache (a memory store in test).
  config.before { Rails.cache.clear }
end
