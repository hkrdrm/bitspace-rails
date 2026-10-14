require "test_helper"

class DashboardPagesTest < ActionDispatch::IntegrationTest
  setup { sign_in create_account }

  test "orders page renders" do
    get "/dashboard/orders"
    assert_response :success
    assert_select "h1 span", text: "YOUR"
  end
end
