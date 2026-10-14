require "test_helper"

class StoreSettingTest < ActiveSupport::TestCase
  teardown { StoreSetting.dataset.delete }

  test "current creates the row with defaults, once" do
    StoreSetting.dataset.delete
    setting = StoreSetting.current

    assert_equal 800, setting.shipping_cents
    assert_equal StoreSetting::DEFAULT_INSTRUCTIONS, setting.pickup_instructions
    refute setting.tax_enabled?
    assert_equal setting.id, StoreSetting.current.id
    assert_equal 1, StoreSetting.count
  end

  test "shipping must be between $0 and $100" do
    setting = StoreSetting.current
    setting.shipping_cents = 10_001
    refute setting.valid?
    setting.shipping_cents = 0
    assert setting.valid?
  end

  test "a tax rate is required while tax is on, and must be 0.01% to 15%" do
    setting = StoreSetting.current
    setting.set(tax_enabled: true, tax_rate_bps: nil)
    refute setting.valid?
    setting.tax_rate_bps = 1501
    refute setting.valid?
    setting.tax_rate_bps = 700
    assert setting.valid?
  end

  test "checkout only gets a tax rate id while tax is on" do
    setting = StoreSetting.current
    setting.update(tax_enabled: false, tax_rate_bps: 700, stripe_tax_rate_id: "txr_1", stripe_tax_rate_bps: 700)
    assert_nil setting.checkout_tax_rate_id

    setting.update(tax_enabled: true)
    assert_equal "txr_1", setting.checkout_tax_rate_id
  end

  test "pickup instructions are required and capped at 500 characters" do
    setting = StoreSetting.current
    setting.pickup_instructions = "  "
    refute setting.valid?
    setting.pickup_instructions = "x" * 501
    refute setting.valid?
  end
end
