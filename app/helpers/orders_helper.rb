module OrdersHelper
  CUSTOMER_STATUS = {
    "paid" => "Paid — we're getting it ready", "printing" => "Printing",
    "ready_for_pickup" => "Ready for pickup in McComb", "shipped" => "Shipped",
    "completed" => "Completed", "cancelled" => "Cancelled", "refunded" => "Refunded"
  }.freeze

  def customer_status(order)
    CUSTOMER_STATUS.fetch(order.status, order.status_label)
  end

  def order_status_tone(status)
    case status
    when "paid", "ready_for_pickup", "shipped", "completed" then :green
    when "printing" then :orange
    else :gray
    end
  end

  # [label, cents] rows for an order's totals. Shipping shows for shipping
  # orders even when free; tax and refunds only when there are any.
  def order_total_rows(order)
    rows = [ [ "Subtotal", order.subtotal_cents ] ]
    rows << [ "Shipping", order.shipping_cents ] if order.shipping?
    rows << [ "Tax", order.tax_cents ] if order.tax_cents.positive?
    rows << [ "Total", order.total_cents ]
    rows << [ "Refunded", -order.refunded_cents ] if order.refunded_cents.positive?
    rows
  end
end
