class ShopController < ApplicationController
  def index
    @products = Product.published.all
  end

  def show
    @product = Product.first(slug: params[:slug], active: true)

    # A 404 rather than a redirect: an unpublished product should not announce
    # that it exists.
    raise ActionController::RoutingError, "Not Found" unless @product
  end
end
