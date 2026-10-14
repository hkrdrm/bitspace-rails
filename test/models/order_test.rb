require "test_helper"

class OrderTest < ActiveSupport::TestCase
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  test "a new order gets a public number from its id and a long random token" do
    order = build_order
    assert_equal "BS-#{order.id + 1000}", order.number
    assert_operator order.token.length, :>=, 32
    refute_equal order.token, build_order.token
  end

  test "an order starts pending" do
    order = Order.create(fulfillment: "pickup", subtotal_cents: 100, total_cents: 100)
    assert_equal "pending", order.status
    assert_equal 0, order.refunded_cents
  end

  test "unknown statuses and fulfillments are rejected" do
    refute Order.new(fulfillment: "pickup", status: "lost", subtotal_cents: 1, total_cents: 1).valid?
    refute Order.new(fulfillment: "drone", subtotal_cents: 1, total_cents: 1).valid?
  end

  test "placed leaves out pending orders" do
    paid = build_order(status: "paid")
    pending = build_order(status: "pending")

    ids = Order.placed.select_map(:id)
    assert_includes ids, paid.id
    refute_includes ids, pending.id
  end

  test "item count adds up quantities" do
    order = build_order(items: [
      { name: "A", label: "S", price: 1000, quantity: 2 },
      { name: "B", label: "B", price: 500, quantity: 3 }
    ])
    assert_equal 5, order.item_count
    assert_equal 3500, order.subtotal_cents
  end

  test "a full refund marks the order refunded and a partial one keeps its status" do
    full = build_order(status: "shipped")
    full.record_refund(amount_refunded: full.total_cents, amount: full.total_cents)
    assert_equal "refunded", full.refresh.status

    partial = build_order(status: "shipped")
    partial.record_refund(amount_refunded: 300, amount: partial.total_cents)
    partial.refresh
    assert_equal "shipped", partial.status
    assert_equal 300, partial.refunded_cents
    assert partial.partially_refunded?
  end

  test "address lines come from Stripe's address hash" do
    address = { line1: "1 Main St", line2: nil, city: "McComb", state: "MS", postal_code: "39648", country: "US" }
    order = build_order(fulfillment: "shipping", ship_address: address.to_json)
    assert_equal [ "1 Main St", "McComb, MS 39648", "US" ], order.address_lines
    assert_equal [], build_order.address_lines
  end

  test "deleting a product keeps its order lines, unlinked" do
    product = build_product(name: "Gone Tee")
    order = build_order(items: [ { name: "Gone Tee", label: "Gone Tee", price: 1200, quantity: 1, variant_id: product.variants.first.id } ])

    Product.where(id: product.id).delete
    item = order.refresh.items.first
    assert_nil item.variant_id
    assert_equal "Gone Tee", item.product_name
  end
end
