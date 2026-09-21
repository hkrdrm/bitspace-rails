require "test_helper"

class RemovedRoutesTest < ActionDispatch::IntegrationTest
  test "comics route is gone" do
    get "/comics"
    assert_response :not_found
  end

  test "issues routes are gone" do
    get "/issues"
    assert_response :not_found

    get "/issues/1"
    assert_response :not_found
  end

  # RodauthApp gates every path starting with "/dashboard" in middleware, ahead of
  # Rails routing, so an unauthenticated request to a removed dashboard path
  # redirects to /login and can never surface as a 404. Assert against the router
  # itself, which is what "the route is gone" actually means.
  test "new_issue route is gone" do
    assert_routing_error "/dashboard/new_issue"
    assert_routing_error "/dashboard/create_issue", method: :post

    assert_equal({ controller: "dashboard", action: "index" },
      Rails.application.routes.recognize_path("/dashboard", method: :get))
  end

  test "home page still renders" do
    get "/"
    assert_response :success
  end

  test "contact page still renders" do
    get "/contact"
    assert_response :success
  end

  private
    def assert_routing_error(path, method: :get)
      assert_raises(ActionController::RoutingError, "expected no route for #{method.to_s.upcase} #{path}") do
        Rails.application.routes.recognize_path(path, method: method)
      end
    end
end
