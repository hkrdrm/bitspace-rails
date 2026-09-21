require "test_helper"

class DashboardAuthorizationTest < ActionDispatch::IntegrationTest
  PATHS = %w[/dashboard /dashboard/account /dashboard/orders /dashboard/checkout].freeze

  test "signed out visitors are redirected away from every dashboard page" do
    PATHS.each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "a signed in account can reach every dashboard page" do
    sign_in create_account

    PATHS.each do |path|
      get path
      assert_response :success, "expected #{path} to render when signed in"
    end
  end

  test "the account page links to the rodauth routes" do
    sign_in create_account

    get "/dashboard/account"
    assert_select "a[href=?]", "/change-password"
    assert_select "a[href=?]", "/change-login"
    assert_select "a[href=?]", "/close-account"
  end

  # current_account is rendered with &., so a nil would show as an empty string
  # rather than raising. Pin the signed-in account's own email to both pages.
  test "the signed in account's email is shown, not blank" do
    account = create_account
    sign_in account

    get "/dashboard"
    assert_select "dd", text: account.email

    get "/dashboard/account"
    assert_select "dd", text: account.email
  end
end
