require 'rails_helper'

# ApplicationCable::Connection, with ActionCable's connection test helpers.
RSpec.describe ApplicationCable::Connection do
  include ActionCable::Connection::TestCase::Behavior

  tests described_class

  let(:user) { create(:user) }

  it 'identifies the user by the token param, as the endpoint does by its bearer token' do
    connect params: { token: user.api_token }

    expect(connection.current_user).to eq(user)
  end

  it 'identifies the user by an Authorization header too' do
    connect headers: { 'Authorization' => "Bearer #{user.api_token}" }

    expect(connection.current_user).to eq(user)
  end

  it 'lets a guest in' do
    connect

    expect(connection.current_user).to be_nil
  end

  it 'refuses a token that matches nobody' do
    expect { connect params: { token: 'nope' } }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)
  end
end
