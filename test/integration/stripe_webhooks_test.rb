require "test_helper"

class StripeWebhooksTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  setup do
    @tee = build_product(name: "Hook Tee", options: { "Size" => %w[S M] }, stock: 5)
    @small = variant_named(@tee, "S")
    @order = build_order(status: "pending", stripe_session_id: "cs_test_hook",
                         items: [ { name: "Hook Tee", label: "S", price: 1200, quantity: 2, variant_id: @small.id } ])
  end

  def deliver(type, object, signature: nil)
    payload = { id: "evt_#{SecureRandom.hex(4)}", object: "event", type: type, data: { object: object } }.to_json
    post "/stripe/webhooks", params: payload, headers: {
      "Content-Type" => "application/json",
      "User-Agent" => "Stripe/1.0 (+https://stripe.com/docs/webhooks)",
      "Stripe-Signature" => signature || stripe_signature(payload)
    }
  end

  def charge(payment_intent:, amount:, amount_refunded:)
    { id: "ch_1", object: "charge", payment_intent: payment_intent, amount: amount, amount_refunded: amount_refunded }
  end

  test "a completed session marks the order paid and takes stock" do
    deliver("checkout.session.completed", paid_session(@order))

    assert_response :ok
    assert_equal "paid", @order.refresh.status
    assert_equal 3, @small.refresh.stock
  end

  test "a repeated delivery takes stock once" do
    session = paid_session(@order)
    2.times { deliver("checkout.session.completed", session) }

    assert_response :ok
    assert_equal 3, @small.refresh.stock
  end

  # Bank debits and similar methods finish the session unpaid and settle days
  # later with a separate event.
  test "a delayed payment that settles later marks the order paid then" do
    deliver("checkout.session.completed", paid_session(@order).merge(payment_status: "unpaid"))
    assert_equal "pending", @order.refresh.status

    deliver("checkout.session.async_payment_succeeded", paid_session(@order))
    assert_response :ok
    assert_equal "paid", @order.refresh.status
    assert_equal 3, @small.refresh.stock
  end

  test "a delayed payment that fails cancels the order without taking stock" do
    deliver("checkout.session.async_payment_failed", paid_session(@order).merge(payment_status: "unpaid"))

    assert_response :ok
    assert_equal "cancelled", @order.refresh.status
    assert_equal 5, @small.refresh.stock
  end

  test "a session whose id does not match the order's is ignored" do
    deliver("checkout.session.completed", paid_session(@order).merge(id: "cs_test_other"))

    assert_response :ok
    assert_equal "pending", @order.refresh.status
  end

  test "an expired session deletes the pending order, but never a paid one" do
    deliver("checkout.session.expired", { id: "cs_test_hook", object: "checkout.session", metadata: { order_id: @order.id.to_s } })
    assert_response :ok
    assert_nil Order[@order.id]

    paid = build_order(status: "paid", stripe_session_id: "cs_test_paid_already")
    deliver("checkout.session.expired", { id: "cs_test_paid_already", object: "checkout.session", metadata: { order_id: paid.id.to_s } })
    assert Order[paid.id]
  end

  test "a full refund marks the order refunded and leaves stock alone" do
    @order.update(status: "shipped", stripe_payment_intent_id: "pi_full")
    deliver("charge.refunded", charge(payment_intent: "pi_full", amount: @order.total_cents, amount_refunded: @order.total_cents))

    assert_response :ok
    @order.refresh
    assert_equal "refunded", @order.status
    assert_equal @order.total_cents, @order.refunded_cents
    assert_equal 5, @small.refresh.stock
  end

  test "a partial refund records the amount and keeps the status" do
    @order.update(status: "shipped", stripe_payment_intent_id: "pi_part")
    deliver("charge.refunded", charge(payment_intent: "pi_part", amount: @order.total_cents, amount_refunded: 500))

    @order.refresh
    assert_equal "shipped", @order.status
    assert_equal 500, @order.refunded_cents
  end

  test "a refund with no payment intent changes nothing" do
    deliver("charge.refunded", charge(payment_intent: nil, amount: 2400, amount_refunded: 2400))

    assert_response :ok
    @order.refresh
    assert_equal "pending", @order.status
    assert_equal 0, @order.refunded_cents
  end

  test "a bad or missing signature is refused" do
    deliver("checkout.session.completed", paid_session(@order), signature: "t=1,v1=nope")
    assert_response :bad_request

    post "/stripe/webhooks", params: "{}", headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    assert_equal "pending", @order.refresh.status
  end

  test "events the shop does not handle are acknowledged" do
    deliver("customer.created", { id: "cus_1", object: "customer" })
    assert_response :ok
  end

  test "the endpoint needs no CSRF token, because Stripe never has one" do
    ActionController::Base.allow_forgery_protection = true
    deliver("customer.created", { id: "cus_1", object: "customer" })
    assert_response :ok
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
