class CartsController < ApplicationController
  def show
    cart = Cart.new(session)
    @lines = cart.lines
    @subtotal = cart.subtotal_cents(@lines)
    @settings = StoreSetting.current
  end
end
