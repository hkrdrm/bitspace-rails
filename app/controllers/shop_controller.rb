class ShopController < ApplicationController
  def index
    @products = Product.published.eager(:variants, options: :option_values).all
  end

  def show
    @product = Product.where(slug: params[:slug].to_s, active: true)
      .eager(options: :option_values, variants: :option_values)
      .all.first

    # A 404 rather than a redirect: an unpublished product should not announce
    # that it exists.
    raise ActionController::RoutingError, "Not Found" unless @product
  end
end
