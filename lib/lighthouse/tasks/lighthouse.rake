# frozen_string_literal: true

namespace :lighthouse do
  desc 'Write schema-directives.graphql and programmatic-types.graphql for IDE support (OUTPUT=dir, default Rails.root)'
  task ide_helper: :environment do
    output_dir = ENV.fetch('OUTPUT') { Rails.root.to_s }
    Lighthouse::IdeHelper.write(output_dir: output_dir).each { |path| puts "Wrote #{path}" }
  end
end
