# Starts a purchase: snapshots the cart lines into a pending order and opens
# a Stripe Checkout Session for it. Stock is checked by the caller but not
# held; OrderFulfiller flags the rare order that loses a race for the last unit.
class Checkout
  Result = Data.define(:url, :error, :order)
  UNAVAILABLE = "Checkout is unavailable right now, try again shortly.".freeze
  # Stripe refuses an expiry under 30 minutes away; exactly 30 races the clock.
  SESSION_LIFETIME = 31.minutes

  def initialize(lines:, fulfillment:, account:, success_url:, cancel_url:,
                 settings: StoreSetting.current, gateway: StripeGateway.current)
    @lines = lines
    @fulfillment = fulfillment
    @account = account
    @success_url = success_url
    @cancel_url = cancel_url
    @settings = settings
    @gateway = gateway
  end

  def start
    order = create_order
    session = @gateway.create_checkout_session(session_params(order))
    order.update(stripe_session_id: session.id)
    Result.new(url: session.url, error: nil, order: order)
  rescue StripeGateway::Error => e
    # Error, not warn: a failing tax rate or key stops every sale.
    Rails.logger.error("checkout failed for #{order&.number}: #{e.message}")
    order&.destroy
    Result.new(url: nil, error: UNAVAILABLE, order: nil)
  end

  private

  def create_order
    Order.db.transaction do
      order = Order.create(
        account_id: @account&.id, fulfillment: @fulfillment,
        subtotal_cents: subtotal, shipping_cents: shipping_cents,
        tax_rate_bps: (@settings.tax_rate_bps if tax_rate_id),
        total_cents: subtotal + shipping_cents
      )
      @lines.each do |line|
        OrderItem.create(
          order_id: order.id, variant_id: line.variant.id, product_name: line.product.name,
          variant_label: line.variant.label, sku: line.variant.sku,
          unit_price_cents: line.unit_price_cents, quantity: line.quantity
        )
      end
      order
    end
  end

  def session_params(order)
    params = {
      mode: "payment",
      payment_method_types: [ "card" ],
      line_items: @lines.map { |line| line_item(line) },
      metadata: { order_id: order.id.to_s },
      client_reference_id: order.number,
      expires_at: SESSION_LIFETIME.from_now.to_i,
      success_url: @success_url.call(order),
      cancel_url: @cancel_url
    }
    params[:customer_email] = @account.email if @account
    if shipping?
      params[:shipping_address_collection] = { allowed_countries: [ "US" ] }
      params[:shipping_options] = [ {
        shipping_rate_data: { type: "fixed_amount", display_name: "Flat rate shipping",
                              fixed_amount: { amount: shipping_cents, currency: "usd" } }
      } ]
    end
    params
  end

  # Shipping orders get the Mississippi rate as a dynamic rate, which Stripe
  # applies only to MS addresses; pickups happen in Mississippi, so always.
  # Tax applies to items only: manual rates cannot be attached to shipping.
  def line_item(line)
    item = { quantity: line.quantity,
             price_data: { currency: "usd", unit_amount: line.unit_price_cents, product_data: { name: line.name } } }
    item[shipping? ? :dynamic_tax_rates : :tax_rates] = [ tax_rate_id ] if tax_rate_id
    item
  end

  def subtotal
    @lines.sum(&:total_cents)
  end

  def shipping?
    @fulfillment == "shipping"
  end

  def shipping_cents
    shipping? ? @settings.shipping_cents : 0
  end

  def tax_rate_id
    @settings.checkout_tax_rate_id
  end
end
