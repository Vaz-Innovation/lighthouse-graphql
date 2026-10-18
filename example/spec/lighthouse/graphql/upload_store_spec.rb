require 'rails_helper'

# Where @upload puts a file: a blob on one of the app's ActiveStorage services
# (config/storage.yml), as PHP Lighthouse's @upload puts it on a Laravel disk.
RSpec.describe Lighthouse::GraphQL::UploadStore do
  let(:file) { Rack::Test::UploadedFile.new(StringIO.new('png bytes'), 'image/png', original_filename: 'me.png') }

  def blob(signed_id) = ActiveStorage::Blob.find_signed!(signed_id)
  def store(value, **options) = described_class.call(value, argument: 'avatar', **options)

  it 'stores a blob on the default service, its key under `path`, and answers its signed id' do
    stored = blob(store(file, path: '/avatars/'))

    expect(stored).to have_attributes(service_name: 'test', filename: ActiveStorage::Filename.new('me.png'), content_type: 'image/png')
    expect(stored.key).to match(%r{\Aavatars/\w{28}\z})
    expect(stored.download).to eq('png bytes')
    expect(blob(store(file, path: '/')).key).not_to include('/')
  end

  it 'stores on the service `disk` names, which must be as public as `public` says' do
    expect(blob(store(file, disk: 'test_public', public: true)).service_name).to eq('test_public')

    expect { store(file, public: true) }
      .to raise_error(Lighthouse::DefinitionError, /`avatar` stores on the ActiveStorage service `test`, which is not public/)
    expect { store(file, disk: 'test_public') }
      .to raise_error(Lighthouse::DefinitionError, /`test_public`, which is public: pass public: true/)
    expect(ActiveStorage::Blob.count).to eq(1)
  end

  it 'refuses a service config/storage.yml does not declare, and a value that is not a file' do
    expect { store(file, disk: 'nope') }
      .to raise_error(Lighthouse::DefinitionError, /@upload on `avatar`: Missing configuration for the nope Active Storage service/)
    expect { store('me.png') }
      .to raise_error(Lighthouse::DefinitionError, 'Expected argument `avatar` to be an uploaded file (Upload).')
  end
end
