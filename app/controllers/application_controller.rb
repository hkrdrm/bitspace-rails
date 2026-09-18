class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private
  def current_session
    User::Session.find
  end

  def current_user
    @current_user ||= current_session.record
  end

  def current_account
    rodauth.rails_account
  end

  def authenticate
    rodauth.require_account
  end

  helper_method :current_account
end
