require "test_helper"

# Every timestamp is stored and read as UTC, whoever writes it: Sequel's
# timestamps plugin, app code using Time.current, or a database default.
# Without that, the plugin wrote the server's local wall time while the rest
# wrote UTC, so one row could hold times five hours apart for the same moment.
class TimestampsTest < ActiveSupport::TestCase
  teardown { Order.dataset.delete }

  def stored(order, column)
    text = Order.db[:orders].where(id: order.id).get(Sequel.cast(column, :text))
    Time.find_zone("UTC").parse(text)
  end

  test "the timestamps plugin and app code write the same zone" do
    order = build_order(status: "pending")
    order.update(paid_at: Time.current)

    assert_in_delta stored(order, :created_at), stored(order, :paid_at), 60
  end

  test "a timestamp reads back as the instant that was written" do
    moment = Time.current.change(usec: 0)
    order = build_order(paid_at: moment)

    assert_in_delta moment, order.refresh.paid_at, 1
    assert_in_delta moment, stored(order, :paid_at), 1
  end

  test "a database default timestamp reads back as now" do
    account = create_account
    assert_in_delta Time.current, account.refresh.created_at, 60
  end
end
