require "test_helper"

class AdminAccountsTest < ActionDispatch::IntegrationTest
  setup do
    @token = SecureRandom.hex(4)
    sign_in create_account(superuser: true)
  end

  def account(name, status: 2, superuser: false)
    create_account(email: "#{name}-#{@token}@example.test", status: status, superuser: superuser)
  end

  def rows
    css_select("table tbody tr")
  end

  test "lists real accounts with their status and role" do
    account("verified", status: 2)
    account("boss", status: 2, superuser: true)
    account("pending", status: 1)

    get "/admin/accounts", params: { q: @token }
    assert_response :success
    assert_equal 3, rows.size

    boss = rows.find { |row| row.text.include?("boss-#{@token}") }
    assert_includes boss.text, "Superuser"
    assert_includes boss.text, "Verified"
    pending = rows.find { |row| row.text.include?("pending-#{@token}") }
    assert_includes pending.text, "Customer"
    assert_includes pending.text, "Unverified"
  end

  test "the placeholder accounts are gone" do
    get "/admin/accounts"
    refute_selector_text "body", /queen\.com/
  end

  test "the subtitle counts every account and the verified ones" do
    account("one", status: 2)
    account("two", status: 1)

    get "/admin/accounts"
    assert_select "p", text: "#{Account.count} total, #{Account.where(status: 2).count} verified"
  end

  test "search matches part of an email, ignoring case" do
    account("findme")
    account("other")

    get "/admin/accounts", params: { q: "FINDME-#{@token}" }
    assert_equal 1, rows.size
    assert_includes rows.first.text, "findme-#{@token}@example.test"
  end

  test "a percent sign in the search is matched literally, not as a wildcard" do
    account("someone")

    get "/admin/accounts", params: { q: "%" }
    assert_equal 0, rows.size
    assert_select "body", text: /No accounts match/
  end

  test "the status filter narrows the list and marks itself current" do
    account("open", status: 2)
    account("gone", status: 3)

    get "/admin/accounts", params: { q: @token, status: "closed" }
    assert_equal 1, rows.size
    assert_includes rows.first.text, "gone-#{@token}"
    assert_select "a[aria-current='page']", text: "Closed"
  end

  test "the filter links keep the search term" do
    get "/admin/accounts", params: { q: "abc" }
    assert_select "a[href='/admin/accounts?q=abc&status=verified']", text: "Verified"
  end

  test "an unknown status shows everything rather than failing" do
    account("any")

    get "/admin/accounts", params: { q: @token, status: "banana" }
    assert_response :success
    assert_equal 1, rows.size
    assert_select "a[aria-current='page']", text: "All"
  end

  test "new accounts show their creation date and older ones a dash" do
    fresh = account("fresh")
    old = account("old")
    old.this.update(created_at: nil)

    get "/admin/accounts", params: { q: @token }
    fresh_row = rows.find { |row| row.text.include?("fresh-#{@token}") }
    old_row = rows.find { |row| row.text.include?("old-#{@token}") }
    assert_includes fresh_row.text, fresh.refresh.created_at.to_date.iso8601
    assert_includes old_row.text, "—"
  end

  test "non-superusers cannot reach it" do
    sign_in create_account(superuser: false)

    get "/admin/accounts"
    assert_response :not_found
  end
end
