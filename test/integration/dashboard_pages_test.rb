require "test_helper"

class DashboardPagesTest < ActionDispatch::IntegrationTest
  setup { sign_in create_account }

  test "orders page renders an order history table" do
    get "/dashboard/orders"
    assert_response :success
    assert_select "h1 span", text: "YOUR"
    assert_select "table thead th", text: "Order"
  end

  test "checkout page renders all three sections" do
    get "/dashboard/checkout"
    assert_response :success
    assert_select "h2", text: "ORDER SUMMARY"
    assert_select "h2", text: "SHIPPING"
    assert_select "h2", text: "PAYMENT"
  end

  test "checkout leaves a stripe mount point" do
    get "/dashboard/checkout"
    assert_select "div#payment-element[data-stripe-mount]"
  end
end
