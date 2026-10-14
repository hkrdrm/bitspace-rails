ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
# rails/test_help only pulls in minitest/mock along the ActiveRecord path, which
# this app does not load, so Object#stub would be undefined without this.
require "minitest/mock"
require_relative "support/fake_stripe_gateway"

module ActiveSupport
  class TestCase
    # Sequel gives us no transactional tests, and parallel workers share one
    # database here, so tests run serially and clean up after themselves.
    # Rails' parallel testing provisions a database per worker for ActiveRecord
    # only, so Sequel workers would all hammer the same database and collide.
    parallelize(workers: 1)

    # This app's data layer is Sequel; config/application.rb deliberately does not
    # require active_record/railtie, so ActiveRecord never gets a connection.
    # ActiveRecord::Base is still *defined* (solid_cache, solid_queue, solid_cable,
    # ActionText, ActiveStorage and ActionMailbox all require it), and that alone is
    # enough for rails/test_help to mix ActiveRecord::TestFixtures into every test.
    # Its setup_fixtures hook then asks for a connection pool unconditionally and
    # raises ActiveRecord::ConnectionNotDefined before any test body runs, so the
    # fixture lifecycle has to be neutralized here. Commenting out `fixtures :all`
    # is not sufficient -- the fixture load is not conditional on it.
    private def setup_fixtures(config = nil)
    end

    private def teardown_fixtures
    end

    # Every account created by a test uses an @example.test address so teardown
    # can find and remove it. Rodauth's after_login hook writes a remember key,
    # and those rows reference accounts, so they go first.
    ACCOUNT_KEY_TABLES = %i[
      account_remember_keys
      account_verification_keys
      account_password_reset_keys
      account_login_change_keys
    ].freeze

    teardown do
      ids = Account.where(Sequel.like(:email, "%@example.test")).select_map(:id)
      unless ids.empty?
        ACCOUNT_KEY_TABLES.each do |table|
          Account.db[table].where(id: ids).delete if Account.db.table_exists?(table)
        end
        Account.where(id: ids).delete
      end
    end

    # No test talks to Stripe. A test that needs the record of what the app
    # asked for reads StripeGateway.current.
    setup { StripeGateway.current = FakeStripeGateway.new }
    teardown { StripeGateway.current = nil }

    def stripe_signature(payload, secret: FakeStripeGateway::WEBHOOK_SECRET)
      now = Time.now
      Stripe::Webhook::Signature.generate_header(now, Stripe::Webhook::Signature.compute_signature(now, payload, secret))
    end

    # The fields of a paid Checkout Session for order, shaped as Stripe sends
    # them (API 2026-09-30: the shipping address is under collected_information).
    def paid_session(order, email: "buyer@example.test", tax: 0, shipping: 0, address: nil, payment_intent: "pi_#{SecureRandom.hex(6)}")
      fields = {
        id: order.stripe_session_id, object: "checkout.session", payment_status: "paid",
        payment_intent: payment_intent, amount_total: order.subtotal_cents + shipping + tax,
        customer_details: { email: email }, total_details: { amount_tax: tax, amount_shipping: shipping },
        metadata: { order_id: order.id.to_s }
      }
      fields[:collected_information] = { shipping_details: { name: "Pat Buyer", address: address } } if address
      fields
    end

    def create_account(email: nil, password: "password123", status: 2, superuser: false)
      Account.create(
        email: email || "test-#{SecureRandom.hex(6)}@example.test",
        password_hash: RodauthApp.rodauth.allocate.password_hash(password),
        status: status,
        superuser: superuser
      )
    end

    # Builds a product the way the admin does, through ProductEditor, then sets
    # every variant's stock. options maps an option name to its values; a value
    # is a name or a hash of value fields such as { name:, swatch_hex: }.
    def build_product(name: "Test Tee", slug: nil, price: "12.00", options: {}, stock: 5, active: true, image: "3crow.png")
      editor = ProductEditor.new(Product.new, {
        "product" => {
          "name" => name, "slug" => slug || "#{name.parameterize}-#{SecureRandom.hex(3)}",
          "price" => price, "image" => image, "active" => active ? "1" : "0"
        },
        "options" => options.map do |option_name, values|
          { "name" => option_name, "values" => values.map { |value| value.is_a?(Hash) ? value.stringify_keys : { "name" => value } } }
        end
      })
      assert editor.save, "could not build #{name}: #{editor.errors.join(' ')}"

      ProductVariant.where(product_id: editor.product.id).update(stock: stock)
      editor.product.refresh
    end

    # Exactly what the edit form submits for a product nobody has changed.
    def form_params_for(product)
      editor = ProductEditor.from_product(product)
      {
        "product" => {
          "name" => product.name, "slug" => product.slug, "description" => product.description.to_s,
          "image" => product.image.to_s, "price" => editor.price_input, "active" => product.active? ? "1" : "0"
        },
        "options" => indexed(editor.option_inputs.map do |option|
          {
            "name" => option[:name],
            "values" => indexed(option[:values].map do |value|
              {
                "name" => value[:name], "position" => value[:position].to_s, "swatch_hex" => value[:swatch_hex].to_s,
                "swatch_image" => value[:swatch_image].to_s, "image" => value[:image].to_s
              }
            end)
          }
        end),
        "variants" => editor.variant_inputs
      }
    end

    def with_value(params, option_name, value_name)
      params.deep_dup.tap do |copy|
        values = copy["options"].values.find { |option| option["name"] == option_name }["values"]
        values[(values.keys.map(&:to_i).max.to_i + 1).to_s] = { "name" => value_name }
      end
    end

    def without_value(params, option_name, value_name)
      params.deep_dup.tap do |copy|
        values = copy["options"].values.find { |option| option["name"] == option_name }["values"]
        values.reject! { |_, value| value["name"] == value_name }
      end
    end

    def variant_named(product, label)
      product.refresh.variants.find { |variant| variant.label == label }
    end

    # An order written directly, as if checkout and payment had already run.
    # items are hashes of name:, label:, price: (cents), quantity:, and
    # optionally variant_id: and sku:.
    def build_order(status: "paid", fulfillment: "pickup", account: nil, items: nil, **attrs)
      items ||= [ { name: "Test Tee", label: "Black / M", price: 1200, quantity: 1 } ]
      subtotal = items.sum { |item| item[:price] * item[:quantity] }
      order = Order.create({
        status: status, fulfillment: fulfillment, account_id: account&.id,
        email: account&.email || "buyer-#{SecureRandom.hex(3)}@example.test",
        subtotal_cents: subtotal, total_cents: subtotal,
        paid_at: (Time.current unless status == "pending")
      }.merge(attrs))
      items.each do |item|
        OrderItem.create(
          order_id: order.id, variant_id: item[:variant_id], product_name: item[:name],
          variant_label: item[:label], sku: item[:sku], unit_price_cents: item[:price], quantity: item[:quantity]
        )
      end
      order.refresh
    end

    private def indexed(rows)
      rows.each_with_index.to_h { |row, index| [ index.to_s, row ] }
    end
  end
end

class ActionDispatch::IntegrationTest
  def sign_in(account, password: "password123")
    post "/login", params: { email: account.email, password: password }
  end

  # assert_select with both text: and count: 0 passes even when the text is on
  # the page, so absence is checked against the matched elements' text here.
  def refute_selector_text(selector, pattern, message = nil)
    matches = css_select(selector).select do |element|
      pattern.is_a?(Regexp) ? element.text.match?(pattern) : element.text.strip == pattern
    end
    assert_empty matches.map { |element| element.text.squish[0, 80] },
      message || "expected no #{selector} with text #{pattern.inspect}"
  end
end
