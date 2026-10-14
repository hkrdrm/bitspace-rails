require "test_helper"

class OrderPageTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  def stripe
    StripeGateway.current
  end

  test "a paid order shows its number, items, totals and status in words" do
    order = build_order(status: "paid", items: [ { name: "Page Tee", label: "Black / M", price: 1500, quantity: 2 } ])

    get "/orders/#{order.token}"
    assert_response :success
    assert_select "h1", text: /#{order.number}/
    assert_select "[data-order-items]", text: /Page Tee — Black \/ M/
    assert_select "[data-order-totals]", text: /Total\s*\$30\.00/
    assert_select "[data-order-status]", text: /Paid — we're getting it ready/
    assert_select "[data-order-status]", text: /Bookmark this page to check on your order\./
  end

  test "an unknown token is a 404" do
    get "/orders/not-a-real-token"
    assert_response :not_found
  end

  test "a pickup order shows the pickup instructions, a shipped one its tracking" do
    StoreSetting.current.update(pickup_instructions: "Come by the shop on Main.")
    pickup = build_order(status: "ready_for_pickup", fulfillment: "pickup")
    get "/orders/#{pickup.token}"
    assert_select "[data-order-status]", text: /Ready for pickup in McComb/
    assert_select "[data-delivery]", text: /Come by the shop on Main\./

    shipped = build_order(status: "shipped", fulfillment: "shipping", tracking_number: "1Z999",
                          ship_name: "Pat Buyer", ship_address: { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }.to_json)
    get "/orders/#{shipped.token}"
    assert_select "[data-order-status]", text: /Tracking: 1Z999/
    assert_select "[data-delivery]", text: /1 Main St/
  end

  test "when the webhook is late, the page asks Stripe and confirms the order itself" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_late")
    stripe.stub_session("cs_test_late", **paid_session(order).except(:id))

    get "/orders/#{order.token}"
    assert_equal "paid", order.refresh.status
    assert_select "[data-order-status]", text: /Paid — we're getting it ready/
    assert_select "meta[http-equiv=refresh]", count: 0
  end

  test "an unpaid session shows the confirming message and refreshes" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_unpaid")
    stripe.stub_session("cs_test_unpaid", payment_status: "unpaid")

    get "/orders/#{order.token}"
    assert_select "[data-order-status]", text: /Payment received, confirming your order…/
    assert_select "meta[http-equiv=refresh][content=?]", "3;url=/orders/#{order.token}?tries=1"
  end

  test "after ten tries the page stops refreshing and says to check back" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_slow")
    stripe.stub_session("cs_test_slow", payment_status: "unpaid")

    get "/orders/#{order.token}", params: { tries: 10 }
    assert_select "[data-order-status]", text: /We're still confirming your payment\. Check back in a minute\./
    assert_select "meta[http-equiv=refresh]", count: 0
  end

  test "a Stripe error while confirming still shows the page" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_missing")

    get "/orders/#{order.token}"
    assert_response :success
    assert_select "[data-order-status]", text: /Payment received, confirming your order…/
  end

  test "returning from Stripe with a paid order empties the cart" do
    tee = build_product(name: "Flow Tee", price: "10.00")
    post "/cart/items", params: { variant_id: tee.variants.first.id, quantity: 1 }
    post "/checkout", params: { fulfillment: "pickup" }
    order = Order.order(:id).last
    stripe.stub_session(order.stripe_session_id, **paid_session(order).except(:id))

    get "/orders/#{order.token}"
    assert_select "nav a[href='/cart']", text: "Cart (0)"
    assert_nil session[:checkout_order_id]
  end

  test "viewing an older order leaves the current cart alone" do
    tee = build_product(name: "Keep Tee", price: "10.00")
    post "/cart/items", params: { variant_id: tee.variants.first.id, quantity: 2 }
    old = build_order(status: "completed")

    get "/orders/#{old.token}"
    assert_select "nav a[href='/cart']", text: "Cart (2)"
  end
end
