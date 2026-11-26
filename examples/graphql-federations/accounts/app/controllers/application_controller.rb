class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  private

  # The user whose API token the request carries (`Authorization: Bearer <token>`),
  # which the router passes on to every subgraph (router/router.yaml).
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = authenticate_with_http_token { |token, _options| User.find_by(api_token: token) }
  end
end
