require "test_helper"

class AdminSettingsTest < ActionDispatch::IntegrationTest
  teardown { StoreSetting.dataset.delete }

  setup do
    StoreSetting.dataset.delete
    sign_in create_account(superuser: true)
  end

  def stripe
    StripeGateway.current
  end

  def save(shipping: "8.00", pickup: "Pickup on Main.", tax_enabled: "0", tax_rate: "")
    patch "/admin/settings", params: { settings: { shipping: shipping, pickup_instructions: pickup, tax_enabled: tax_enabled, tax_rate: tax_rate } }
  end

  test "the page shows the current settings and that no tax is collected" do
    get "/admin/settings"
    assert_response :success
    assert_select "input[name='settings[shipping]'][value='8.00']"
    assert_select "textarea[name='settings[pickup_instructions]']", text: StoreSetting::DEFAULT_INSTRUCTIONS
    assert_select "body", text: /No sales tax is being collected\./
    assert_select "nav a[href='/admin/settings']", text: "Settings"
  end

  test "saving updates shipping and pickup instructions" do
    save(shipping: "6.50", pickup: "Come by after 5.")

    assert_redirected_to "/admin/settings"
    setting = StoreSetting.current
    assert_equal 650, setting.shipping_cents
    assert_equal "Come by after 5.", setting.pickup_instructions
  end

  test "a malformed or too large shipping rate is an error and saves nothing" do
    save(shipping: "abc")
    assert_response :unprocessable_entity
    assert_select "li", text: "Shipping rate must be a dollar amount, like 8.00."

    save(shipping: "100.01")
    assert_select "li", text: "Shipping rate must be between $0.00 and $100.00."
    assert_equal 800, StoreSetting.current.shipping_cents
  end

  test "turning tax on creates a Stripe tax rate for that rate" do
    save(tax_enabled: "1", tax_rate: "7")

    setting = StoreSetting.current
    assert setting.tax_enabled?
    assert_equal 700, setting.tax_rate_bps
    assert_equal [ 700 ], stripe.tax_rates_created
    assert_equal "txr_test_1", setting.checkout_tax_rate_id
  end

  test "saving the same rate again creates no new Stripe tax rate, and a new rate does" do
    save(tax_enabled: "1", tax_rate: "7")
    save(tax_enabled: "1", tax_rate: "7.00")
    assert_equal [ 700 ], stripe.tax_rates_created

    save(tax_enabled: "1", tax_rate: "7.25")
    assert_equal [ 700, 725 ], stripe.tax_rates_created
    assert_equal "txr_test_2", StoreSetting.current.stripe_tax_rate_id
  end

  test "tax on without a rate, or with a bad one, is an error" do
    save(tax_enabled: "1", tax_rate: "")
    assert_select "li", text: "Tax rate is required while sales tax is on."

    save(tax_enabled: "1", tax_rate: "seven")
    assert_select "li", text: "Tax rate must be a percent, like 7 or 7.25."

    save(tax_enabled: "1", tax_rate: "16")
    assert_select "li", text: "Tax rate must be between 0.01% and 15%."
    refute StoreSetting.current.tax_enabled?
    assert_empty stripe.tax_rates_created
  end

  test "when Stripe refuses the tax rate, nothing is saved" do
    stripe.fail_with = "Invalid API key"
    save(shipping: "5.00", tax_enabled: "1", tax_rate: "7")

    assert_response :unprocessable_entity
    assert_select "li", text: /Stripe did not accept the tax rate/
    setting = StoreSetting.current
    assert_equal 800, setting.shipping_cents
    refute setting.tax_enabled?
  end

  test "non-superusers cannot reach it" do
    sign_in create_account(superuser: false)
    get "/admin/settings"
    assert_response :not_found
  end
end
