require "test_helper"

class CheckoutTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  setup do
    @tee = build_product(name: "Check Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    StoreSetting.current.update(shipping_cents: 800)
  end

  def stripe
    StripeGateway.current
  end

  def add(variant, quantity = 1)
    post "/cart/items", params: { variant_id: variant.id, quantity: quantity }
  end

  def checkout(fulfillment)
    post "/checkout", params: { fulfillment: fulfillment }
  end

  def tax_on
    StoreSetting.current.update(tax_enabled: true, tax_rate_bps: 700, stripe_tax_rate_id: "txr_ms", stripe_tax_rate_bps: 700)
  end

  test "a pickup checkout saves a pending order and sends the buyer to Stripe" do
    add(@small, 2)
    checkout("pickup")

    order = Order.order(:id).last
    assert_response :see_other
    assert_equal "https://checkout.stripe.test/#{order.stripe_session_id}", response.location

    assert_equal [ "pending", "pickup", 4000, 0, 4000 ],
      [ order.status, order.fulfillment, order.subtotal_cents, order.shipping_cents, order.total_cents ]
    item = order.items.first
    assert_equal [ "Check Tee", "S", 2000, 2, @small.id ],
      [ item.product_name, item.variant_label, item.unit_price_cents, item.quantity, item.variant_id ]
  end

  test "the pickup session asks Stripe for the right things" do
    add(@small, 2)
    checkout("pickup")
    order = Order.order(:id).last
    params = stripe.sessions_created.last

    assert_equal "payment", params[:mode]
    # API 2026-09-30 rejects payment_method_types; methods are set in the Stripe Dashboard.
    refute params.key?(:payment_method_types)
    assert_equal [ { quantity: 2, price_data: { currency: "usd", unit_amount: 2000, product_data: { name: "Check Tee — S" } } } ],
      params[:line_items]
    assert_equal({ order_id: order.id.to_s }, params[:metadata])
    assert_equal order.number, params[:client_reference_id]
    assert_equal "http://www.example.com/orders/#{order.token}", params[:success_url]
    assert_equal "http://www.example.com/cart", params[:cancel_url]
    assert_in_delta 31.minutes.from_now.to_i, params[:expires_at], 60
    refute params.key?(:shipping_address_collection)
    refute params.key?(:shipping_options)
    refute params.key?(:customer_email)
  end

  test "a shipping checkout collects a US address and charges the flat rate" do
    add(@small)
    checkout("shipping")
    order = Order.order(:id).last
    params = stripe.sessions_created.last

    assert_equal({ allowed_countries: [ "US" ] }, params[:shipping_address_collection])
    assert_equal [ { shipping_rate_data: { type: "fixed_amount", display_name: "Flat rate shipping",
                                            fixed_amount: { amount: 800, currency: "usd" } } } ],
      params[:shipping_options]
    assert_equal [ 800, 2800 ], [ order.shipping_cents, order.total_cents ]
  end

  test "with tax on, shipping orders use a dynamic rate and pickups a fixed one" do
    tax_on
    add(@small)

    checkout("shipping")
    shipping_line = stripe.sessions_created.last[:line_items].first
    assert_equal [ "txr_ms" ], shipping_line[:dynamic_tax_rates]
    refute shipping_line.key?(:tax_rates)
    assert_equal 700, Order.order(:id).last.tax_rate_bps

    checkout("pickup")
    pickup_line = stripe.sessions_created.last[:line_items].first
    assert_equal [ "txr_ms" ], pickup_line[:tax_rates]
    refute pickup_line.key?(:dynamic_tax_rates)
  end

  test "with tax off, no tax rate is sent even if one is stored" do
    StoreSetting.current.update(tax_enabled: false, tax_rate_bps: 700, stripe_tax_rate_id: "txr_ms", stripe_tax_rate_bps: 700)
    add(@small)
    checkout("pickup")

    line = stripe.sessions_created.last[:line_items].first
    refute line.key?(:tax_rates)
    refute line.key?(:dynamic_tax_rates)
    assert_nil Order.order(:id).last.tax_rate_bps
  end

  test "a signed in buyer's email is filled in and the order is theirs" do
    account = create_account
    sign_in account
    add(@small)
    checkout("pickup")

    assert_equal account.email, stripe.sessions_created.last[:customer_email]
    assert_equal account.id, Order.order(:id).last.account_id
  end

  test "an empty cart or an unknown delivery choice makes no order" do
    assert_no_difference -> { Order.count } do
      checkout("pickup")
      assert_redirected_to "/cart"
      assert_equal "Your cart is empty.", flash[:alert]

      add(@small)
      checkout("drone")
      assert_redirected_to "/cart"
      assert_equal "Choose pickup or shipping.", flash[:alert]
    end
    assert_empty stripe.sessions_created
  end

  test "stock that ran out since the cart was filled sends the buyer back with the cart fixed" do
    add(@small, 3)
    @small.this.update(stock: 1)

    assert_no_difference -> { Order.count } do
      checkout("pickup")
    end
    assert_redirected_to "/cart"
    assert_equal "Only 1 of Check Tee — S left, so your cart now has 1.", flash[:alert]
    assert_equal({ @small.id.to_s => 1 }, session[:cart])
  end

  test "a sold out line is left out and the rest is checked out" do
    sticker = build_product(name: "Check Sticker", price: "4.00")
    add(@small)
    add(sticker.variants.first)
    sticker.variants.first.this.update(stock: 0)

    checkout("pickup")
    assert_equal [ "Check Tee" ], Order.order(:id).last.items.map(&:product_name)
  end

  test "when Stripe fails, no order is left behind and the buyer is told" do
    stripe.fail_with = "Stripe is down"
    add(@small)

    assert_no_difference -> { Order.count } do
      checkout("pickup")
    end
    assert_redirected_to "/cart"
    assert_equal "Checkout is unavailable right now, try again shortly.", flash[:alert]
  end

  test "the session remembers which order this browser checked out" do
    add(@small)
    checkout("pickup")
    assert_equal Order.order(:id).last.id, session[:checkout_order_id]
  end
end
