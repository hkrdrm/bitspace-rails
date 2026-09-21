require "test_helper"

class AdminTrafficTest < ActionDispatch::IntegrationTest
  setup do
    PageView.dataset.delete
    @superuser = create_account(superuser: true)
    sign_in @superuser
  end

  teardown { PageView.dataset.delete }

  test "renders an empty state when nothing has been recorded" do
    PageView.dataset.delete

    get "/admin/traffic"
    assert_response :success
    assert_select "h1 span", text: "SITE"
  end

  test "counts humans and bots separately" do
    3.times { PageView.create(path: "/", ip: "1.2.3.4", user_agent: "Chrome", bot: false, created_at: Time.current) }
    2.times { PageView.create(path: "/", ip: "5.6.7.8", user_agent: "Googlebot", bot: true, created_at: Time.current) }

    get "/admin/traffic"
    assert_response :success
    assert_select "body", text: /3/
    assert_select "body", text: /2/
  end

  # The assertions above only check that a digit appears somewhere on the page.
  # This pins the four aggregates to exact rendered values, so a broken window,
  # grouping or bot split cannot pass unnoticed.
  test "the stat tiles report the right numbers for the window" do
    now = Time.current
    5.times { PageView.create(path: "/", ip: "1.1.1.1", user_agent: "Chrome", bot: false, created_at: now) }
    3.times { PageView.create(path: "/contact", ip: "1.1.1.1", user_agent: "Chrome", bot: false, created_at: now - 2.days) }
    2.times { PageView.create(path: "/", ip: "2.2.2.2", user_agent: "Googlebot", bot: true, created_at: now) }
    # Outside the 7 day window, and deliberately large enough to be obvious.
    100.times { PageView.create(path: "/old", ip: "9.9.9.9", user_agent: "Ancient", bot: false, created_at: now - 30.days) }

    get "/admin/traffic"
    assert_response :success

    # Page views, Unique IPs, Humans, Bots -- in the order the view renders them.
    assert_equal [ "10", "2", "8", "2" ], css_select("div.text-4xl").map { |el| el.text.strip }

    assert_select "td", text: "/"
    assert_select "td", text: "/contact"
    assert_select "td", text: "/old", count: 0, message: "rows outside the window must not appear"
  end

  test "non-superusers cannot reach it" do
    sign_in create_account(superuser: false)

    get "/admin/traffic"
    assert_response :not_found
  end
end
