require "test_helper"

class AuthPagesRenderTest < ActionDispatch::IntegrationTest
  test "login page renders with its heading" do
    get "/login"
    assert_response :success
    assert_select "h1 span", text: "WELCOME"
    assert_select "h1 span", text: "BACK."
  end

  test "create account page renders with its heading" do
    get "/create-account"
    assert_response :success
    assert_select "h1 span", text: "JOIN"
    assert_select "h1 span", text: "BITSPACE."
  end

  test "reset password request page renders" do
    get "/reset-password-request"
    assert_response :success
    assert_select "h1 span", text: "RESET YOUR"
  end
end
