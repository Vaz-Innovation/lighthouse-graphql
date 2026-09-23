# frozen_string_literal: true

# `build`, `install` and `release` come from bundler: `rake build` writes the
# packaged gem to pkg/, which is what both a local release and CI push.
require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec
