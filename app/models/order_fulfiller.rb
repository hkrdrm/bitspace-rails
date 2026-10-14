# Turns a paid Stripe Checkout Session into a paid order: copies what Stripe
# collected, takes the stock, and flags the order when there was not enough.
# Safe to call any number of times: only the first call on a pending order
# changes anything. The webhook and the success page both call it, and
# whichever arrives first does the work.
class OrderFulfiller
  def initialize(order, session)
    @order = order
    @session = session.to_hash.deep_symbolize_keys
  end

  # True when this call marked the order paid.
  def call
    return false unless @session[:payment_status] == "paid"

    fulfilled = Order.db.transaction do
      order = Order.where(id: @order.id).for_update.first
      next false unless order&.pending?

      order.update(paid_fields(order))
      short = order.items.map { |item| take_stock(item) }.include?(false)
      order.update(oversold: true) if short
      true
    end
    @order.refresh if fulfilled
    fulfilled
  end

  private

  def paid_fields(order)
    shipping = @session.dig(:collected_information, :shipping_details) || @session[:shipping_details]
    {
      status: "paid",
      email: @session.dig(:customer_details, :email),
      ship_name: shipping&.dig(:name),
      ship_address: shipping&.dig(:address)&.to_json,
      tax_cents: @session.dig(:total_details, :amount_tax).to_i,
      shipping_cents: @session.dig(:total_details, :amount_shipping).to_i,
      total_cents: @session[:amount_total] || order.total_cents,
      stripe_payment_intent_id: @session[:payment_intent],
      paid_at: Time.current
    }
  end

  # Takes the item's quantity from its variant, never below zero. False when
  # there was not enough to cover it or the variant no longer exists.
  def take_stock(item)
    variant = item.variant_id && ProductVariant.where(id: item.variant_id).for_update.first
    return false unless variant

    enough = variant.stock >= item.quantity
    variant.this.update(stock: [ variant.stock - item.quantity, 0 ].max)
    enough
  end
end
