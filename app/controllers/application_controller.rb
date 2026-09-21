class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :current_account

  private

  def current_account
    rodauth.rails_account
  end

  def authenticate
    rodauth.require_account
  end

  # A 404 rather than a 403: an admin area that answers "forbidden" tells a
  # prober it exists.
  def require_superuser
    authenticate
    raise ActionController::RoutingError, "Not Found" unless current_account&.superuser?
  end
end
