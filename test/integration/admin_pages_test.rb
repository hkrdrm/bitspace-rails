require "test_helper"

class AdminPagesTest < ActionDispatch::IntegrationTest
  setup do
    @superuser = create_account(superuser: true)
    sign_in @superuser
  end

  test "accounts page renders a table of accounts" do
    get "/admin/accounts"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Email"
  end

  test "orders page renders a table of orders" do
    get "/admin/orders"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Order"
  end

  test "non-superusers cannot reach either page" do
    plain = create_account(superuser: false)
    sign_in plain

    get "/admin/accounts"
    assert_response :not_found

    get "/admin/orders"
    assert_response :not_found
  end
end
