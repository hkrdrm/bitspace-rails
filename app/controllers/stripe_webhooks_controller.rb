# Stripe's calls back to the shop. Stripe is not a browser and sends no CSRF
# token or session, so this skips ApplicationController entirely; the
# signature check is the authentication. Anything that raises while handling
# an event returns 500, and Stripe retries the delivery.
class StripeWebhooksController < ActionController::API
  def create
    event = StripeGateway.current.construct_event(request.raw_post, request.headers["Stripe-Signature"])
    handle(event.type, event.data.object.to_hash.deep_symbolize_keys)
    head :ok
  rescue StripeGateway::InvalidSignature
    head :bad_request
  end

  private

  def handle(type, object)
    case type
    # A delayed method (a bank debit) completes the session unpaid, which the
    # fulfiller ignores, and settles later with async_payment_succeeded.
    when "checkout.session.completed", "checkout.session.async_payment_succeeded"
      order = order_for(object)
      OrderFulfiller.new(order, object).call if order
    when "checkout.session.async_payment_failed"
      order = order_for(object)
      order.update(status: "cancelled") if order&.pending?
    when "checkout.session.expired"
      order = order_for(object)
      order.destroy if order&.pending?
    when "charge.refunded"
      # A blank intent would match every order without one (IS NULL).
      return if object[:payment_intent].blank?

      Order.first(stripe_payment_intent_id: object[:payment_intent].to_s)
        &.record_refund(amount_refunded: object[:amount_refunded].to_i, amount: object[:amount].to_i)
    end
  end

  # Both the metadata id and the session id must match, so a session can
  # only ever settle the order it was created for.
  def order_for(session)
    id = session.dig(:metadata, :order_id).to_s
    return nil unless id.match?(/\A\d+\z/)

    Order.first(id: id.to_i, stripe_session_id: session[:id].to_s)
  end
end
