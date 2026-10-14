require "test_helper"

class DashboardOrdersTest < ActionDispatch::IntegrationTest
  teardown { Order.dataset.delete }

  setup do
    @account = create_account
    sign_in @account
  end

  test "the orders page lists only this account's placed orders, each linking to its page" do
    mine = build_order(account: @account, status: "shipped")
    pending = build_order(account: @account, status: "pending")
    theirs = build_order(account: create_account, status: "paid")

    get "/dashboard/orders"
    assert_response :success
    assert_select "a[href='/orders/#{mine.token}']", text: "View"
    assert_select "tbody", text: /#{mine.number}.*Shipped/m
    refute_selector_text "tbody", /#{pending.number}/
    refute_selector_text "tbody", /#{theirs.number}/
  end

  test "with no orders the page says so and links to the shop" do
    get "/dashboard/orders"
    assert_select "body", text: /No orders yet\./
  end

  test "the dashboard shows the three most recent orders" do
    orders = 4.times.map { build_order(account: @account) }

    get "/dashboard"
    numbers = css_select("tbody tr td:first-child").map { |td| td.text.strip }
    assert_equal orders.last(3).reverse.map(&:number), numbers
  end

  test "the placeholder orders and the checkout tab are gone" do
    get "/dashboard"
    refute_selector_text "body", /#1041|#1042/
    assert_select "a[href='/dashboard/checkout']", count: 0
  end
end
