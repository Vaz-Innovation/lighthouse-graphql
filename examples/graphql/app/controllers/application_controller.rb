class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  private

  # `Authorization: Bearer <api_token>`; nil for guests.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = authenticate_with_http_token { |token, _options| User.find_by(api_token: token) }
  end
end
