require "test_helper"

class AdminAuthorizationTest < ActionDispatch::IntegrationTest
  # Every path Admin::BaseController gates, including the three the tabs link to.
  ADMIN_PATHS = %w[/admin /admin/accounts /admin/orders /admin/traffic].freeze

  test "signed out visitors are redirected away from admin" do
    get "/admin"
    assert_response :redirect
  end

  test "a signed in non-superuser gets a 404 from admin" do
    account = create_account(superuser: false)
    sign_in account

    get "/admin"
    assert_response :not_found
  end

  test "a superuser can reach the admin overview" do
    account = create_account(superuser: true)
    sign_in account

    get "/admin"
    assert_response :success
    assert_select "h1 span", text: "STUDIO"
  end

  test "the gate covers every admin path, not just the overview" do
    sign_in create_account(superuser: true)
    ADMIN_PATHS.each do |path|
      get path
      assert_response :success, "#{path} should render for a superuser (got #{response.status})"
    end

    sign_in create_account(superuser: false)
    ADMIN_PATHS.each do |path|
      get path
      assert_response :not_found, "#{path} should 404 for a non-superuser (got #{response.status})"
    end
  end
end
