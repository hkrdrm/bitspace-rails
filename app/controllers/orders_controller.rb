# The page a buyer lands on after paying, and the link their dashboard uses.
# Anyone holding the token can see it, because guests have no account to sign
# in to.
class OrdersController < ApplicationController
  MAX_TRIES = 10

  def show
    @order = Order.first(token: params[:token].to_s)
    raise ActionController::RoutingError, "Not Found" unless @order

    confirm_payment if @order.pending?
    clear_cart_after_checkout
    @tries = params[:tries].to_i.clamp(0, MAX_TRIES)
    @settings = StoreSetting.current
  end

  private

  # The webhook usually lands first. When it has not, ask Stripe directly so
  # the buyer sees a confirmed order without waiting.
  def confirm_payment
    return if @order.stripe_session_id.blank?

    OrderFulfiller.new(@order, StripeGateway.current.retrieve_session(@order.stripe_session_id)).call
  rescue StripeGateway::Error => e
    Rails.logger.warn("could not confirm #{@order.number}: #{e.message}")
  end

  # Only for the order this browser just checked out: opening an old order
  # from the dashboard must not empty the cart.
  def clear_cart_after_checkout
    return unless session[:checkout_order_id] == @order.id && !@order.pending?

    Cart.new(session).clear
    session.delete(:checkout_order_id)
  end
end
