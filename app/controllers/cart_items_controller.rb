class CartItemsController < ApplicationController
  def create
    result = cart.add(params[:variant_id], params.fetch(:quantity, 1))
    if result.ok
      redirect_to cart_path, notice: result.message
    else
      redirect_back_or_to shop_path, alert: result.message
    end
  end

  def update
    result = cart.update(params[:variant_id], params[:quantity])
    redirect_to cart_path, flash: { (result.ok ? :notice : :alert) => result.message }
  end

  def destroy
    redirect_to cart_path, notice: cart.remove(params[:variant_id]).message
  end

  private

  def cart
    @cart ||= Cart.new(session)
  end
end
