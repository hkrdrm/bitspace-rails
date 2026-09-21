module Admin
  class BaseController < ApplicationController
    before_action :require_superuser
  end
end
