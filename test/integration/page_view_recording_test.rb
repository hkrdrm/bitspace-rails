require "test_helper"

class PageViewRecordingTest < ActionDispatch::IntegrationTest
  setup { PageView.dataset.delete }
  teardown { PageView.dataset.delete }

  test "a GET on an html page is recorded" do
    get "/"

    assert_equal 1, PageView.count
    view = PageView.first
    assert_equal "/", view.path
    assert_equal false, view.bot
  end

  test "a known bot user agent is flagged" do
    get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1)" }

    assert_equal true, PageView.first.bot
  end

  test "a browser user agent is not flagged" do
    get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36" }

    assert_equal false, PageView.first.bot
  end

  test "the health check is not recorded" do
    get "/up"

    assert_equal 0, PageView.count
  end

  test "non-GET requests are not recorded" do
    post "/login", params: { email: "nobody@example.test", password: "wrong" }

    assert_equal 0, PageView.count
  end

  test "a signed in account is attributed" do
    account = create_account
    sign_in account
    PageView.dataset.delete

    get "/"

    assert_equal account.id, PageView.first.account_id
  end

  test "a recorder failure does not break the response" do
    PageView.stub(:create, ->(*) { raise "boom" }) do
      get "/"
      assert_response :success
    end
  end
end
