require "test_helper"

# Times are rendered in UTC inside a <time> element, and the local-time
# Stimulus controller rewrites them in the viewer's time zone.
class LocalTimeTest < ActionDispatch::IntegrationTest
  teardown { Order.dataset.delete }

  setup do
    @paid_at = Time.utc(2026, 10, 14, 17, 42)
  end

  test "the admin order page shows when it was paid, in UTC, for the browser to convert" do
    order = build_order(paid_at: @paid_at)
    sign_in create_account(superuser: true)

    get "/admin/orders/#{order.number}"
    assert_select "time[datetime='2026-10-14T17:42:00Z'][data-controller='local-time']", text: "2026-10-14 17:42 UTC"
  end

  test "order lists and pages give dates the browser can convert" do
    account = create_account
    order = build_order(account: account, paid_at: @paid_at)
    sign_in account

    get "/dashboard/orders"
    assert_select "tbody time[datetime='2026-10-14T17:42:00Z'][data-local-time-format-value='date']", text: "2026-10-14"

    get "/orders/#{order.token}"
    assert_select "time[data-controller='local-time']"
  end

  test "the accounts table gives creation dates the browser can convert" do
    sign_in create_account(superuser: true)

    get "/admin/accounts"
    assert_select "tbody time[data-controller='local-time'][data-local-time-format-value='date']"
  end

  test "the controller the times name exists" do
    assert File.exist?(Rails.root.join("app/javascript/controllers/local_time_controller.js"))
  end
end
