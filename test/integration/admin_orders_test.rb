require "test_helper"

class AdminOrdersTest < ActionDispatch::IntegrationTest
  teardown { Order.dataset.delete }

  setup { sign_in create_account(superuser: true) }

  def rows
    css_select("table tbody tr")
  end

  def row_for(order)
    rows.find { |row| row.text.include?(order.number) }
  end

  test "paid orders are listed with their details and pending ones are not" do
    paid = build_order(status: "paid", fulfillment: "shipping", email: "pat@example.test")
    pending = build_order(status: "pending")

    get "/admin/orders"
    assert_response :success
    row = row_for(paid)
    assert row, "expected #{paid.number} in the list"
    [ "pat@example.test", "Ship", "$12.00", "Paid" ].each { |text| assert_includes row.text, text }
    assert_nil row_for(pending)
  end

  test "oversold and partially refunded orders say so" do
    oversold = build_order(oversold: true)
    refunded = build_order(status: "shipped", refunded_cents: 500)

    get "/admin/orders"
    assert_includes row_for(oversold).text, "Oversold"
    assert_includes row_for(refunded).text, "Partially refunded $5.00"
  end

  test "search matches an order number or email, and a percent sign is literal" do
    findme = build_order(email: "findme@example.test")
    other = build_order(email: "other@example.test")

    get "/admin/orders", params: { q: "FINDME" }
    assert row_for(findme)
    assert_nil row_for(other)

    get "/admin/orders", params: { q: other.number.downcase }
    assert row_for(other)
    assert_nil row_for(findme)

    get "/admin/orders", params: { q: "%" }
    assert_equal 0, rows.size
  end

  test "filters narrow the list and mark themselves current" do
    printing = build_order(status: "printing", fulfillment: "pickup")
    done = build_order(status: "completed", fulfillment: "shipping")
    oversold = build_order(status: "completed", oversold: true)

    get "/admin/orders", params: { filter: "needs_action" }
    assert row_for(printing)
    assert_nil row_for(done)
    assert_select "a[aria-current='page']", text: "Needs action"

    get "/admin/orders", params: { filter: "shipping" }
    assert row_for(done)
    assert_nil row_for(printing)

    get "/admin/orders", params: { filter: "oversold" }
    assert row_for(oversold)
    assert_nil row_for(done)

    get "/admin/orders", params: { filter: "banana" }
    assert_select "a[aria-current='page']", text: "All"
  end

  test "the order page shows items, totals, address and the Stripe payment" do
    order = build_order(status: "paid", fulfillment: "shipping", stripe_payment_intent_id: "pi_abc",
                        ship_name: "Pat Buyer", ship_address: { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }.to_json,
                        items: [ { name: "Admin Tee", label: "Black / L", price: 1500, quantity: 2, sku: "AT-BL-L" } ])

    get "/admin/orders/#{order.number}"
    assert_response :success
    assert_select "[data-order-items]", text: /Admin Tee — Black \/ L/
    assert_select "[data-order-items]", text: /AT-BL-L/
    assert_select "[data-order-totals]", text: /\$30\.00/
    assert_select "body", text: /1 Main St/
    assert_select "a[href='https://dashboard.stripe.com/payments/pi_abc']"
  end

  test "pending and unknown orders are not found" do
    pending = build_order(status: "pending")

    get "/admin/orders/#{pending.number}"
    assert_response :not_found
    get "/admin/orders/BS-0"
    assert_response :not_found
  end

  test "the owner sets the status and tracking number" do
    order = build_order(status: "paid", fulfillment: "shipping")

    patch "/admin/orders/#{order.number}", params: { status: "shipped", tracking_number: " 1Z999 " }
    assert_redirected_to "/admin/orders/#{order.number}"
    follow_redirect!
    assert_select "[data-flash=notice]", text: "Order updated."
    order.refresh
    assert_equal [ "shipped", "1Z999" ], [ order.status, order.tracking_number ]
  end

  test "the status list offers every step after payment, in any order" do
    order = build_order(status: "completed")

    get "/admin/orders/#{order.number}"
    options = css_select("select[name=status] option").map { |option| option["value"] }
    assert_equal Order::ADMIN_STATUSES, options

    patch "/admin/orders/#{order.number}", params: { status: "printing" }
    assert_equal "printing", order.refresh.status
  end

  test "an unknown status, or pending, is refused" do
    order = build_order(status: "paid")

    [ "pending", "lost" ].each do |status|
      patch "/admin/orders/#{order.number}", params: { status: status }
      assert_response :unprocessable_entity
      assert_select "[data-order-error]", text: "Choose a status from the list."
    end
    assert_equal "paid", order.refresh.status
  end

  test "the placeholder orders are gone" do
    get "/admin/orders"
    refute_selector_text "body", /queen\.com/
  end

  test "non-superusers cannot reach orders" do
    order = build_order
    sign_in create_account(superuser: false)

    get "/admin/orders/#{order.number}"
    assert_response :not_found
  end
end
