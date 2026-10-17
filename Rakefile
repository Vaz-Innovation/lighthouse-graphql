# frozen_string_literal: true

# `build`, `install` and `release` come from bundler: `rake build` writes the
# packaged gem to pkg/, which is what both a local release and CI push.
require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

namespace :rbs do
  desc 'Validate the RBS signatures in sig/'
  task :validate do
    sh 'bundle exec rbs -I sig validate'
  end

  desc 'Run the suite with every Lighthouse method checked against its signature'
  task :test do
    env = {
      'RBS_TEST_TARGET' => 'Lighthouse::*',
      'RBS_TEST_OPT' => '-I sig',
      'RBS_TEST_LOGLEVEL' => 'error',
      'RBS_TEST_RAISE' => 'true'
    }
    sh env, 'bundle exec ruby -r rbs/test/setup -S rspec'
  end
end

desc 'Validate sig/ and check it against the suite'
task rbs: %w[rbs:validate rbs:test]

task default: %i[spec rubocop rbs]
