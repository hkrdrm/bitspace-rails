require "test_helper"

class OrderFulfillerTest < ActiveSupport::TestCase
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  setup do
    @tee = build_product(name: "Paid Tee", options: { "Size" => %w[S M] }, stock: 5)
    @small = variant_named(@tee, "S")
    @order = build_order(status: "pending", fulfillment: "shipping", stripe_session_id: "cs_test_paid",
                         items: [ { name: "Paid Tee", label: "S", price: 1200, quantity: 2, variant_id: @small.id } ])
  end

  test "a paid session marks the order paid and copies what Stripe collected" do
    address = { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }
    session = paid_session(@order, email: "pat@example.test", tax: 168, shipping: 800, address: address, payment_intent: "pi_123")

    assert OrderFulfiller.new(@order, session).call
    assert_equal "paid", @order.status
    assert_equal "pat@example.test", @order.email
    assert_equal "Pat Buyer", @order.ship_name
    assert_equal [ "1 Main St", "McComb, MS 39648", "US" ], @order.address_lines
    assert_equal [ 168, 800, 2400 + 800 + 168 ], [ @order.tax_cents, @order.shipping_cents, @order.total_cents ]
    assert_equal "pi_123", @order.stripe_payment_intent_id
    assert @order.paid_at
  end

  test "payment takes the stock" do
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal 3, @small.refresh.stock
    refute @order.oversold?
  end

  test "a second call changes nothing" do
    OrderFulfiller.new(@order, paid_session(@order)).call
    refute OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal 3, @small.refresh.stock
  end

  test "not enough stock still takes the order, floors stock at zero and flags it" do
    @small.this.update(stock: 1)
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal "paid", @order.status
    assert_equal 0, @small.refresh.stock
    assert @order.oversold?
  end

  test "a variant deleted since checkout flags the order" do
    Product.where(id: @tee.id).delete
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal "paid", @order.status
    assert @order.oversold?
  end

  test "an unpaid session changes nothing" do
    session = paid_session(@order).merge(payment_status: "unpaid")

    refute OrderFulfiller.new(@order, session).call
    assert_equal "pending", @order.refresh.status
    assert_equal 5, @small.refresh.stock
  end

  test "an order that is no longer pending is left alone" do
    @order.update(status: "cancelled")

    refute OrderFulfiller.new(@order, paid_session(@order)).call
    assert_equal "cancelled", @order.refresh.status
    assert_equal 5, @small.refresh.stock
  end

  test "a Stripe session object works as well as a hash" do
    session = Stripe::Checkout::Session.construct_from(paid_session(@order))

    assert OrderFulfiller.new(@order, session).call
    assert_equal "paid", @order.status
  end
end
