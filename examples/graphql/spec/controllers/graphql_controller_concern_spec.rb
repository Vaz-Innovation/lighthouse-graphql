require 'rails_helper'

RSpec.describe 'GraphQL controller concern', type: :controller do
  describe 'hooks' do
    controller(ApplicationController) do
      include Lighthouse::GraphQL::Controller

      lighthouse_schema { AppSchema }

      def custom
        lighthouse_request do
          lighthouse_request { render json: { ok: true } }
        end
      end

      private

      def graphql_context = { current_user: User.find_by!(name: 'Hooked') }
    end

    before do
      routes.draw do
        post 'execute' => 'anonymous#execute'
        post 'custom' => 'anonymous#custom'
      end
    end

    after { Lighthouse::Events.reset! }

    it 'resolves the schema from a block and the context from graphql_context' do
      create(:user, name: 'Hooked')

      post :execute, params: { query: '{ me { name } }' }

      expect(response.parsed_body.dig('data', 'me', 'name')).to eq('Hooked')
    end

    it 'gives an action of its own the request events, once however it nests lighthouse_request' do
      seen = []
      Lighthouse::Events.listen(Lighthouse::Events::StartRequest) { (seen << :start) && nil }
      Lighthouse::Events.listen(Lighthouse::Events::EndRequest) { (seen << :end) && nil }

      post :custom

      expect(seen).to eq(%i[start end])
      expect(response.parsed_body).to eq('ok' => true)
    end

    it 'does not route the hooks as actions' do
      expect(controller.class.action_methods).to include('execute', 'custom')
      expect(controller.class.action_methods).not_to include('graphql_context', 'graphql_schema', 'lighthouse_request')
    end
  end

  describe 'without a schema' do
    controller(ApplicationController) do
      include Lighthouse::GraphQL::Controller
    end

    before { routes.draw { post 'execute' => 'anonymous#execute' } }

    it 'says the schema is missing' do
      expect { post :execute, params: { query: '{ a }' } }.to raise_error(Lighthouse::DefinitionError, /lighthouse_schema/)
    end
  end
end
