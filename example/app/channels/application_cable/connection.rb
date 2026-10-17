# Identifies the socket by the same API token GraphqlController reads from
# `Authorization: Bearer <token>`. A browser WebSocket cannot set headers, so
# the token also comes as `?token=<token>`. No token is a guest, as on the
# endpoint; a token that matches nobody is refused.
class ApplicationCable::Connection < ActionCable::Connection::Base
  identified_by :current_user

  def connect
    token = request.params[:token].presence || bearer_token
    self.current_user = User.find_by(api_token: token) if token
    reject_unauthorized_connection if token && current_user.nil?
  end

  private

  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/, 1]
  end
end
