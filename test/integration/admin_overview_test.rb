require "test_helper"

class AdminOverviewTest < ActionDispatch::IntegrationTest
  setup do
    PageView.dataset.delete
    sign_in create_account(superuser: true)
  end

  teardown do
    PageView.dataset.delete
    Product.dataset.delete
  end

  def tiles
    css_select("div.text-4xl").map { |el| el.text.strip }
  end

  test "the tiles report real accounts, products and traffic" do
    create_account(status: 1)
    build_product(name: "Live Tee", options: {})
    build_product(name: "Draft Tee", options: {}, active: false)
    3.times { PageView.create(path: "/", ip: "1.1.1.1", user_agent: "Chrome", bot: false, created_at: Time.current) }
    PageView.create(path: "/", ip: "1.1.1.1", user_agent: "Chrome", bot: false, created_at: 30.days.ago)

    get "/admin"
    assert_response :success

    # Accounts, Verified, Products live, Page views -- in render order.
    expected = [ Account.count, Account.where(status: 2).count, 1, 3 ].map(&:to_s)
    assert_equal expected, tiles
  end

  test "the accounts tile counts sign-ups from the last week" do
    create_account
    old = create_account
    old.this.update(created_at: 30.days.ago)

    get "/admin"
    recent = Account.where { created_at >= 7.days.ago }.count
    assert_select "div", text: "+#{recent} this week"
  end

  test "the placeholder numbers and orders are gone" do
    get "/admin"
    refute_selector_text "body", /\$1,860|#1042/
  end

  test "recent activity lists new accounts and product changes, newest first" do
    newcomer = create_account
    newcomer.this.update(created_at: 2.hours.ago)
    product = build_product(name: "Fresh Print Tee", options: {})
    product.this.update(updated_at: 1.hour.ago)

    get "/admin"
    items = css_select("[data-activity] li").map { |li| li.text.squish }
    product_index = items.index { |item| item.include?("Fresh Print Tee") }
    account_index = items.index { |item| item.include?(newcomer.email) }

    assert product_index, "expected the product change in #{items.inspect}"
    assert account_index, "expected the new account in #{items.inspect}"
    assert_operator product_index, :<, account_index
  end

  test "the traffic panel shows this week's numbers" do
    2.times { PageView.create(path: "/", ip: "1.1.1.1", user_agent: "Chrome", bot: false, created_at: Time.current) }
    PageView.create(path: "/", ip: "2.2.2.2", user_agent: "Googlebot", bot: true, created_at: Time.current)

    get "/admin"
    assert_select "[data-traffic-summary]", text: /3 page views.*2 from people.*1 from bots/m
  end
end
