class CheckoutsController < ApplicationController
  def create
    cart = Cart.new(session)
    lines = cart.available_lines
    fulfillment = params[:fulfillment].to_s

    return redirect_to(cart_path, alert: "Your cart is empty.") if lines.empty?
    return redirect_to(cart_path, alert: "Choose pickup or shipping.") unless Order::FULFILLMENTS.include?(fulfillment)

    changes = cart.reconcile(lines)
    return redirect_to(cart_path, alert: changes.join(" ")) if changes.any?

    result = Checkout.new(
      lines: lines, fulfillment: fulfillment, account: current_account,
      success_url: ->(order) { order_url(order.token) }, cancel_url: cart_url
    ).start
    return redirect_to(cart_path, alert: result.error) if result.error

    # The success page clears the cart only for this order (see OrdersController).
    session[:checkout_order_id] = result.order.id
    redirect_to result.url, allow_other_host: true, status: :see_other
  end
end
