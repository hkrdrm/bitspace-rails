# Orders and Checkout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people buy from the shop. A session cart feeds Stripe hosted Checkout, with free McComb pickup or one flat shipping rate and an optional Mississippi sales tax. Paid orders take stock and show up in the admin, where the owner sets each order's status. Signed-in customers see their orders in the dashboard.

**Architecture:**
- **Cart:** a session-backed `Cart`.
- **Checkout:** a `Checkout` object snapshots the cart into a `pending` order and opens a Stripe Checkout Session.
- **Paying:** `OrderFulfiller` marks the order paid and takes stock. It runs from the `checkout.session.completed` webhook or from the success page, whichever arrives first, and only the first call changes anything.
- **Stripe calls:** only `StripeGateway` talks to Stripe. Tests swap in `FakeStripeGateway`.

**Tech Stack:**
- Rails 8.0.2 with Sequel (sequel-rails), PostgreSQL and Rodauth.
- `stripe` gem 20.x (API version 2026-09-30).
- Minitest integration tests, Stimulus.

**Spec:** `docs/superpowers/specs/2026-10-13-orders-and-checkout-design.md`

## Global Constraints

**Workflow**
- Work on the `orders-checkout` branch. It already exists and holds the spec commit.

**Data and money**
- Sequel, not ActiveRecord. Models subclass `Sequel::Model`. Migrations are `Sequel.migration do ... end`.
- Money is integer cents everywhere. Tax rates are integer basis points (700 = 7%). Malformed money or percent input is an error, never zero.

**Stripe**
- Only `app/models/stripe_gateway.rb` may reference `Stripe::` API classes. The exceptions are `test/support/fake_stripe_gateway.rb` and `test/test_helper.rb`, which build Stripe objects and signatures.
- Every test runs against `FakeStripeGateway`, which `test/test_helper.rb` installs in a global `setup`. No test may reach the network.

**Running tests**
- Run tests as `bin/rails test <path>`. The full suite is `bin/rails test test/`, never bare `bin/rails test`.
- The full suite takes ~400s against a shared remote database. Run it in the background, and never run two test processes at once from any session or agent. Concurrent runs delete each other's rows and cause fake failures.
- Do not remove the `setup_fixtures` / `teardown_fixtures` overrides in `test/test_helper.rb`.
- Test cleanup is per file. A test file that creates orders deletes them in `teardown` with `Order.dataset.delete`. One that touches settings uses `StoreSetting.dataset.delete`, and one that creates products uses `Product.dataset.delete`.
- To check that text is absent, use `refute_selector_text`. Never use `assert_select ..., text:, count: 0`, which passes even when the text is present.

**Tooling and dev server**
- `bin/rubocop` must exit 0 at the end of every task.
- `bin/brakeman --no-pager` must report no warnings beyond the pre-existing Rails EOL notice. Its exit code is 5 on `master` already.
- Do not run `bin/rails tailwindcss:build`. The `bin/dev` watcher compiles CSS.
- After Task 1's migration, the user must restart `bin/dev` before any browser check. Sequel caches columns per process.

**Code style**
- House style for failed form renders is `status: :unprocessable_entity`, matching `Admin::ProductsController`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Customer-facing copy**

These strings must be used verbatim:
- "Payment received, confirming your order…"
- "We're still confirming your payment. Check back in a minute."
- "Bookmark this page to check on your order."
- "Checkout is unavailable right now, try again shortly."
- "Mississippi sales tax is added at checkout for MS addresses and pickups."
- "No sales tax is being collected."
- "Order updated."

## Deviations from the spec (rulings made while planning)

1. **`store_settings.stripe_tax_rate_bps` (an extra integer column).** The spec says to create a new Stripe tax rate when the rate "differs from the one behind `stripe_tax_rate_id`". The app can only know that if it stores the rate the id was created for.
2. **`StripeGateway.current` instead of `config.x.stripe_gateway`.** This is a class-level accessor with a lazy default. It survives development code reloading without an initializer that references an autoloaded constant.
3. **The order id is taken from `orders_id_seq` before the insert,** so that `number` (`BS-<id + 1000>`) can be NOT NULL without a second write.
4. **The session lifetime is 31 minutes, not 30.** Stripe rejects an `expires_at` under 30 minutes away, and a value of exactly 30 races the clock.
5. **The cart is cleared only for the order this browser just checked out.** At checkout, `session[:checkout_order_id]` is set, and the success page clears the cart only when the paid order matches it. Without this, opening an old order from the dashboard would empty the current cart.
6. **The webhook controller inherits `ActionController::API`.** That means no CSRF, no `allow_browser` and no page-view recording.

## Review Focus

1. **The redirect to Stripe must leave the site.**
   - Rails blocks redirects to other hosts unless they pass `allow_other_host: true`.
   - Turbo cannot follow a cross-origin redirect, so the checkout form needs `data-turbo="false"`.
   - *Pinned in Task 4 (`delivery offers pickup with instructions and the flat shipping rate`) and Task 5 (`a pickup checkout saves a pending order and sends the buyer to Stripe`).*
2. **Stripe's webhook POST carries no CSRF token or session.** The endpoint must accept it with forgery protection on. *Pinned in Task 7 (`the endpoint needs no CSRF token, because Stripe never has one`).*
3. **A `charge.refunded` event with no payment intent must not match orders whose `stripe_payment_intent_id` is NULL.** `where(col: nil)` is `IS NULL`. *Pinned in Task 7 (`a refund with no payment intent changes nothing`).*
4. **Opening an old order must not empty the current cart.** *Pinned in Task 8 (`viewing an older order leaves the current cart alone`).*
5. **Stale or malformed cart entries must not raise.** This covers deleted variants and non-numeric quantities. *Pinned in Task 3 (`junk in the session is dropped instead of raising`, `lines drop variants that were deleted`).*

---

### Task 1: Orders, order items and store settings

**Files:**
- Create: `db/migrate/20261013200000_create_orders_and_store_settings.rb`
- Create: `app/models/order.rb`, `app/models/order_item.rb`, `app/models/store_setting.rb`
- Modify: `test/test_helper.rb` (add `build_order`)
- Modify: `db/schema.rb` (regenerated by the migration)
- Test: `test/models/order_test.rb`, `test/models/store_setting_test.rb`

**Interfaces:**
- Produces:
  - `Order` constants: `STATUSES`, `ADMIN_STATUSES`, `NEEDS_ACTION`, `FULFILLMENTS`, `STATUS_LABELS`.
  - `Order` dataset method: `Order.placed`.
  - `Order` instance methods:
    - predicates: `#pending?`, `#pickup?`, `#shipping?`, `#oversold?`, `#partially_refunded?`;
    - readers: `#status_label`, `#item_count`, `#address_lines → Array<String>`;
    - `#record_refund(amount_refunded:, amount:)`;
    - associations `#items` (OrderItem, ordered by id) and `#account`.
  - `OrderItem#variant` (ProductVariant or nil) and `OrderItem#total_cents`.
  - `StoreSetting`:
    - `StoreSetting.current` and `StoreSetting::DEFAULT_INSTRUCTIONS`;
    - `#checkout_tax_rate_id → String or nil`, `#tax_enabled?`;
    - columns `shipping_cents`, `pickup_instructions`, `tax_enabled`, `tax_rate_bps`, `stripe_tax_rate_id`, `stripe_tax_rate_bps`.
  - Test helper: `build_order(status: "paid", fulfillment: "pickup", account: nil, items: nil, **attrs) → Order`.

- [ ] **Step 1: Write the failing model tests**

`test/models/order_test.rb`:

```ruby
require "test_helper"

class OrderTest < ActiveSupport::TestCase
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  test "a new order gets a public number from its id and a long random token" do
    order = build_order
    assert_equal "BS-#{order.id + 1000}", order.number
    assert_operator order.token.length, :>=, 32
    refute_equal order.token, build_order.token
  end

  test "an order starts pending" do
    order = Order.create(fulfillment: "pickup", subtotal_cents: 100, total_cents: 100)
    assert_equal "pending", order.status
    assert_equal 0, order.refunded_cents
  end

  test "unknown statuses and fulfillments are rejected" do
    refute Order.new(fulfillment: "pickup", status: "lost", subtotal_cents: 1, total_cents: 1).valid?
    refute Order.new(fulfillment: "drone", subtotal_cents: 1, total_cents: 1).valid?
  end

  test "placed leaves out pending orders" do
    paid = build_order(status: "paid")
    pending = build_order(status: "pending")

    ids = Order.placed.select_map(:id)
    assert_includes ids, paid.id
    refute_includes ids, pending.id
  end

  test "item count adds up quantities" do
    order = build_order(items: [
      { name: "A", label: "S", price: 1000, quantity: 2 },
      { name: "B", label: "B", price: 500, quantity: 3 }
    ])
    assert_equal 5, order.item_count
    assert_equal 3500, order.subtotal_cents
  end

  test "a full refund marks the order refunded and a partial one keeps its status" do
    full = build_order(status: "shipped")
    full.record_refund(amount_refunded: full.total_cents, amount: full.total_cents)
    assert_equal "refunded", full.refresh.status

    partial = build_order(status: "shipped")
    partial.record_refund(amount_refunded: 300, amount: partial.total_cents)
    partial.refresh
    assert_equal "shipped", partial.status
    assert_equal 300, partial.refunded_cents
    assert partial.partially_refunded?
  end

  test "address lines come from Stripe's address hash" do
    address = { line1: "1 Main St", line2: nil, city: "McComb", state: "MS", postal_code: "39648", country: "US" }
    order = build_order(fulfillment: "shipping", ship_address: address.to_json)
    assert_equal [ "1 Main St", "McComb, MS 39648", "US" ], order.address_lines
    assert_equal [], build_order.address_lines
  end

  test "deleting a product keeps its order lines, unlinked" do
    product = build_product(name: "Gone Tee")
    order = build_order(items: [ { name: "Gone Tee", label: "Gone Tee", price: 1200, quantity: 1, variant_id: product.variants.first.id } ])

    Product.where(id: product.id).delete
    item = order.refresh.items.first
    assert_nil item.variant_id
    assert_equal "Gone Tee", item.product_name
  end
end
```

`test/models/store_setting_test.rb`:

```ruby
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
```

Add `build_order` to `test/test_helper.rb`, inside `class TestCase`, directly after `variant_named`:

```ruby
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/order_test.rb test/models/store_setting_test.rb`
Expected: errors with `NameError: uninitialized constant Order` / `StoreSetting`.

- [ ] **Step 3: Write the migration**

`db/migrate/20261013200000_create_orders_and_store_settings.rb`:

```ruby
# frozen_string_literal: true

# Orders, their item snapshots, and the one-row store settings (shipping rate,
# pickup text, sales tax). Items copy what was bought so products stay
# deletable: variant_id goes NULL and the snapshot remains.
Sequel.migration do
  change do
    create_table :store_settings do
      primary_key :id
      Integer   :shipping_cents, null: false, default: 800
      String    :pickup_instructions, text: true, null: false, default: "Pickup in McComb, MS. We'll reach out when it's ready."
      TrueClass :tax_enabled, null: false, default: false
      Integer   :tax_rate_bps
      String    :stripe_tax_rate_id
      Integer   :stripe_tax_rate_bps
      DateTime  :updated_at
    end

    create_table :orders do
      primary_key :id
      String    :number, null: false, unique: true
      String    :token, null: false, unique: true
      foreign_key :account_id, :accounts, type: :Bignum, on_delete: :set_null
      String    :email
      String    :status, null: false, default: "pending"
      String    :fulfillment, null: false
      Integer   :subtotal_cents, null: false
      Integer   :shipping_cents, null: false, default: 0
      Integer   :tax_cents, null: false, default: 0
      Integer   :total_cents, null: false
      Integer   :tax_rate_bps
      Integer   :refunded_cents, null: false, default: 0
      String    :ship_name
      String    :ship_address, text: true
      String    :tracking_number
      TrueClass :oversold, null: false, default: false
      String    :stripe_session_id, unique: true
      String    :stripe_payment_intent_id
      DateTime  :paid_at
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false

      index :account_id
      index :status
      index :stripe_payment_intent_id
    end

    create_table :order_items do
      primary_key :id
      foreign_key :order_id, :orders, null: false, on_delete: :cascade
      foreign_key :variant_id, :product_variants, on_delete: :set_null
      String  :product_name, null: false
      String  :variant_label, null: false
      String  :sku
      Integer :unit_price_cents, null: false
      Integer :quantity, null: false

      constraint(:order_items_positive_quantity) { quantity > 0 }
      index :order_id
    end
  end
end
```

Run:

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
git status --short db/
```

Expected: both migrate without error, and `db/schema.rb` shows as modified.

- [ ] **Step 4: Write the models**

`app/models/order.rb`:

```ruby
# A purchase. Created "pending" when checkout starts and marked "paid" by
# OrderFulfiller once Stripe confirms payment; every later status is the
# owner's to set, in any order. Items keep their own copy of what was bought.
class Order < Sequel::Model
  STATUSES = %w[pending paid printing ready_for_pickup shipped completed cancelled refunded].freeze
  ADMIN_STATUSES = (STATUSES - [ "pending" ]).freeze
  NEEDS_ACTION = %w[paid printing ready_for_pickup].freeze
  FULFILLMENTS = %w[pickup shipping].freeze
  STATUS_LABELS = {
    "pending" => "Confirming payment", "paid" => "Paid", "printing" => "Printing",
    "ready_for_pickup" => "Ready for pickup", "shipped" => "Shipped", "completed" => "Completed",
    "cancelled" => "Cancelled", "refunded" => "Refunded"
  }.freeze
  NUMBER_OFFSET = 1000
  MAX_TRACKING = 100

  one_to_many :items, class: :OrderItem, order: :id
  many_to_one :account

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  dataset_module do
    # Orders someone has paid for. Pending ones are in flight or abandoned.
    def placed
      exclude(status: "pending")
    end
  end

  def before_validation
    if new?
      self.status ||= "pending"
      # The public number derives from the id, so the id comes from the
      # sequence before the insert instead of a second write after it.
      values[:id] ||= db.get(Sequel.function(:nextval, "orders_id_seq"))
      self.number ||= "BS-#{id + NUMBER_OFFSET}"
      self.token ||= SecureRandom.urlsafe_base64(24)
    end
    super
  end

  def pending?
    status == "pending"
  end

  def pickup?
    fulfillment == "pickup"
  end

  def shipping?
    fulfillment == "shipping"
  end

  def status_label
    STATUS_LABELS.fetch(status, status.to_s.humanize)
  end

  def item_count
    items.sum(&:quantity)
  end

  def partially_refunded?
    refunded_cents.to_i.positive? && refunded_cents < total_cents
  end

  # Stripe's address hash, stored as JSON, as printable lines.
  def address_lines
    return [] if ship_address.blank?

    address = JSON.parse(ship_address)
    region = [ address["state"], address["postal_code"] ].compact_blank.join(" ")
    [ address["line1"], address["line2"], [ address["city"], region ].compact_blank.join(", "), address["country"] ].compact_blank
  rescue JSON::ParserError
    []
  end

  # From Stripe's charge.refunded: amount_refunded is the running total for
  # the charge, so it replaces rather than adds.
  def record_refund(amount_refunded:, amount:)
    changes = { refunded_cents: amount_refunded }
    changes[:status] = "refunded" if amount_refunded >= amount
    update(changes)
  end

  def validate
    super
    validates_includes STATUSES, :status
    validates_includes FULFILLMENTS, :fulfillment
    validates_presence [ :subtotal_cents, :total_cents ]
    validates_operator(:>=, 0, [ :subtotal_cents, :shipping_cents, :tax_cents, :total_cents, :refunded_cents ], allow_nil: true)
    validates_max_length MAX_TRACKING, :tracking_number, allow_nil: true
  end
end
```

`app/models/order_item.rb`:

```ruby
# One line of an order: a copy of the product, variant label and price at the
# moment of checkout. variant_id goes NULL if the variant is deleted later.
class OrderItem < Sequel::Model
  many_to_one :order
  many_to_one :variant, class: :ProductVariant

  plugin :validation_helpers

  def total_cents
    unit_price_cents * quantity
  end

  def validate
    super
    validates_presence [ :order_id, :product_name, :variant_label, :unit_price_cents, :quantity ]
    validates_operator(:>, 0, :quantity, allow_nil: true)
    validates_operator(:>=, 0, :unit_price_cents, allow_nil: true)
  end
end
```

`app/models/store_setting.rb`:

```ruby
# The shop's one row of settings: flat shipping rate, pickup text, and the
# sales tax switch. stripe_tax_rate_bps records which rate the stored Stripe
# tax rate was created for, because Stripe's tax rates cannot be edited.
class StoreSetting < Sequel::Model
  DEFAULT_SHIPPING_CENTS = 800
  DEFAULT_INSTRUCTIONS = "Pickup in McComb, MS. We'll reach out when it's ready.".freeze
  MAX_SHIPPING_CENTS = 10_000
  MAX_TAX_RATE_BPS = 1_500
  MAX_INSTRUCTIONS = 500

  plugin :boolean_readers

  def self.current
    order(:id).first || create(shipping_cents: DEFAULT_SHIPPING_CENTS, pickup_instructions: DEFAULT_INSTRUCTIONS)
  end

  # The Stripe tax rate checkout should charge, or nil while tax is off.
  def checkout_tax_rate_id
    stripe_tax_rate_id if tax_enabled? && tax_rate_bps
  end

  def before_save
    self.updated_at = Time.current
    super
  end

  def validate
    super
    unless shipping_cents && (0..MAX_SHIPPING_CENTS).cover?(shipping_cents)
      errors.add(:shipping_cents, "must be between $0.00 and $100.00")
    end

    if pickup_instructions.to_s.strip.empty?
      errors.add(:pickup_instructions, "can't be blank")
    elsif pickup_instructions.length > MAX_INSTRUCTIONS
      errors.add(:pickup_instructions, "must be #{MAX_INSTRUCTIONS} characters or fewer")
    end

    if tax_rate_bps.nil?
      errors.add(:tax_rate_bps, "is required while sales tax is on") if tax_enabled?
    elsif !(1..MAX_TAX_RATE_BPS).cover?(tax_rate_bps)
      errors.add(:tax_rate_bps, "must be between 0.01% and 15%")
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/order_test.rb test/models/store_setting_test.rb`
Expected: 13 runs, 0 failures, 0 errors.

- [ ] **Step 6: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add db/migrate/20261013200000_create_orders_and_store_settings.rb db/schema.rb app/models/order.rb app/models/order_item.rb app/models/store_setting.rb test/models/order_test.rb test/models/store_setting_test.rb test/test_helper.rb
git commit -m "Add orders, order items and store settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Tell the user: restart `bin/dev` before any browser check, because the migration added tables.

---

### Task 2: The Stripe gateway and its test double

**Files:**
- Modify: `Gemfile`, `Gemfile.lock` (`stripe ~> 20.0`)
- Create: `app/models/stripe_gateway.rb`
- Create: `test/support/fake_stripe_gateway.rb`
- Modify: `test/test_helper.rb` (require the fake, install it globally, add `stripe_signature` and `paid_session`)
- Modify: `config/deploy.yml`, `.kamal/secrets` (Stripe secrets)
- Test: `test/models/stripe_gateway_test.rb`

**Interfaces:**
- Consumes: `Order#stripe_session_id`, `#subtotal_cents`, `#id` (Task 1).
- Produces:
  - `StripeGateway` class level:
    - `StripeGateway.current` and `StripeGateway.current=`;
    - errors `StripeGateway::Error` and `StripeGateway::InvalidSignature`.
  - `StripeGateway` instance methods:
    - `#create_checkout_session(params) → object with #id, #url`;
    - `#retrieve_session(id) → Stripe::Checkout::Session`;
    - `#create_tax_rate(bps) → String id`;
    - `#construct_event(payload, signature) → Stripe::Event`.
  - `FakeStripeGateway`, with the same four methods plus:
    - `#sessions_created` (Array of params hashes), `#tax_rates_created` (Array of bps);
    - `#stub_session(id, **fields)`, `#fail_with=` (a message string, or nil);
    - `FakeStripeGateway::WEBHOOK_SECRET`.
  - Test helpers:
    - `stripe_signature(payload, secret: FakeStripeGateway::WEBHOOK_SECRET) → header String`;
    - `paid_session(order, email:, tax:, shipping:, address:, payment_intent:) → Hash` with symbol keys.

- [ ] **Step 1: Add the gem**

```bash
bundle add stripe --version "~> 20.0"
bundle exec ruby -e 'require "stripe"; puts Stripe::VERSION'
```

Expected: `20.x.y`.

- [ ] **Step 2: Write the failing tests**

`test/models/stripe_gateway_test.rb`:

```ruby
require "test_helper"

class StripeGatewayTest < ActiveSupport::TestCase
  SECRET = "whsec_gateway_test"

  def gateway
    StripeGateway.new(api_key: nil, webhook_secret: SECRET)
  end

  def event_payload(type)
    { id: "evt_1", object: "event", type: type, data: { object: { id: "cs_1", object: "checkout.session" } } }.to_json
  end

  test "a correctly signed payload becomes a Stripe event" do
    payload = event_payload("checkout.session.completed")
    event = gateway.construct_event(payload, stripe_signature(payload, secret: SECRET))

    assert_equal "checkout.session.completed", event.type
    assert_equal "cs_1", event.data.object.id
  end

  test "a wrong or missing signature is rejected" do
    payload = event_payload("checkout.session.completed")

    assert_raises(StripeGateway::InvalidSignature) { gateway.construct_event(payload, stripe_signature(payload, secret: "whsec_other")) }
    assert_raises(StripeGateway::InvalidSignature) { gateway.construct_event(payload, nil) }
  end

  test "without a webhook secret every event is rejected" do
    payload = event_payload("checkout.session.completed")
    unconfigured = StripeGateway.new(api_key: nil, webhook_secret: nil)

    assert_raises(StripeGateway::InvalidSignature) { unconfigured.construct_event(payload, stripe_signature(payload, secret: SECRET)) }
  end

  test "Stripe errors come back as StripeGateway::Error" do
    error = assert_raises(StripeGateway::Error) { gateway.create_tax_rate(700) }
    assert_match(/API key/i, error.message)
  end

  test "tests never reach the real gateway" do
    assert_kind_of FakeStripeGateway, StripeGateway.current
  end

  test "the fake records sessions and returns a Stripe-hosted url" do
    session = StripeGateway.current.create_checkout_session(mode: "payment")

    assert_equal [ { mode: "payment" } ], StripeGateway.current.sessions_created
    assert_match %r{\Ahttps://checkout\.stripe\.test/cs_test_}, session.url
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/models/stripe_gateway_test.rb`
Expected: the run aborts with `NameError: uninitialized constant FakeStripeGateway`, or with `stripe_signature` undefined.

- [ ] **Step 4: Write the gateway, the fake, and the helpers**

`app/models/stripe_gateway.rb`:

```ruby
# The only code that talks to Stripe. Everything else asks
# StripeGateway.current, which the test suite replaces with
# FakeStripeGateway so no test reaches the network.
class StripeGateway
  class Error < StandardError; end
  class InvalidSignature < StandardError; end

  class << self
    attr_writer :current

    def current
      @current ||= new
    end
  end

  def initialize(api_key: ENV["STRIPE_SECRET_KEY"], webhook_secret: ENV["STRIPE_WEBHOOK_SECRET"])
    @api_key = api_key
    @webhook_secret = webhook_secret
  end

  # Returns a Stripe::Checkout::Session; callers use #id and #url.
  def create_checkout_session(params)
    call { Stripe::Checkout::Session.create(params, request_options) }
  end

  def retrieve_session(id)
    call { Stripe::Checkout::Session.retrieve(id, request_options) }
  end

  # Stripe tax rates cannot be edited, so a new rate is a new object.
  # Returns its id.
  def create_tax_rate(bps)
    call do
      Stripe::TaxRate.create({
        display_name: "Sales tax", description: "Mississippi sales tax",
        jurisdiction: "MS", country: "US", state: "MS",
        percentage: bps / 100.0, inclusive: false, tax_type: "sales_tax"
      }, request_options).id
    end
  end

  # Checks the Stripe-Signature header and returns the Stripe::Event.
  def construct_event(payload, signature)
    raise InvalidSignature, "no webhook secret is configured" if @webhook_secret.blank?

    Stripe::Webhook.construct_event(payload, signature.to_s, @webhook_secret)
  rescue Stripe::SignatureVerificationError, JSON::ParserError => e
    raise InvalidSignature, e.message
  end

  private

  def request_options
    { api_key: @api_key }
  end

  def call
    yield
  rescue Stripe::StripeError => e
    raise Error, e.message
  end
end
```

`test/support/fake_stripe_gateway.rb`:

```ruby
# Stands in for StripeGateway in every test. It records what the app asked
# Stripe for, returns sessions with predictable shapes, and verifies webhook
# signatures with the real Stripe code and a known secret.
class FakeStripeGateway
  WEBHOOK_SECRET = "whsec_test_secret"

  attr_reader :sessions_created, :tax_rates_created
  attr_accessor :fail_with

  def initialize
    @sessions_created = []
    @tax_rates_created = []
    @sessions = {}
    @fail_with = nil
  end

  def create_checkout_session(params)
    fail_if_asked
    @sessions_created << params
    id = "cs_test_#{@sessions_created.size}_#{SecureRandom.hex(4)}"
    Stripe::Checkout::Session.construct_from(id: id, url: "https://checkout.stripe.test/#{id}")
  end

  def retrieve_session(id)
    fail_if_asked
    @sessions.fetch(id) { raise StripeGateway::Error, "No such checkout.session: '#{id}'" }
  end

  # Makes retrieve_session(id) return a session with these fields.
  def stub_session(id, **fields)
    @sessions[id] = Stripe::Checkout::Session.construct_from({ id: id }.merge(fields))
  end

  def create_tax_rate(bps)
    fail_if_asked
    @tax_rates_created << bps
    "txr_test_#{@tax_rates_created.size}"
  end

  def construct_event(payload, signature)
    StripeGateway.new(api_key: nil, webhook_secret: WEBHOOK_SECRET).construct_event(payload, signature)
  end

  private

  def fail_if_asked
    raise StripeGateway::Error, fail_with if fail_with
  end
end
```

In `test/test_helper.rb`, add `require_relative "support/fake_stripe_gateway"` directly after `require "minitest/mock"`.

Then, inside `class TestCase`, add the following directly after the existing account-cleanup `teardown do ... end` block:

```ruby
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
```

In `config/deploy.yml`, extend `env.secret`:

```yaml
  secret:
    - RAILS_MASTER_KEY
    - STRIPE_SECRET_KEY
    - STRIPE_WEBHOOK_SECRET
```

Append to `.kamal/secrets`:

```bash
# Stripe keys come from the deploying shell's environment.
STRIPE_SECRET_KEY=$STRIPE_SECRET_KEY
STRIPE_WEBHOOK_SECRET=$STRIPE_WEBHOOK_SECRET
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/stripe_gateway_test.rb test/models/order_test.rb`
Expected: 14 runs, 0 failures, 0 errors.

- [ ] **Step 6: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add Gemfile Gemfile.lock app/models/stripe_gateway.rb test/support/fake_stripe_gateway.rb test/test_helper.rb test/models/stripe_gateway_test.rb config/deploy.yml .kamal/secrets
git commit -m "Add the Stripe gateway and a fake for tests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The session cart

**Files:**
- Create: `app/models/cart.rb`
- Test: `test/models/cart_test.rb`

**Interfaces:**
- Consumes:
  - `ProductVariant#price_cents`, `#label`, `#sold_out?`, `#stock`, `#product`;
  - `Product#active?`, `#simple?`.
- Produces:
  - `Cart.new(session)`, where `session` is the Rails session or a plain Hash.
  - Reading the cart:
    - `#count → Integer`, `#empty?`;
    - `#lines → Array<Cart::Line>`, `#available_lines → Array<Cart::Line>`;
    - `#subtotal_cents(lines = available_lines) → Integer`.
  - Changing the cart:
    - `#add(variant_id, quantity) → Cart::Result`;
    - `#update(variant_id, quantity) → Cart::Result`;
    - `#remove(variant_id) → Cart::Result`;
    - `#reconcile(lines) → Array<String>` (one sentence per line it capped);
    - `#clear`.
  - `Cart::Line`: `variant`, `quantity`, `#product`, `#available?`, `#name`, `#unit_price_cents`, `#total_cents`.
  - `Cart::Result`: `ok` (Boolean) and `message` (String).
  - `Cart::MAX_QUANTITY = 99`.
  - The session key is `:cart`, holding `{ "variant id" => Integer }`.

- [ ] **Step 1: Write the failing tests**

`test/models/cart_test.rb`:

```ruby
require "test_helper"

class CartTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  setup do
    @session = {}
    @cart = Cart.new(@session)
    @tee = build_product(name: "Cart Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    @sticker = build_product(name: "Sticker", price: "4.00")
  end

  test "adding puts the variant in the session and counts it" do
    result = @cart.add(@small.id, 2)

    assert result.ok
    assert_equal "Added to your cart.", result.message
    assert_equal({ @small.id.to_s => 2 }, @session[:cart])
    assert_equal 2, @cart.count
  end

  test "adding more than the stock caps the quantity and says so" do
    @cart.add(@small.id, 2)
    result = @cart.add(@small.id, 5)

    assert result.ok
    assert_equal "Only 3 of Cart Tee — S available, so your cart has 3.", result.message
    assert_equal 3, @cart.count
  end

  test "unknown, unpublished and sold out variants are refused" do
    refute @cart.add(999_999_999, 1).ok
    refute @cart.add("abc", 1).ok

    @small.this.update(stock: 0)
    sold_out = @cart.add(@small.id, 1)
    refute sold_out.ok
    assert_equal "Cart Tee — S is sold out.", sold_out.message

    @sticker.update(active: false)
    refute @cart.add(@sticker.variants.first.id, 1).ok
    assert @cart.empty?
  end

  test "a quantity that is not a positive whole number is refused" do
    [ 0, -1, "1.5", "two", nil ].each do |quantity|
      refute @cart.add(@small.id, quantity).ok, "expected #{quantity.inspect} to be refused"
    end
    assert @cart.empty?
  end

  test "update changes the quantity, caps it at stock, and zero removes the line" do
    @cart.add(@small.id, 1)

    assert @cart.update(@small.id, 2).ok
    assert_equal 2, @cart.count

    capped = @cart.update(@small.id, 10)
    assert_equal 3, @cart.count
    assert_match(/Only 3/, capped.message)

    @cart.update(@small.id, 0)
    assert @cart.empty?
  end

  test "update refuses junk and items that are not in the cart" do
    refute @cart.update(@small.id, 1).ok
    @cart.add(@small.id, 1)
    refute @cart.update(@small.id, "lots").ok
    assert_equal 1, @cart.count
  end

  test "remove takes the line out" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)
    @cart.remove(@small.id)

    assert_equal [ @sticker.variants.first.id ], @cart.lines.map { |line| line.variant.id }
  end

  test "junk in the session is dropped instead of raising" do
    @session[:cart] = { "abc" => 1, @small.id.to_s => "2", "0" => 1, @sticker.variants.first.id.to_s => -4, "7" => nil }
    assert_equal 2, @cart.count
    assert_equal [ @small.id ], @cart.lines.map { |line| line.variant.id }

    @session[:cart] = "not a hash"
    assert_equal 0, @cart.count
    assert_equal [], @cart.lines
  end

  test "lines drop variants that were deleted" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)
    Product.where(id: @tee.id).delete

    assert_equal [ "Sticker" ], @cart.lines.map(&:name)
    assert_equal({ @sticker.variants.first.id.to_s => 1 }, @session[:cart])
  end

  test "a line that sold out or was unpublished stays, but is unavailable and not in the subtotal" do
    @cart.add(@small.id, 2)
    @cart.add(@sticker.variants.first.id, 1)
    @small.this.update(stock: 0)

    lines = @cart.lines
    refute lines.find { |line| line.variant.id == @small.id }.available?
    assert_equal 400, @cart.subtotal_cents
    assert_equal [ "Sticker" ], @cart.available_lines.map(&:name)
  end

  test "line names include the variant label except for simple products" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)

    assert_equal [ "Cart Tee — S", "Sticker" ], @cart.lines.map(&:name)
  end

  test "reconcile caps lines to the stock left and explains" do
    @cart.add(@small.id, 3)
    @small.this.update(stock: 1)

    messages = @cart.reconcile(@cart.lines)
    assert_equal [ "Only 1 of Cart Tee — S left, so your cart now has 1." ], messages
    assert_equal 1, @cart.count
  end

  test "clear empties the cart" do
    @cart.add(@small.id, 1)
    @cart.clear
    assert @cart.empty?
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/models/cart_test.rb`
Expected: errors with `NameError: uninitialized constant Cart`.

- [ ] **Step 3: Write the cart**

`app/models/cart.rb`:

```ruby
# The visitor's cart, kept in the Rails session as { "variant id" => quantity }
# so guests and signed-in customers work the same way and nothing is written
# to the database until checkout. Entries that are not a positive whole
# quantity of a numeric id, and variants that no longer exist, are dropped
# when the cart is read.
class Cart
  MAX_QUANTITY = 99
  ID = /\A[1-9]\d{0,17}\z/

  Line = Data.define(:variant, :quantity) do
    def product
      variant.product
    end

    # Sold out or unpublished since it was added: still listed, never bought.
    def available?
      product.active? && variant.stock.positive?
    end

    def name
      product.simple? ? product.name : "#{product.name} — #{variant.label}"
    end

    def unit_price_cents
      variant.price_cents
    end

    def total_cents
      unit_price_cents * quantity
    end
  end

  Result = Data.define(:ok, :message)

  def initialize(session)
    @session = session
  end

  def count
    entries.values.sum
  end

  def empty?
    entries.empty?
  end

  def lines
    current = entries
    variants = load_variants(current.keys).index_by { |variant| variant.id.to_s }
    kept = current.select { |id, _| variants.key?(id) }
    write(kept)
    kept.map { |id, quantity| Line.new(variant: variants.fetch(id), quantity: quantity) }
  end

  def available_lines
    lines.select(&:available?)
  end

  def subtotal_cents(lines = available_lines)
    lines.select(&:available?).sum(&:total_cents)
  end

  def add(variant_id, quantity)
    variant = load_variants([ variant_id ]).first
    return Result.new(ok: false, message: "That item is no longer available.") unless variant&.product&.active?
    return Result.new(ok: false, message: "#{describe(variant)} is sold out.") if variant.sold_out?

    wanted = whole(quantity)
    return Result.new(ok: false, message: "Choose a quantity of at least 1.") unless wanted&.positive?

    current = entries
    total = current[variant.id.to_s].to_i + wanted
    allowed = [ total, variant.stock, MAX_QUANTITY ].min
    write(current.merge(variant.id.to_s => allowed))
    return Result.new(ok: true, message: "Added to your cart.") if allowed == total

    Result.new(ok: true, message: "Only #{allowed} of #{describe(variant)} available, so your cart has #{allowed}.")
  end

  def update(variant_id, quantity)
    key = variant_id.to_s
    current = entries
    return Result.new(ok: false, message: "That item is not in your cart.") unless current.key?(key)

    wanted = whole(quantity)
    return Result.new(ok: false, message: "Quantity must be a whole number.") if wanted.nil? || wanted.negative?
    return remove(key) if wanted.zero?

    variant = load_variants([ key ]).first
    return remove(key) unless variant

    allowed = [ wanted, MAX_QUANTITY ].min
    # A sold-out line keeps whatever was asked; it is excluded at checkout.
    allowed = [ allowed, variant.stock ].min if variant.stock.positive?
    write(current.merge(key => allowed))
    return Result.new(ok: true, message: "Cart updated.") if allowed == wanted

    Result.new(ok: true, message: "Only #{allowed} of #{describe(variant)} available, so your cart has #{allowed}.")
  end

  def remove(variant_id)
    write(entries.except(variant_id.to_s))
    Result.new(ok: true, message: "Removed from your cart.")
  end

  # Caps each line at the stock left right now. Returns one sentence per line
  # it changed, for the buyer.
  def reconcile(lines)
    current = entries
    messages = lines.filter_map do |line|
      next if line.quantity <= line.variant.stock

      current[line.variant.id.to_s] = line.variant.stock
      "Only #{line.variant.stock} of #{line.name} left, so your cart now has #{line.variant.stock}."
    end
    write(current)
    messages
  end

  def clear
    @session.delete(:cart)
  end

  private

  def entries
    raw = @session[:cart]
    return {} unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(id, quantity), clean|
      key = id.to_s
      count = whole(quantity)
      clean[key] = [ count, MAX_QUANTITY ].min if key.match?(ID) && count&.positive?
    end
  end

  def write(entries)
    @session[:cart] = entries
  end

  def load_variants(ids)
    numeric = ids.map(&:to_s).grep(ID).map(&:to_i)
    return [] if numeric.empty?

    ProductVariant.where(id: numeric).eager(:option_values, product: :options).all
  end

  def whole(value)
    Integer(value.to_s.strip, 10, exception: false)
  end

  def describe(variant)
    Line.new(variant: variant, quantity: 1).name
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/cart_test.rb`
Expected: 13 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/models/cart.rb test/models/cart_test.rb
git commit -m "Add a session cart

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Cart pages, add to cart, and the nav count

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/carts_controller.rb`, `app/controllers/cart_items_controller.rb`
- Create: `app/views/carts/show.html.erb`
- Modify: `app/helpers/application_helper.rb` (`cart_count`)
- Modify: `app/views/layouts/partials/_navigation.html.erb` (cart link)
- Modify: `app/views/layouts/application.html.erb` (flash styling)
- Modify: `app/views/shop/show.html.erb` (add-to-cart form)
- Modify: `app/javascript/controllers/variant_picker_controller.js`
- Test: `test/integration/cart_pages_test.rb`

**Interfaces:**
- Consumes: `Cart` (Task 3), `StoreSetting.current`, `#checkout_tax_rate_id` (Task 1).
- Produces:
  - Routes:

    | Request | Route helper |
    |---|---|
    | `GET /cart` | `cart_path` |
    | `POST /cart/items` | `cart_items_path` |
    | `PATCH /cart/items/:variant_id` | `cart_item_path(id)` |
    | `DELETE /cart/items/:variant_id` | `cart_item_path(id)` |
    | `POST /checkout` | `checkout_path` |
    | `GET /orders/:token` | `order_path(token)` / `order_url(token)` |

    The checkout and order routes are only declared here. Their controllers arrive in Tasks 5 and 8.
  - Flash markup: `[data-flash=notice]` and `[data-flash=alert]`.
  - The cart page's checkout form posts `fulfillment` to `/checkout` with `data-turbo="false"`.
  - Helper: `cart_count`.

- [ ] **Step 1: Write the failing tests**

`test/integration/cart_pages_test.rb`:

```ruby
require "test_helper"

class CartPagesTest < ActionDispatch::IntegrationTest
  teardown do
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  setup do
    @tee = build_product(name: "Cart Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    @sticker = build_product(name: "Cart Sticker", price: "4.00")
  end

  def add(variant, quantity = 1, headers: {})
    post "/cart/items", params: { variant_id: variant.id, quantity: quantity }, headers: headers
  end

  test "an empty cart says so and offers no checkout" do
    get "/cart"
    assert_response :success
    assert_select "body", text: /Your cart is empty/
    assert_select "form[action='/checkout']", count: 0
  end

  test "adding an item goes to the cart, which lists it with the subtotal" do
    add(@small, 2)
    assert_redirected_to "/cart"
    follow_redirect!

    assert_select "[data-flash=notice]", text: "Added to your cart."
    assert_select "[data-cart-line='#{@small.id}']", text: /Cart Tee — S/
    assert_select "[data-subtotal]", text: "$40.00"
  end

  test "a simple product's line is just its name" do
    add(@sticker.variants.first)
    follow_redirect!

    assert_select "[data-cart-line] p.font-bold", text: "Cart Sticker"
  end

  test "the nav shows how many items are in the cart" do
    add(@small, 2)
    add(@sticker.variants.first)

    get "/"
    assert_select "nav a[href='/cart']", text: "Cart (3)"
  end

  test "adding a sold out item goes back to the product with a message" do
    @small.this.update(stock: 0)
    referer = "http://www.example.com/shop/#{@tee.slug}"

    add(@small, 1, headers: { "HTTP_REFERER" => referer })
    assert_redirected_to referer
    follow_redirect!
    assert_select "[data-flash=alert]", text: "Cart Tee — S is sold out."
  end

  test "updating a quantity changes the subtotal and zero empties the cart" do
    add(@small)

    patch "/cart/items/#{@small.id}", params: { quantity: 3 }
    follow_redirect!
    assert_select "[data-subtotal]", text: "$60.00"

    patch "/cart/items/#{@small.id}", params: { quantity: 0 }
    follow_redirect!
    assert_select "body", text: /Your cart is empty/
  end

  test "remove takes a line out" do
    add(@small)
    add(@sticker.variants.first)

    delete "/cart/items/#{@small.id}"
    follow_redirect!
    assert_select "[data-cart-line]", count: 1
    assert_select "[data-cart-line='#{@sticker.variants.first.id}']"
  end

  test "a line that sold out after it was added stays with a note and leaves the subtotal" do
    add(@small)
    add(@sticker.variants.first)
    @small.this.update(stock: 0)

    get "/cart"
    assert_select "[data-cart-line='#{@small.id}'][data-unavailable]", text: /No longer available/
    assert_select "[data-subtotal]", text: "$4.00"
  end

  test "delivery offers pickup with instructions and the flat shipping rate" do
    StoreSetting.current.update(shipping_cents: 650, pickup_instructions: "Come by the shop on Main.")
    add(@small)

    get "/cart"
    assert_select "form[action='/checkout'][data-turbo='false']" do
      assert_select "input[type=radio][name=fulfillment][value=pickup]"
      assert_select "input[type=radio][name=fulfillment][value=shipping]"
    end
    assert_select "body", text: /Come by the shop on Main\./
    assert_select "body", text: /Ship it — \$6\.50 flat/
  end

  test "the tax note appears only while tax is on" do
    add(@small)

    get "/cart"
    assert_select "[data-tax-note]", count: 0

    StoreSetting.current.update(tax_enabled: true, tax_rate_bps: 700, stripe_tax_rate_id: "txr_1", stripe_tax_rate_bps: 700)
    get "/cart"
    assert_select "[data-tax-note]", text: "Mississippi sales tax is added at checkout for MS addresses and pickups."
  end

  test "a simple product page has an add to cart form for its one variant" do
    get "/shop/#{@sticker.slug}"

    assert_select "form[action='/cart/items']" do
      assert_select "input[type=hidden][name=variant_id][value='#{@sticker.variants.first.id}']"
      assert_select "button", text: "Add to cart"
    end
    refute_selector_text "p", /Ordering online is not open yet/
  end

  test "a product page with options offers only the variants in stock" do
    variant_named(@tee, "M").this.update(stock: 0)

    get "/shop/#{@tee.slug}"
    values = css_select("form[action='/cart/items'] select[name=variant_id] option").map { |option| option["value"] }
    assert_equal [ "", @small.id.to_s ], values
  end

  test "a sold out product has no add to cart form" do
    @sticker.variants.first.this.update(stock: 0)

    get "/shop/#{@sticker.slug}"
    assert_select "form[action='/cart/items']", count: 0
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/cart_pages_test.rb`
Expected: failures and errors, including 404s for `/cart` and missing `form[action='/cart/items']`.

- [ ] **Step 3: Routes and controllers**

In `config/routes.rb`, add the following after the `get "shop/:slug"` line:

```ruby
  resource :cart, only: :show
  post   "cart/items"             => "cart_items#create",  as: :cart_items
  patch  "cart/items/:variant_id" => "cart_items#update",  as: :cart_item
  delete "cart/items/:variant_id" => "cart_items#destroy"
  post   "checkout"               => "checkouts#create",   as: :checkout
  get    "orders/:token"          => "orders#show",        as: :order
```

`app/controllers/carts_controller.rb`:

```ruby
class CartsController < ApplicationController
  def show
    cart = Cart.new(session)
    @lines = cart.lines
    @subtotal = cart.subtotal_cents(@lines)
    @settings = StoreSetting.current
  end
end
```

`app/controllers/cart_items_controller.rb`:

```ruby
class CartItemsController < ApplicationController
  def create
    result = cart.add(params[:variant_id], params.fetch(:quantity, 1))
    if result.ok
      redirect_to cart_path, notice: result.message
    else
      redirect_back_or_to shop_path, alert: result.message
    end
  end

  def update
    result = cart.update(params[:variant_id], params[:quantity])
    redirect_to cart_path, flash: { (result.ok ? :notice : :alert) => result.message }
  end

  def destroy
    redirect_to cart_path, notice: cart.remove(params[:variant_id]).message
  end

  private

  def cart
    @cart ||= Cart.new(session)
  end
end
```

- [ ] **Step 4: Views, nav, and flash**

`app/views/carts/show.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "YOUR", heading_bottom: "CART." %>

  <section class="max-w-4xl mx-auto px-6 py-12 space-y-8">
    <% if @lines.empty? %>
      <%= render "shared/empty_state", message: "Your cart is empty.", cta_label: "Shop", cta_path: shop_path %>
    <% else %>
      <%= render layout: "shared/panel", locals: { title: "Items" } do %>
        <ul class="divide-y divide-gray-200">
          <% @lines.each do |line| %>
            <li class="py-4 flex flex-wrap items-center gap-4" data-cart-line="<%= line.variant.id %>" <%= "data-unavailable" unless line.available? %>>
              <div class="w-16 h-16 flex-shrink-0 rounded bg-gray-100 overflow-hidden">
                <%= product_image_tag line.product, alt: "", class: "w-full h-full object-cover" %>
              </div>
              <div class="min-w-0 flex-1">
                <p class="font-bold"><%= line.name %></p>
                <p class="text-sm text-gray-600"><%= price(line.unit_price_cents) %> each</p>
                <% unless line.available? %>
                  <p class="mt-1 text-xs font-bold uppercase tracking-widest text-brand-orange">No longer available. It won't be included at checkout.</p>
                <% end %>
              </div>
              <%= form_with url: cart_item_path(line.variant.id), method: :patch, class: "flex items-center gap-2" do %>
                <label for="quantity_<%= line.variant.id %>" class="sr-only">Quantity of <%= line.name %></label>
                <input id="quantity_<%= line.variant.id %>" type="number" name="quantity" min="0" max="<%= Cart::MAX_QUANTITY %>" value="<%= line.quantity %>"
                       class="w-20 px-2 py-1 text-sm text-ink bg-white border-2 border-gray-300 rounded-md">
                <button type="submit" class="text-xs font-bold uppercase tracking-widest text-brand-green">Update</button>
              <% end %>
              <%= button_to "Remove", cart_item_path(line.variant.id), method: :delete,
                    class: "text-xs font-bold uppercase tracking-widest text-gray-500 hover:text-brand-orange" %>
              <p class="w-24 text-right font-bold"><%= line.available? ? price(line.total_cents) : "—" %></p>
            </li>
          <% end %>
        </ul>
        <p class="mt-6 flex justify-between border-t-2 border-gray-200 pt-4 font-bold">
          <span>Subtotal</span><span data-subtotal><%= price(@subtotal) %></span>
        </p>
      <% end %>

      <% if @lines.any?(&:available?) %>
        <%# Turbo cannot follow a redirect to another origin, and checkout redirects to Stripe. %>
        <%= form_with url: checkout_path, data: { turbo: false } do %>
          <%= render layout: "shared/panel", locals: { title: "Delivery" } do %>
            <fieldset class="space-y-4">
              <legend class="sr-only">Pickup or shipping</legend>
              <label class="flex items-start gap-3">
                <input type="radio" name="fulfillment" value="pickup" required class="mt-1 accent-brand-green">
                <span>
                  <span class="font-bold">Pickup in McComb — Free</span>
                  <span class="block text-sm text-gray-600"><%= @settings.pickup_instructions %></span>
                </span>
              </label>
              <label class="flex items-start gap-3">
                <input type="radio" name="fulfillment" value="shipping" required class="mt-1 accent-brand-green">
                <span class="font-bold">Ship it — <%= price(@settings.shipping_cents) %> flat</span>
              </label>
            </fieldset>
            <% if @settings.checkout_tax_rate_id %>
              <p class="mt-4 text-sm text-gray-600" data-tax-note>Mississippi sales tax is added at checkout for MS addresses and pickups.</p>
            <% end %>
            <button type="submit"
                    class="mt-6 inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">
              Checkout <span aria-hidden="true">&rarr;</span>
            </button>
          <% end %>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

In `app/helpers/application_helper.rb`, add the following after `price`:

```ruby
  # Items in the visitor's cart, for the nav. Reads the session only.
  def cart_count
    Cart.new(session).count
  end
```

In `app/views/layouts/partials/_navigation.html.erb`, add the cart link after the Contact link in **both** places it appears:
- in the desktop list: `<span><%= link_to "Cart (#{cart_count})", cart_path %></span>`
- in the mobile menu: `<span class="block py-2 border-b border-white/10"><%= link_to "Cart (#{cart_count})", cart_path %></span>`

In `app/views/layouts/application.html.erb`, replace the two flash blocks with:

```erb
    <% if notice %>
      <div class="bg-brand-green text-white text-sm font-bold text-center px-6 py-3" role="status" data-flash="notice"><%= notice %></div>
    <% end %>
    <% if alert %>
      <div class="bg-brand-orange text-white text-sm font-bold text-center px-6 py-3" role="alert" data-flash="alert"><%= alert %></div>
    <% end %>
```

In `app/views/shop/show.html.erb`, replace the line `<p class="mt-8 text-xs text-gray-500">Ordering online is not open yet — get in touch for a quote.</p>` with:

```erb
      <% if @product.in_stock? %>
        <%= form_with url: cart_items_path, class: "mt-8 space-y-4" do %>
          <% if @product.simple? %>
            <input type="hidden" name="variant_id" value="<%= @product.variants.first.id %>">
          <% else %>
            <%# Without JavaScript this select is the picker; with it, the picker fills it in. %>
            <div data-variant-picker-target="choice">
              <label for="variant_id" class="text-xs font-bold uppercase tracking-widest text-gray-500">Choose</label>
              <select id="variant_id" name="variant_id" required data-variant-picker-target="select"
                      class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md">
                <option value="">Choose an option</option>
                <% @product.variants.reject(&:sold_out?).each do |variant| %>
                  <option value="<%= variant.id %>"><%= variant.label %> — <%= price(variant.price_cents) %></option>
                <% end %>
              </select>
            </div>
          <% end %>
          <div class="flex items-end gap-4">
            <div>
              <label for="quantity" class="text-xs font-bold uppercase tracking-widest text-gray-500">Quantity</label>
              <input id="quantity" type="number" name="quantity" value="1" min="1" max="<%= Cart::MAX_QUANTITY %>"
                     class="mt-2 w-20 px-2 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md">
            </div>
            <button type="submit" data-variant-picker-target="submit"
                    class="inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark disabled:opacity-50 text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">Add to cart</button>
          </div>
        <% end %>
      <% end %>
```

In `app/javascript/controllers/variant_picker_controller.js`:
- Extend `static targets` to `["list", "picker", "button", "fixed", "price", "status", "image", "choice", "select", "submit"]`.
- At the end of `connect()`, before `this.render()`, add:
  ```js
      if (this.hasChoiceTarget) this.choiceTarget.classList.add("hidden")
  ```
- At the end of `render()`, after `this.showImage()`, add:
  ```js
      // The add-to-cart form posts the select; the buttons choose for it.
      if (this.hasSelectTarget) {
        const buyable = Boolean(variant && variant.stock > 0)
        this.selectTarget.value = buyable ? String(variant.id) : ""
        if (this.hasSubmitTarget) this.submitTarget.disabled = !buyable
      }
  ```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/integration/cart_pages_test.rb test/integration/shop_test.rb test/integration/stimulus_controllers_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 6: Full suite, lint, commit**

Run the full suite in the background (`bin/rails test test/ > <workspace>/suite.log 2>&1`, ~400s), with nothing else touching the test database until it finishes. Then:

```bash
bin/rubocop && bin/brakeman --no-pager
git add config/routes.rb app/controllers/carts_controller.rb app/controllers/cart_items_controller.rb app/views/carts app/helpers/application_helper.rb app/views/layouts app/views/shop/show.html.erb app/javascript/controllers/variant_picker_controller.js test/integration/cart_pages_test.rb
git commit -m "Add the cart page, add to cart, and the nav cart count

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: suite 0 failures, 0 errors.

---

### Task 5: Starting checkout

**Files:**
- Create: `app/models/checkout.rb`
- Create: `app/controllers/checkouts_controller.rb`
- Test: `test/integration/checkout_test.rb`

**Interfaces:**
- Consumes:
  - `Cart#available_lines`, `#reconcile`, `Cart::Line` (Task 3);
  - `Order`, `OrderItem`, `StoreSetting#checkout_tax_rate_id` (Task 1);
  - `StripeGateway.current.create_checkout_session` (Task 2);
  - the `order_url(token)` and `cart_url` routes (Task 4).
- Produces:
  - `Checkout.new(lines:, fulfillment:, account:, success_url:, cancel_url:, settings: StoreSetting.current, gateway: StripeGateway.current)`. `success_url` is a lambda taking the Order.
  - `#start → Checkout::Result(url:, error:, order:)`.
  - `Checkout::UNAVAILABLE`.
  - `session[:checkout_order_id]`, set to the new order's id on success.

- [ ] **Step 1: Write the failing tests**

`test/integration/checkout_test.rb`:

```ruby
require "test_helper"

class CheckoutTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  setup do
    @tee = build_product(name: "Check Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    StoreSetting.current.update(shipping_cents: 800)
  end

  def stripe
    StripeGateway.current
  end

  def add(variant, quantity = 1)
    post "/cart/items", params: { variant_id: variant.id, quantity: quantity }
  end

  def checkout(fulfillment)
    post "/checkout", params: { fulfillment: fulfillment }
  end

  def tax_on
    StoreSetting.current.update(tax_enabled: true, tax_rate_bps: 700, stripe_tax_rate_id: "txr_ms", stripe_tax_rate_bps: 700)
  end

  test "a pickup checkout saves a pending order and sends the buyer to Stripe" do
    add(@small, 2)
    checkout("pickup")

    order = Order.order(:id).last
    assert_response :see_other
    assert_equal "https://checkout.stripe.test/#{order.stripe_session_id}", response.location

    assert_equal [ "pending", "pickup", 4000, 0, 4000 ],
      [ order.status, order.fulfillment, order.subtotal_cents, order.shipping_cents, order.total_cents ]
    item = order.items.first
    assert_equal [ "Check Tee", "S", 2000, 2, @small.id ],
      [ item.product_name, item.variant_label, item.unit_price_cents, item.quantity, item.variant_id ]
  end

  test "the pickup session asks Stripe for the right things" do
    add(@small, 2)
    checkout("pickup")
    order = Order.order(:id).last
    params = stripe.sessions_created.last

    assert_equal "payment", params[:mode]
    assert_equal [ "card" ], params[:payment_method_types]
    assert_equal [ { quantity: 2, price_data: { currency: "usd", unit_amount: 2000, product_data: { name: "Check Tee — S" } } } ],
      params[:line_items]
    assert_equal({ order_id: order.id.to_s }, params[:metadata])
    assert_equal order.number, params[:client_reference_id]
    assert_equal "http://www.example.com/orders/#{order.token}", params[:success_url]
    assert_equal "http://www.example.com/cart", params[:cancel_url]
    assert_in_delta 31.minutes.from_now.to_i, params[:expires_at], 60
    refute params.key?(:shipping_address_collection)
    refute params.key?(:shipping_options)
    refute params.key?(:customer_email)
  end

  test "a shipping checkout collects a US address and charges the flat rate" do
    add(@small)
    checkout("shipping")
    order = Order.order(:id).last
    params = stripe.sessions_created.last

    assert_equal({ allowed_countries: [ "US" ] }, params[:shipping_address_collection])
    assert_equal [ { shipping_rate_data: { type: "fixed_amount", display_name: "Flat rate shipping",
                                            fixed_amount: { amount: 800, currency: "usd" } } } ],
      params[:shipping_options]
    assert_equal [ 800, 2800 ], [ order.shipping_cents, order.total_cents ]
  end

  test "with tax on, shipping orders use a dynamic rate and pickups a fixed one" do
    tax_on
    add(@small)

    checkout("shipping")
    shipping_line = stripe.sessions_created.last[:line_items].first
    assert_equal [ "txr_ms" ], shipping_line[:dynamic_tax_rates]
    refute shipping_line.key?(:tax_rates)
    assert_equal 700, Order.order(:id).last.tax_rate_bps

    checkout("pickup")
    pickup_line = stripe.sessions_created.last[:line_items].first
    assert_equal [ "txr_ms" ], pickup_line[:tax_rates]
    refute pickup_line.key?(:dynamic_tax_rates)
  end

  test "with tax off, no tax rate is sent even if one is stored" do
    StoreSetting.current.update(tax_enabled: false, tax_rate_bps: 700, stripe_tax_rate_id: "txr_ms", stripe_tax_rate_bps: 700)
    add(@small)
    checkout("pickup")

    line = stripe.sessions_created.last[:line_items].first
    refute line.key?(:tax_rates)
    refute line.key?(:dynamic_tax_rates)
    assert_nil Order.order(:id).last.tax_rate_bps
  end

  test "a signed in buyer's email is filled in and the order is theirs" do
    account = create_account
    sign_in account
    add(@small)
    checkout("pickup")

    assert_equal account.email, stripe.sessions_created.last[:customer_email]
    assert_equal account.id, Order.order(:id).last.account_id
  end

  test "an empty cart or an unknown delivery choice makes no order" do
    assert_no_difference -> { Order.count } do
      checkout("pickup")
      assert_redirected_to "/cart"
      assert_equal "Your cart is empty.", flash[:alert]

      add(@small)
      checkout("drone")
      assert_redirected_to "/cart"
      assert_equal "Choose pickup or shipping.", flash[:alert]
    end
    assert_empty stripe.sessions_created
  end

  test "stock that ran out since the cart was filled sends the buyer back with the cart fixed" do
    add(@small, 3)
    @small.this.update(stock: 1)

    assert_no_difference -> { Order.count } do
      checkout("pickup")
    end
    assert_redirected_to "/cart"
    assert_equal "Only 1 of Check Tee — S left, so your cart now has 1.", flash[:alert]
    assert_equal({ @small.id.to_s => 1 }, session[:cart])
  end

  test "a sold out line is left out and the rest is checked out" do
    sticker = build_product(name: "Check Sticker", price: "4.00")
    add(@small)
    add(sticker.variants.first)
    sticker.variants.first.this.update(stock: 0)

    checkout("pickup")
    assert_equal [ "Check Tee" ], Order.order(:id).last.items.map(&:product_name)
  end

  test "when Stripe fails, no order is left behind and the buyer is told" do
    stripe.fail_with = "Stripe is down"
    add(@small)

    assert_no_difference -> { Order.count } do
      checkout("pickup")
    end
    assert_redirected_to "/cart"
    assert_equal "Checkout is unavailable right now, try again shortly.", flash[:alert]
  end

  test "the session remembers which order this browser checked out" do
    add(@small)
    checkout("pickup")
    assert_equal Order.order(:id).last.id, session[:checkout_order_id]
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/checkout_test.rb`
Expected: errors with `uninitialized constant CheckoutsController`, or routing errors.

- [ ] **Step 3: Write `Checkout` and the controller**

`app/models/checkout.rb`:

```ruby
# Starts a purchase: snapshots the cart lines into a pending order and opens
# a Stripe Checkout Session for it. Stock is checked by the caller but not
# held; OrderFulfiller flags the rare order that loses a race for the last unit.
class Checkout
  Result = Data.define(:url, :error, :order)
  UNAVAILABLE = "Checkout is unavailable right now, try again shortly.".freeze
  # Stripe refuses an expiry under 30 minutes away; exactly 30 races the clock.
  SESSION_LIFETIME = 31.minutes

  def initialize(lines:, fulfillment:, account:, success_url:, cancel_url:,
                 settings: StoreSetting.current, gateway: StripeGateway.current)
    @lines = lines
    @fulfillment = fulfillment
    @account = account
    @success_url = success_url
    @cancel_url = cancel_url
    @settings = settings
    @gateway = gateway
  end

  def start
    order = create_order
    session = @gateway.create_checkout_session(session_params(order))
    order.update(stripe_session_id: session.id)
    Result.new(url: session.url, error: nil, order: order)
  rescue StripeGateway::Error => e
    Rails.logger.warn("checkout failed for #{order&.number}: #{e.message}")
    order&.destroy
    Result.new(url: nil, error: UNAVAILABLE, order: nil)
  end

  private

  def create_order
    Order.db.transaction do
      order = Order.create(
        account_id: @account&.id, fulfillment: @fulfillment,
        subtotal_cents: subtotal, shipping_cents: shipping_cents,
        tax_rate_bps: (@settings.tax_rate_bps if tax_rate_id),
        total_cents: subtotal + shipping_cents
      )
      @lines.each do |line|
        OrderItem.create(
          order_id: order.id, variant_id: line.variant.id, product_name: line.product.name,
          variant_label: line.variant.label, sku: line.variant.sku,
          unit_price_cents: line.unit_price_cents, quantity: line.quantity
        )
      end
      order
    end
  end

  def session_params(order)
    params = {
      mode: "payment",
      payment_method_types: [ "card" ],
      line_items: @lines.map { |line| line_item(line) },
      metadata: { order_id: order.id.to_s },
      client_reference_id: order.number,
      expires_at: SESSION_LIFETIME.from_now.to_i,
      success_url: @success_url.call(order),
      cancel_url: @cancel_url
    }
    params[:customer_email] = @account.email if @account
    if shipping?
      params[:shipping_address_collection] = { allowed_countries: [ "US" ] }
      params[:shipping_options] = [ {
        shipping_rate_data: { type: "fixed_amount", display_name: "Flat rate shipping",
                              fixed_amount: { amount: shipping_cents, currency: "usd" } }
      } ]
    end
    params
  end

  # Shipping orders get the Mississippi rate as a dynamic rate, which Stripe
  # applies only to MS addresses; pickups happen in Mississippi, so always.
  # Tax applies to items only: manual rates cannot be attached to shipping.
  def line_item(line)
    item = { quantity: line.quantity,
             price_data: { currency: "usd", unit_amount: line.unit_price_cents, product_data: { name: line.name } } }
    item[shipping? ? :dynamic_tax_rates : :tax_rates] = [ tax_rate_id ] if tax_rate_id
    item
  end

  def subtotal
    @lines.sum(&:total_cents)
  end

  def shipping?
    @fulfillment == "shipping"
  end

  def shipping_cents
    shipping? ? @settings.shipping_cents : 0
  end

  def tax_rate_id
    @settings.checkout_tax_rate_id
  end
end
```

`app/controllers/checkouts_controller.rb`:

```ruby
class CheckoutsController < ApplicationController
  def create
    cart = Cart.new(session)
    lines = cart.available_lines
    fulfillment = params[:fulfillment].to_s

    return redirect_to(cart_path, alert: "Your cart is empty.") if lines.empty?
    return redirect_to(cart_path, alert: "Choose pickup or shipping.") unless Order::FULFILLMENTS.include?(fulfillment)

    changes = cart.reconcile(lines)
    return redirect_to(cart_path, alert: changes.join(" ")) if changes.any?

    result = Checkout.new(
      lines: lines, fulfillment: fulfillment, account: current_account,
      success_url: ->(order) { order_url(order.token) }, cancel_url: cart_url
    ).start
    return redirect_to(cart_path, alert: result.error) if result.error

    # The success page clears the cart only for this order (see OrdersController).
    session[:checkout_order_id] = result.order.id
    redirect_to result.url, allow_other_host: true, status: :see_other
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/checkout_test.rb`
Expected: 11 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/models/checkout.rb app/controllers/checkouts_controller.rb test/integration/checkout_test.rb
git commit -m "Start checkout: save a pending order and open a Stripe session

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Fulfilling a paid order

**Files:**
- Create: `app/models/order_fulfiller.rb`
- Test: `test/models/order_fulfiller_test.rb`

**Interfaces:**
- Consumes:
  - `Order#pending?`, `#items` (Task 1);
  - `ProductVariant#stock`;
  - the `paid_session` test helper (Task 2).
- Produces: `OrderFulfiller.new(order, session).call → true` when this call marked the order paid, otherwise `false`.
  - `session` is anything that responds to `to_hash`: a `Stripe::Checkout::Session` or a Hash.
  - On success the caller's `order` is refreshed.

- [ ] **Step 1: Write the failing tests**

`test/models/order_fulfiller_test.rb`:

```ruby
require "test_helper"

class OrderFulfillerTest < ActiveSupport::TestCase
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  setup do
    @tee = build_product(name: "Paid Tee", options: { "Size" => %w[S M] }, stock: 5)
    @small = variant_named(@tee, "S")
    @order = build_order(status: "pending", fulfillment: "shipping", stripe_session_id: "cs_test_paid",
                         items: [ { name: "Paid Tee", label: "S", price: 1200, quantity: 2, variant_id: @small.id } ])
  end

  test "a paid session marks the order paid and copies what Stripe collected" do
    address = { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }
    session = paid_session(@order, email: "pat@example.test", tax: 168, shipping: 800, address: address, payment_intent: "pi_123")

    assert OrderFulfiller.new(@order, session).call
    assert_equal "paid", @order.status
    assert_equal "pat@example.test", @order.email
    assert_equal "Pat Buyer", @order.ship_name
    assert_equal [ "1 Main St", "McComb, MS 39648", "US" ], @order.address_lines
    assert_equal [ 168, 800, 2400 + 800 + 168 ], [ @order.tax_cents, @order.shipping_cents, @order.total_cents ]
    assert_equal "pi_123", @order.stripe_payment_intent_id
    assert @order.paid_at
  end

  test "payment takes the stock" do
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal 3, @small.refresh.stock
    refute @order.oversold?
  end

  test "a second call changes nothing" do
    OrderFulfiller.new(@order, paid_session(@order)).call
    refute OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal 3, @small.refresh.stock
  end

  test "not enough stock still takes the order, floors stock at zero and flags it" do
    @small.this.update(stock: 1)
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal "paid", @order.status
    assert_equal 0, @small.refresh.stock
    assert @order.oversold?
  end

  test "a variant deleted since checkout flags the order" do
    Product.where(id: @tee.id).delete
    OrderFulfiller.new(@order, paid_session(@order)).call

    assert_equal "paid", @order.status
    assert @order.oversold?
  end

  test "an unpaid session changes nothing" do
    session = paid_session(@order).merge(payment_status: "unpaid")

    refute OrderFulfiller.new(@order, session).call
    assert_equal "pending", @order.refresh.status
    assert_equal 5, @small.refresh.stock
  end

  test "an order that is no longer pending is left alone" do
    @order.update(status: "cancelled")

    refute OrderFulfiller.new(@order, paid_session(@order)).call
    assert_equal "cancelled", @order.refresh.status
    assert_equal 5, @small.refresh.stock
  end

  test "a Stripe session object works as well as a hash" do
    session = Stripe::Checkout::Session.construct_from(paid_session(@order))

    assert OrderFulfiller.new(@order, session).call
    assert_equal "paid", @order.status
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/models/order_fulfiller_test.rb`
Expected: errors with `uninitialized constant OrderFulfiller`.

- [ ] **Step 3: Write the fulfiller**

`app/models/order_fulfiller.rb`:

```ruby
# Turns a paid Stripe Checkout Session into a paid order: copies what Stripe
# collected, takes the stock, and flags the order when there was not enough.
# Safe to call any number of times: only the first call on a pending order
# changes anything. The webhook and the success page both call it, and
# whichever arrives first does the work.
class OrderFulfiller
  def initialize(order, session)
    @order = order
    @session = session.to_hash.deep_symbolize_keys
  end

  # True when this call marked the order paid.
  def call
    return false unless @session[:payment_status] == "paid"

    fulfilled = Order.db.transaction do
      order = Order.where(id: @order.id).for_update.first
      next false unless order&.pending?

      order.update(paid_fields(order))
      short = order.items.map { |item| take_stock(item) }.include?(false)
      order.update(oversold: true) if short
      true
    end
    @order.refresh if fulfilled
    fulfilled
  end

  private

  def paid_fields(order)
    shipping = @session.dig(:collected_information, :shipping_details) || @session[:shipping_details]
    {
      status: "paid",
      email: @session.dig(:customer_details, :email),
      ship_name: shipping&.dig(:name),
      ship_address: shipping&.dig(:address)&.to_json,
      tax_cents: @session.dig(:total_details, :amount_tax).to_i,
      shipping_cents: @session.dig(:total_details, :amount_shipping).to_i,
      total_cents: @session[:amount_total] || order.total_cents,
      stripe_payment_intent_id: @session[:payment_intent],
      paid_at: Time.current
    }
  end

  # Takes the item's quantity from its variant, never below zero. False when
  # there was not enough to cover it or the variant no longer exists.
  def take_stock(item)
    variant = item.variant_id && ProductVariant.where(id: item.variant_id).for_update.first
    return false unless variant

    enough = variant.stock >= item.quantity
    variant.this.update(stock: [ variant.stock - item.quantity, 0 ].max)
    enough
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/order_fulfiller_test.rb`
Expected: 8 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/models/order_fulfiller.rb test/models/order_fulfiller_test.rb
git commit -m "Mark orders paid and take stock when Stripe confirms payment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The Stripe webhook

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/stripe_webhooks_controller.rb`
- Test: `test/integration/stripe_webhooks_test.rb`

**Interfaces:**
- Consumes:
  - `StripeGateway.current.construct_event`, `StripeGateway::InvalidSignature`, and the `stripe_signature` / `paid_session` helpers (Task 2);
  - `OrderFulfiller` (Task 6);
  - `Order#record_refund`, `#pending?` (Task 1).
- Produces: `POST /stripe/webhooks` (`stripe_webhooks_path`), which responds:
  - **200** for every event it accepted, including unknown ones;
  - **400** for a bad signature.

- [ ] **Step 1: Write the failing tests**

`test/integration/stripe_webhooks_test.rb`:

```ruby
require "test_helper"

class StripeWebhooksTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
  end

  setup do
    @tee = build_product(name: "Hook Tee", options: { "Size" => %w[S M] }, stock: 5)
    @small = variant_named(@tee, "S")
    @order = build_order(status: "pending", stripe_session_id: "cs_test_hook",
                         items: [ { name: "Hook Tee", label: "S", price: 1200, quantity: 2, variant_id: @small.id } ])
  end

  def deliver(type, object, signature: nil)
    payload = { id: "evt_#{SecureRandom.hex(4)}", object: "event", type: type, data: { object: object } }.to_json
    post "/stripe/webhooks", params: payload, headers: {
      "Content-Type" => "application/json",
      "User-Agent" => "Stripe/1.0 (+https://stripe.com/docs/webhooks)",
      "Stripe-Signature" => signature || stripe_signature(payload)
    }
  end

  def charge(payment_intent:, amount:, amount_refunded:)
    { id: "ch_1", object: "charge", payment_intent: payment_intent, amount: amount, amount_refunded: amount_refunded }
  end

  test "a completed session marks the order paid and takes stock" do
    deliver("checkout.session.completed", paid_session(@order))

    assert_response :ok
    assert_equal "paid", @order.refresh.status
    assert_equal 3, @small.refresh.stock
  end

  test "a repeated delivery takes stock once" do
    session = paid_session(@order)
    2.times { deliver("checkout.session.completed", session) }

    assert_response :ok
    assert_equal 3, @small.refresh.stock
  end

  test "a session whose id does not match the order's is ignored" do
    deliver("checkout.session.completed", paid_session(@order).merge(id: "cs_test_other"))

    assert_response :ok
    assert_equal "pending", @order.refresh.status
  end

  test "an expired session deletes the pending order, but never a paid one" do
    deliver("checkout.session.expired", { id: "cs_test_hook", object: "checkout.session", metadata: { order_id: @order.id.to_s } })
    assert_response :ok
    assert_nil Order[@order.id]

    paid = build_order(status: "paid", stripe_session_id: "cs_test_paid_already")
    deliver("checkout.session.expired", { id: "cs_test_paid_already", object: "checkout.session", metadata: { order_id: paid.id.to_s } })
    assert Order[paid.id]
  end

  test "a full refund marks the order refunded and leaves stock alone" do
    @order.update(status: "shipped", stripe_payment_intent_id: "pi_full")
    deliver("charge.refunded", charge(payment_intent: "pi_full", amount: @order.total_cents, amount_refunded: @order.total_cents))

    assert_response :ok
    @order.refresh
    assert_equal "refunded", @order.status
    assert_equal @order.total_cents, @order.refunded_cents
    assert_equal 5, @small.refresh.stock
  end

  test "a partial refund records the amount and keeps the status" do
    @order.update(status: "shipped", stripe_payment_intent_id: "pi_part")
    deliver("charge.refunded", charge(payment_intent: "pi_part", amount: @order.total_cents, amount_refunded: 500))

    @order.refresh
    assert_equal "shipped", @order.status
    assert_equal 500, @order.refunded_cents
  end

  test "a refund with no payment intent changes nothing" do
    deliver("charge.refunded", charge(payment_intent: nil, amount: 2400, amount_refunded: 2400))

    assert_response :ok
    @order.refresh
    assert_equal "pending", @order.status
    assert_equal 0, @order.refunded_cents
  end

  test "a bad or missing signature is refused" do
    deliver("checkout.session.completed", paid_session(@order), signature: "t=1,v1=nope")
    assert_response :bad_request

    post "/stripe/webhooks", params: "{}", headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    assert_equal "pending", @order.refresh.status
  end

  test "events the shop does not handle are acknowledged" do
    deliver("customer.created", { id: "cus_1", object: "customer" })
    assert_response :ok
  end

  test "the endpoint needs no CSRF token, because Stripe never has one" do
    ActionController::Base.allow_forgery_protection = true
    deliver("customer.created", { id: "cus_1", object: "customer" })
    assert_response :ok
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/stripe_webhooks_test.rb`
Expected: failures with 404 responses (no route).

- [ ] **Step 3: Route and controller**

In `config/routes.rb`, add after the `get "orders/:token"` line:

```ruby
  post "stripe/webhooks" => "stripe_webhooks#create", as: :stripe_webhooks
```

`app/controllers/stripe_webhooks_controller.rb`:

```ruby
# Stripe's calls back to the shop. Stripe is not a browser and sends no CSRF
# token or session, so this skips ApplicationController entirely; the
# signature check is the authentication. Anything that raises while handling
# an event returns 500, and Stripe retries the delivery.
class StripeWebhooksController < ActionController::API
  def create
    event = StripeGateway.current.construct_event(request.raw_post, request.headers["Stripe-Signature"])
    handle(event.type, event.data.object.to_hash.deep_symbolize_keys)
    head :ok
  rescue StripeGateway::InvalidSignature
    head :bad_request
  end

  private

  def handle(type, object)
    case type
    when "checkout.session.completed"
      order = order_for(object)
      OrderFulfiller.new(order, object).call if order
    when "checkout.session.expired"
      order = order_for(object)
      order.destroy if order&.pending?
    when "charge.refunded"
      # A blank intent would match every order without one (IS NULL).
      return if object[:payment_intent].blank?

      Order.first(stripe_payment_intent_id: object[:payment_intent].to_s)
        &.record_refund(amount_refunded: object[:amount_refunded].to_i, amount: object[:amount].to_i)
    end
  end

  # Both the metadata id and the session id must match, so a session can
  # only ever settle the order it was created for.
  def order_for(session)
    id = session.dig(:metadata, :order_id).to_s
    return nil unless id.match?(/\A\d+\z/)

    Order.first(id: id.to_i, stripe_session_id: session[:id].to_s)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/stripe_webhooks_test.rb`
Expected: 10 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add config/routes.rb app/controllers/stripe_webhooks_controller.rb test/integration/stripe_webhooks_test.rb
git commit -m "Handle Stripe's checkout and refund webhooks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The customer's order page

**Files:**
- Create: `app/controllers/orders_controller.rb`
- Create: `app/helpers/orders_helper.rb`
- Create: `app/views/orders/show.html.erb`, `app/views/orders/_items.html.erb`, `app/views/orders/_totals.html.erb`
- Test: `test/integration/order_page_test.rb`

**Interfaces:**
- Consumes:
  - `Order` (Task 1), `OrderFulfiller` (Task 6);
  - `StripeGateway.current.retrieve_session`, `FakeStripeGateway#stub_session` (Task 2);
  - `session[:checkout_order_id]` (Task 5), `Cart#clear` (Task 3).
- Produces:
  - `OrdersController::MAX_TRIES = 10`.
  - Helpers, used by the admin and dashboard views too:
    - `customer_status(order) → String`;
    - `order_status_tone(status) → :green | :orange | :gray`;
    - `order_total_rows(order) → Array<[label, cents]>`.
  - Partials: `orders/_items`, with locals `order:` and `show_sku:` (default false); and `orders/_totals`, with local `order:`.

- [ ] **Step 1: Write the failing tests**

`test/integration/order_page_test.rb`:

```ruby
require "test_helper"

class OrderPageTest < ActionDispatch::IntegrationTest
  teardown do
    Order.dataset.delete
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  def stripe
    StripeGateway.current
  end

  test "a paid order shows its number, items, totals and status in words" do
    order = build_order(status: "paid", items: [ { name: "Page Tee", label: "Black / M", price: 1500, quantity: 2 } ])

    get "/orders/#{order.token}"
    assert_response :success
    assert_select "h1", text: /#{order.number}/
    assert_select "[data-order-items]", text: /Page Tee — Black \/ M/
    assert_select "[data-order-totals]", text: /Total\s*\$30\.00/
    assert_select "[data-order-status]", text: /Paid — we're getting it ready/
    assert_select "[data-order-status]", text: /Bookmark this page to check on your order\./
  end

  test "an unknown token is a 404" do
    get "/orders/not-a-real-token"
    assert_response :not_found
  end

  test "a pickup order shows the pickup instructions, a shipped one its tracking" do
    StoreSetting.current.update(pickup_instructions: "Come by the shop on Main.")
    pickup = build_order(status: "ready_for_pickup", fulfillment: "pickup")
    get "/orders/#{pickup.token}"
    assert_select "[data-order-status]", text: /Ready for pickup in McComb/
    assert_select "[data-delivery]", text: /Come by the shop on Main\./

    shipped = build_order(status: "shipped", fulfillment: "shipping", tracking_number: "1Z999",
                          ship_name: "Pat Buyer", ship_address: { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }.to_json)
    get "/orders/#{shipped.token}"
    assert_select "[data-order-status]", text: /Tracking: 1Z999/
    assert_select "[data-delivery]", text: /1 Main St/
  end

  test "when the webhook is late, the page asks Stripe and confirms the order itself" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_late")
    stripe.stub_session("cs_test_late", **paid_session(order).except(:id))

    get "/orders/#{order.token}"
    assert_equal "paid", order.refresh.status
    assert_select "[data-order-status]", text: /Paid — we're getting it ready/
    assert_select "meta[http-equiv=refresh]", count: 0
  end

  test "an unpaid session shows the confirming message and refreshes" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_unpaid")
    stripe.stub_session("cs_test_unpaid", payment_status: "unpaid")

    get "/orders/#{order.token}"
    assert_select "[data-order-status]", text: /Payment received, confirming your order…/
    assert_select "meta[http-equiv=refresh][content=?]", "3;url=/orders/#{order.token}?tries=1"
  end

  test "after ten tries the page stops refreshing and says to check back" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_slow")
    stripe.stub_session("cs_test_slow", payment_status: "unpaid")

    get "/orders/#{order.token}", params: { tries: 10 }
    assert_select "[data-order-status]", text: /We're still confirming your payment\. Check back in a minute\./
    assert_select "meta[http-equiv=refresh]", count: 0
  end

  test "a Stripe error while confirming still shows the page" do
    order = build_order(status: "pending", stripe_session_id: "cs_test_missing")

    get "/orders/#{order.token}"
    assert_response :success
    assert_select "[data-order-status]", text: /Payment received, confirming your order…/
  end

  test "returning from Stripe with a paid order empties the cart" do
    tee = build_product(name: "Flow Tee", price: "10.00")
    post "/cart/items", params: { variant_id: tee.variants.first.id, quantity: 1 }
    post "/checkout", params: { fulfillment: "pickup" }
    order = Order.order(:id).last
    stripe.stub_session(order.stripe_session_id, **paid_session(order).except(:id))

    get "/orders/#{order.token}"
    assert_select "nav a[href='/cart']", text: "Cart (0)"
    assert_nil session[:checkout_order_id]
  end

  test "viewing an older order leaves the current cart alone" do
    tee = build_product(name: "Keep Tee", price: "10.00")
    post "/cart/items", params: { variant_id: tee.variants.first.id, quantity: 2 }
    old = build_order(status: "completed")

    get "/orders/#{old.token}"
    assert_select "nav a[href='/cart']", text: "Cart (2)"
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/order_page_test.rb`
Expected: errors with `uninitialized constant OrdersController`.

- [ ] **Step 3: Controller, helper, views**

`app/controllers/orders_controller.rb`:

```ruby
# The page a buyer lands on after paying, and the link their dashboard uses.
# Anyone holding the token can see it, because guests have no account to sign
# in to.
class OrdersController < ApplicationController
  MAX_TRIES = 10

  def show
    @order = Order.first(token: params[:token].to_s)
    raise ActionController::RoutingError, "Not Found" unless @order

    confirm_payment if @order.pending?
    clear_cart_after_checkout
    @tries = params[:tries].to_i.clamp(0, MAX_TRIES)
    @settings = StoreSetting.current
  end

  private

  # The webhook usually lands first. When it has not, ask Stripe directly so
  # the buyer sees a confirmed order without waiting.
  def confirm_payment
    return if @order.stripe_session_id.blank?

    OrderFulfiller.new(@order, StripeGateway.current.retrieve_session(@order.stripe_session_id)).call
  rescue StripeGateway::Error => e
    Rails.logger.warn("could not confirm #{@order.number}: #{e.message}")
  end

  # Only for the order this browser just checked out: opening an old order
  # from the dashboard must not empty the cart.
  def clear_cart_after_checkout
    return unless session[:checkout_order_id] == @order.id && !@order.pending?

    Cart.new(session).clear
    session.delete(:checkout_order_id)
  end
end
```

`app/helpers/orders_helper.rb`:

```ruby
module OrdersHelper
  CUSTOMER_STATUS = {
    "paid" => "Paid — we're getting it ready", "printing" => "Printing",
    "ready_for_pickup" => "Ready for pickup in McComb", "shipped" => "Shipped",
    "completed" => "Completed", "cancelled" => "Cancelled", "refunded" => "Refunded"
  }.freeze

  def customer_status(order)
    CUSTOMER_STATUS.fetch(order.status, order.status_label)
  end

  def order_status_tone(status)
    case status
    when "paid", "ready_for_pickup", "shipped", "completed" then :green
    when "printing" then :orange
    else :gray
    end
  end

  # [label, cents] rows for an order's totals. Shipping shows for shipping
  # orders even when free; tax and refunds only when there are any.
  def order_total_rows(order)
    rows = [ [ "Subtotal", order.subtotal_cents ] ]
    rows << [ "Shipping", order.shipping_cents ] if order.shipping?
    rows << [ "Tax", order.tax_cents ] if order.tax_cents.positive?
    rows << [ "Total", order.total_cents ]
    rows << [ "Refunded", -order.refunded_cents ] if order.refunded_cents.positive?
    rows
  end
end
```

`app/views/orders/_items.html.erb`:

```erb
<% show_sku = local_assigns.fetch(:show_sku, false) %>
<div data-order-items>
  <%= render layout: "shared/data_table", locals: { headers: [ "Item", (show_sku ? "SKU" : nil), "Qty", "Price", "Total" ].compact } do %>
    <% order.items.each do |item| %>
      <tr>
        <td class="py-3 pr-6 font-bold"><%= item.variant_label == item.product_name ? item.product_name : "#{item.product_name} — #{item.variant_label}" %></td>
        <% if show_sku %>
          <td class="py-3 pr-6 text-gray-600"><%= item.sku.presence || "—" %></td>
        <% end %>
        <td class="py-3 pr-6"><%= item.quantity %></td>
        <td class="py-3 pr-6 whitespace-nowrap"><%= price(item.unit_price_cents) %></td>
        <td class="py-3 font-bold whitespace-nowrap"><%= price(item.total_cents) %></td>
      </tr>
    <% end %>
  <% end %>
</div>
```

`app/views/orders/_totals.html.erb`:

```erb
<dl class="mt-6 space-y-1 text-sm" data-order-totals>
  <% order_total_rows(order).each do |label, cents| %>
    <div class="flex justify-between <%= "border-t-2 border-gray-200 pt-2 font-bold" if label == "Total" %>">
      <dt><%= label %></dt>
      <dd><%= price(cents) %></dd>
    </div>
  <% end %>
</dl>
```

`app/views/orders/show.html.erb`:

```erb
<% refreshing = @order.pending? && @tries < OrdersController::MAX_TRIES %>
<% if refreshing %>
  <% content_for :head do %>
    <meta http-equiv="refresh" content="3;url=<%= order_path(@order.token, tries: @tries + 1) %>">
  <% end %>
<% end %>
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ORDER", heading_bottom: "#{@order.number}." %>

  <section class="max-w-3xl mx-auto px-6 py-12 space-y-8">
    <div class="border-2 border-brand-green rounded-xl p-6" data-order-status>
      <% if @order.pending? %>
        <p class="font-bold"><%= refreshing ? "Payment received, confirming your order…" : "We're still confirming your payment. Check back in a minute." %></p>
      <% else %>
        <p class="font-display text-2xl uppercase tracking-wide"><%= customer_status(@order) %></p>
        <% if @order.status == "shipped" && @order.tracking_number.present? %>
          <p class="mt-1 text-sm font-bold">Tracking: <%= @order.tracking_number %></p>
        <% end %>
      <% end %>
      <p class="mt-2 text-sm text-gray-600">Bookmark this page to check on your order.</p>
    </div>

    <%= render layout: "shared/panel", locals: { title: "Items", subtitle: "Placed #{@order.created_at.to_date.iso8601}" } do %>
      <%= render "orders/items", order: @order %>
      <%= render "orders/totals", order: @order %>
    <% end %>

    <%= render layout: "shared/panel", locals: { title: "Delivery" } do %>
      <div class="text-sm text-gray-700" data-delivery>
        <% if @order.pickup? %>
          <p class="font-bold">Pickup in McComb</p>
          <p class="mt-1"><%= @settings.pickup_instructions %></p>
        <% elsif @order.address_lines.any? %>
          <p class="font-bold"><%= @order.ship_name %></p>
          <% @order.address_lines.each do |line| %>
            <p><%= line %></p>
          <% end %>
        <% else %>
          <p>Shipping. Your address appears here once payment is confirmed.</p>
        <% end %>
      </div>
    <% end %>
  </section>
</div>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/order_page_test.rb`
Expected: 9 runs, 0 failures, 0 errors.

- [ ] **Step 5: Full suite, lint, commit**

Run the full suite in the background, with nothing else running against the test database. Then:

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/controllers/orders_controller.rb app/helpers/orders_helper.rb app/views/orders test/integration/order_page_test.rb
git commit -m "Add the customer order page, confirming payment if the webhook is late

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: suite 0 failures, 0 errors.

---

### Task 9: Admin settings

**Files:**
- Create: `app/models/store_settings_form.rb`
- Create: `app/controllers/admin/settings_controller.rb`
- Create: `app/views/admin/settings/show.html.erb`
- Modify: `config/routes.rb` (admin namespace)
- Modify: `app/views/admin/_tabs.html.erb` (Settings tab)
- Modify: `test/integration/admin_authorization_test.rb` (`ADMIN_PATHS` gains `/admin/settings`)
- Test: `test/integration/admin_settings_test.rb`

**Interfaces:**
- Consumes:
  - `StoreSetting` (Task 1);
  - `StripeGateway.current.create_tax_rate`, `FakeStripeGateway#tax_rates_created`, `#fail_with=` (Task 2);
  - `ProductEditor.format_money(cents) → "8.00"`.
- Produces:
  - `StoreSettingsForm.new(setting, params = nil, gateway: StripeGateway.current)`.
  - Methods: `#save → Boolean`, `#errors → Array<String>`, `#setting`.
  - Field readers: `#shipping_input`, `#pickup_input`, `#tax_enabled?`, `#tax_rate_input`.
  - Routes: `GET /admin/settings` (`admin_settings_path`) and `PATCH /admin/settings`.
  - Form field names: `settings[shipping]`, `settings[pickup_instructions]`, `settings[tax_enabled]`, `settings[tax_rate]`.

- [ ] **Step 1: Write the failing tests**

`test/integration/admin_settings_test.rb`:

```ruby
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
```

In `test/integration/admin_authorization_test.rb`, change `ADMIN_PATHS` to `%w[/admin /admin/accounts /admin/orders /admin/traffic /admin/settings].freeze`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/admin_settings_test.rb`
Expected: failures with 404s (no route).

- [ ] **Step 3: Form object, controller, view, route, tab**

`app/models/store_settings_form.rb`:

```ruby
# What /admin/settings submits, parsed into the StoreSetting row. Dollars
# and percents in, cents and basis points out; a malformed number is an
# error, never zero. A new tax rate becomes a new Stripe tax rate, because
# Stripe's cannot be edited, and if Stripe refuses it nothing is saved.
class StoreSettingsForm
  DECIMAL = /\A\d+(\.\d{1,2})?\z/
  LABELS = { shipping_cents: "Shipping rate", pickup_instructions: "Pickup instructions", tax_rate_bps: "Tax rate" }.freeze

  attr_reader :setting, :errors

  def initialize(setting, params = nil, gateway: StripeGateway.current)
    @setting = setting
    @params = params&.to_h&.stringify_keys
    @gateway = gateway
    @errors = []
  end

  def shipping_input
    @params ? @params["shipping"].to_s : ProductEditor.format_money(@setting.shipping_cents)
  end

  def pickup_input
    @params ? @params["pickup_instructions"].to_s : @setting.pickup_instructions
  end

  def tax_enabled?
    @params ? @params["tax_enabled"] == "1" : @setting.tax_enabled?
  end

  def tax_rate_input
    return @params["tax_rate"].to_s if @params

    ProductEditor.format_money(@setting.tax_rate_bps)
  end

  def save
    shipping = hundredths(@params["shipping"])
    rate_text = @params["tax_rate"].to_s.strip
    rate = rate_text.empty? ? nil : hundredths(rate_text)

    @errors << "Shipping rate must be a dollar amount, like 8.00." unless shipping
    @errors << "Tax rate must be a percent, like 7 or 7.25." if rate_text.present? && rate.nil?
    return false if @errors.any?

    @setting.set(shipping_cents: shipping, tax_rate_bps: rate, tax_enabled: tax_enabled?,
                 pickup_instructions: @params["pickup_instructions"].to_s.strip)
    unless @setting.valid?
      @setting.errors.each { |field, messages| messages.each { |message| @errors << "#{LABELS.fetch(field)} #{message}." } }
      return false
    end

    refresh_stripe_tax_rate
    @setting.save
    true
  rescue StripeGateway::Error => e
    @errors << "Stripe did not accept the tax rate (#{e.message}). Nothing was saved."
    false
  end

  private

  def refresh_stripe_tax_rate
    return unless @setting.tax_enabled?
    return if @setting.stripe_tax_rate_id && @setting.stripe_tax_rate_bps == @setting.tax_rate_bps

    @setting.set(stripe_tax_rate_id: @gateway.create_tax_rate(@setting.tax_rate_bps),
                 stripe_tax_rate_bps: @setting.tax_rate_bps)
  end

  def hundredths(text)
    clean = text.to_s.strip.delete("$%,")
    return nil unless clean.match?(DECIMAL)

    (BigDecimal(clean) * 100).round.to_i
  end
end
```

`app/controllers/admin/settings_controller.rb`:

```ruby
module Admin
  class SettingsController < BaseController
    def show
      @form = StoreSettingsForm.new(StoreSetting.current)
      @collecting_tax = @form.setting.checkout_tax_rate_id.present?
    end

    def update
      @form = StoreSettingsForm.new(StoreSetting.current, settings_params)
      return redirect_to(admin_settings_path, notice: "Settings saved.") if @form.save

      # From a fresh read: the form's copy holds the rejected values.
      @collecting_tax = StoreSetting.current.checkout_tax_rate_id.present?
      render :show, status: :unprocessable_entity
    end

    private

    def settings_params
      params.fetch(:settings, {}).permit(:shipping, :pickup_instructions, :tax_enabled, :tax_rate)
    end
  end
end
```

`app/views/admin/settings/show.html.erb`:

```erb
<%
  field_class = "px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40"
  label_class = "block text-xs font-bold uppercase tracking-widest text-gray-500"
%>
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "STORE", heading_bottom: "SETTINGS." %>

  <%= render "admin/tabs" %>

  <section class="max-w-3xl mx-auto px-6 py-12">
    <%= form_with url: admin_settings_path, method: :patch, data: { turbo: false }, class: "space-y-8" do %>
      <% if @form.errors.any? %>
        <div class="border-2 border-brand-orange rounded-lg p-4">
          <p class="font-bold text-sm uppercase tracking-widest text-brand-orange">Could not save</p>
          <ul class="mt-2 space-y-1 text-sm text-gray-700">
            <% @form.errors.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= render layout: "shared/panel", locals: { title: "Delivery" } do %>
        <div class="space-y-4">
          <div>
            <label for="settings_shipping" class="<%= label_class %>">Flat shipping rate</label>
            <input id="settings_shipping" name="settings[shipping]" type="text" inputmode="decimal" value="<%= @form.shipping_input %>" class="mt-2 w-40 <%= field_class %>">
            <p class="mt-1 text-xs text-gray-500">Charged once per shipped order. Pickup is free.</p>
          </div>
          <div>
            <label for="settings_pickup_instructions" class="<%= label_class %>">Pickup instructions</label>
            <textarea id="settings_pickup_instructions" name="settings[pickup_instructions]" rows="3" maxlength="<%= StoreSetting::MAX_INSTRUCTIONS %>"
                      class="mt-2 w-full <%= field_class %>"><%= @form.pickup_input %></textarea>
          </div>
        </div>
      <% end %>

      <%= render layout: "shared/panel", locals: { title: "Sales tax" } do %>
        <div class="space-y-4">
          <label class="flex items-center gap-3 text-sm font-bold">
            <input type="hidden" name="settings[tax_enabled]" value="0">
            <input type="checkbox" name="settings[tax_enabled]" value="1" class="accent-brand-green" <%= "checked" if @form.tax_enabled? %>>
            Collect Mississippi sales tax
          </label>
          <div>
            <label for="settings_tax_rate" class="<%= label_class %>">Rate (%)</label>
            <input id="settings_tax_rate" name="settings[tax_rate]" type="text" inputmode="decimal" value="<%= @form.tax_rate_input %>" placeholder="7.00"
                   class="mt-2 w-40 <%= field_class %>">
            <p class="mt-1 text-xs text-gray-500">Charged on items for Mississippi addresses and pickups. Not on shipping.</p>
          </div>
          <% unless @collecting_tax %>
            <p class="text-sm font-bold text-brand-orange">No sales tax is being collected.</p>
          <% end %>
        </div>
      <% end %>

      <button type="submit"
              class="inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">
        Save settings <span aria-hidden="true">&rarr;</span>
      </button>
    <% end %>
  </section>
</div>
```

In `config/routes.rb`, inside `namespace :admin`, add `resource :settings, only: [ :show, :update ]`.

In `app/views/admin/_tabs.html.erb`, add `[ "Settings", admin_settings_path ]` after Traffic.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_settings_test.rb test/integration/admin_authorization_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/models/store_settings_form.rb app/controllers/admin/settings_controller.rb app/views/admin/settings config/routes.rb app/views/admin/_tabs.html.erb test/integration/admin_settings_test.rb test/integration/admin_authorization_test.rb
git commit -m "Add store settings: shipping rate, pickup text and the sales tax switch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Admin orders

**Files:**
- Modify: `config/routes.rb` (replace `get "orders"` in the admin namespace)
- Modify: `app/controllers/admin/orders_controller.rb`
- Replace: `app/views/admin/orders/index.html.erb`
- Create: `app/views/admin/orders/show.html.erb`
- Modify: `test/integration/admin_pages_test.rb` (the orders test no longer expects a table on an empty list)
- Test: `test/integration/admin_orders_test.rb`

**Interfaces:**
- Consumes:
  - `Order.placed`, `Order::ADMIN_STATUSES`, `Order::NEEDS_ACTION`, `Order::STATUS_LABELS`, `#status_label`, `#item_count`, `#partially_refunded?`, `#address_lines` (Task 1);
  - `order_status_tone`, `orders/_items`, `orders/_totals` (Task 8).
- Produces:
  - Routes:
    - `GET /admin/orders`, with query params `q` and `filter`;
    - `GET /admin/orders/:number` (`admin_order_path(number)`);
    - `PATCH /admin/orders/:number`, with params `status` and `tracking_number`.
  - `Admin::OrdersController::FILTERS` keys: `needs_action`, `pickup`, `shipping`, `oversold`, `refunded`.

- [ ] **Step 1: Write the failing tests**

`test/integration/admin_orders_test.rb`:

```ruby
require "test_helper"

class AdminOrdersTest < ActionDispatch::IntegrationTest
  teardown { Order.dataset.delete }

  setup { sign_in create_account(superuser: true) }

  def rows
    css_select("table tbody tr")
  end

  def row_for(order)
    rows.find { |row| row.text.include?(order.number) }
  end

  test "paid orders are listed with their details and pending ones are not" do
    paid = build_order(status: "paid", fulfillment: "shipping", email: "pat@example.test")
    pending = build_order(status: "pending")

    get "/admin/orders"
    assert_response :success
    row = row_for(paid)
    assert row, "expected #{paid.number} in the list"
    [ "pat@example.test", "Ship", "$12.00", "Paid" ].each { |text| assert_includes row.text, text }
    assert_nil row_for(pending)
  end

  test "oversold and partially refunded orders say so" do
    oversold = build_order(oversold: true)
    refunded = build_order(status: "shipped", refunded_cents: 500)

    get "/admin/orders"
    assert_includes row_for(oversold).text, "Oversold"
    assert_includes row_for(refunded).text, "Partially refunded $5.00"
  end

  test "search matches an order number or email, and a percent sign is literal" do
    findme = build_order(email: "findme@example.test")
    other = build_order(email: "other@example.test")

    get "/admin/orders", params: { q: "FINDME" }
    assert row_for(findme)
    assert_nil row_for(other)

    get "/admin/orders", params: { q: other.number.downcase }
    assert row_for(other)
    assert_nil row_for(findme)

    get "/admin/orders", params: { q: "%" }
    assert_equal 0, rows.size
  end

  test "filters narrow the list and mark themselves current" do
    printing = build_order(status: "printing", fulfillment: "pickup")
    done = build_order(status: "completed", fulfillment: "shipping")
    oversold = build_order(status: "completed", oversold: true)

    get "/admin/orders", params: { filter: "needs_action" }
    assert row_for(printing)
    assert_nil row_for(done)
    assert_select "a[aria-current='page']", text: "Needs action"

    get "/admin/orders", params: { filter: "shipping" }
    assert row_for(done)
    assert_nil row_for(printing)

    get "/admin/orders", params: { filter: "oversold" }
    assert row_for(oversold)
    assert_nil row_for(done)

    get "/admin/orders", params: { filter: "banana" }
    assert_select "a[aria-current='page']", text: "All"
  end

  test "the order page shows items, totals, address and the Stripe payment" do
    order = build_order(status: "paid", fulfillment: "shipping", stripe_payment_intent_id: "pi_abc",
                        ship_name: "Pat Buyer", ship_address: { line1: "1 Main St", city: "McComb", state: "MS", postal_code: "39648", country: "US" }.to_json,
                        items: [ { name: "Admin Tee", label: "Black / L", price: 1500, quantity: 2, sku: "AT-BL-L" } ])

    get "/admin/orders/#{order.number}"
    assert_response :success
    assert_select "[data-order-items]", text: /Admin Tee — Black \/ L/
    assert_select "[data-order-items]", text: /AT-BL-L/
    assert_select "[data-order-totals]", text: /\$30\.00/
    assert_select "body", text: /1 Main St/
    assert_select "a[href='https://dashboard.stripe.com/payments/pi_abc']"
  end

  test "pending and unknown orders are not found" do
    pending = build_order(status: "pending")

    get "/admin/orders/#{pending.number}"
    assert_response :not_found
    get "/admin/orders/BS-0"
    assert_response :not_found
  end

  test "the owner sets the status and tracking number" do
    order = build_order(status: "paid", fulfillment: "shipping")

    patch "/admin/orders/#{order.number}", params: { status: "shipped", tracking_number: " 1Z999 " }
    assert_redirected_to "/admin/orders/#{order.number}"
    follow_redirect!
    assert_select "[data-flash=notice]", text: "Order updated."
    order.refresh
    assert_equal [ "shipped", "1Z999" ], [ order.status, order.tracking_number ]
  end

  test "the status list offers every step after payment, in any order" do
    order = build_order(status: "completed")

    get "/admin/orders/#{order.number}"
    options = css_select("select[name=status] option").map { |option| option["value"] }
    assert_equal Order::ADMIN_STATUSES, options

    patch "/admin/orders/#{order.number}", params: { status: "printing" }
    assert_equal "printing", order.refresh.status
  end

  test "an unknown status, or pending, is refused" do
    order = build_order(status: "paid")

    [ "pending", "lost" ].each do |status|
      patch "/admin/orders/#{order.number}", params: { status: status }
      assert_response :unprocessable_entity
      assert_select "[data-order-error]", text: "Choose a status from the list."
    end
    assert_equal "paid", order.refresh.status
  end

  test "the placeholder orders are gone" do
    get "/admin/orders"
    refute_selector_text "body", /queen\.com/
  end

  test "non-superusers cannot reach orders" do
    order = build_order
    sign_in create_account(superuser: false)

    get "/admin/orders/#{order.number}"
    assert_response :not_found
  end
end
```

In `test/integration/admin_pages_test.rb`, replace the body of `"orders page renders a table of orders"` with the following. Rename the test to `"orders page renders"`.

```ruby
    get "/admin/orders"
    assert_response :success
    assert_select "h1 span", text: "ALL"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/admin_orders_test.rb`
Expected: failures, with the mockup rows present and `/admin/orders/:number` not routed.

- [ ] **Step 3: Routes, controller, views**

In `config/routes.rb`, inside `namespace :admin`, replace `get "orders"   => "orders#index",   as: :orders` with:

```ruby
    resources :orders, only: [ :index, :show, :update ], param: :number
```

`app/controllers/admin/orders_controller.rb`:

```ruby
module Admin
  class OrdersController < BaseController
    LIMIT = 100
    # Filter key => [link label, dataset narrowing]. Pending orders never show.
    FILTERS = {
      "needs_action" => [ "Needs action", ->(orders) { orders.where(status: Order::NEEDS_ACTION) } ],
      "pickup"       => [ "Pickup",       ->(orders) { orders.where(fulfillment: "pickup") } ],
      "shipping"     => [ "Shipping",     ->(orders) { orders.where(fulfillment: "shipping") } ],
      "oversold"     => [ "Oversold",     ->(orders) { orders.where(oversold: true) } ],
      "refunded"     => [ "Refunded",     ->(orders) { orders.where(status: "refunded") } ]
    }.freeze

    def index
      @query = params[:q].to_s.strip
      @filter = params[:filter].to_s if FILTERS.key?(params[:filter].to_s)

      orders = Order.placed.order(Sequel.desc(:id))
      orders = FILTERS.fetch(@filter).last.call(orders) if @filter
      if @query.present?
        # escape_like so a typed % or _ is matched literally, not as a wildcard.
        pattern = "%#{orders.escape_like(@query)}%"
        orders = orders.where(Sequel.ilike(:number, pattern) | Sequel.ilike(:email, pattern))
      end

      @total = Order.placed.count
      @matching = orders.count
      @orders = orders.eager(:items).limit(LIMIT).all
    end

    def show
      @order = find_order
    end

    def update
      @order = find_order
      status = params[:status].to_s

      unless Order::ADMIN_STATUSES.include?(status)
        @error = "Choose a status from the list."
        return render :show, status: :unprocessable_entity
      end

      @order.set(status: status, tracking_number: params[:tracking_number].to_s.strip.presence)
      unless @order.valid?
        @error = "Tracking number must be #{Order::MAX_TRACKING} characters or fewer."
        return render :show, status: :unprocessable_entity
      end

      @order.save
      redirect_to admin_order_path(@order.number), notice: "Order updated."
    end

    private

    def find_order
      order = Order.placed.where(number: params[:number].to_s).eager(:items).all.first
      raise ActionController::RoutingError, "Not Found" unless order

      order
    end
  end
end
```

Replace `app/views/admin/orders/index.html.erb`:

```erb
<% filters = [ [ "All", nil ] ] + Admin::OrdersController::FILTERS.map { |key, (label, _)| [ label, key ] } %>
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ALL", heading_bottom: "ORDERS." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Orders", subtitle: "#{@total} placed" } do %>
      <div class="mb-6 flex flex-wrap items-center gap-4">
        <%= form_with url: admin_orders_path, method: :get, class: "w-full max-w-xs" do %>
          <% if @filter %><input type="hidden" name="filter" value="<%= @filter %>"><% end %>
          <label for="order_search" class="sr-only">Search by order number or email</label>
          <input id="order_search" type="search" name="q" value="<%= @query %>" placeholder="Order number or email"
                 class="w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
        <% end %>
        <nav class="flex flex-wrap gap-2" aria-label="Filter orders">
          <% filters.each do |label, key| %>
            <% current = @filter == key %>
            <%= link_to label, admin_orders_path(q: @query.presence, filter: key),
                  "aria-current": (current ? "page" : nil),
                  class: "px-3 py-1 rounded-full text-xs font-bold uppercase tracking-widest #{current ? "bg-brand-green text-white" : "bg-gray-100 text-gray-600 hover:bg-gray-200"}" %>
          <% end %>
        </nav>
      </div>

      <% if @orders.empty? %>
        <%= render "shared/empty_state", message: "No orders match." %>
      <% else %>
        <%= render layout: "shared/data_table", locals: { headers: [ "Order", "Date", "Email", "Items", "Delivery", "Total", "Status", "" ] } do %>
          <% @orders.each do |order| %>
            <tr>
              <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= order.number %></td>
              <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= (order.paid_at || order.created_at).to_date.iso8601 %></td>
              <td class="py-3 pr-6 text-gray-600"><%= order.email %></td>
              <td class="py-3 pr-6 text-gray-600"><%= order.item_count %></td>
              <td class="py-3 pr-6 text-gray-600"><%= order.pickup? ? "Pickup" : "Ship" %></td>
              <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= price(order.total_cents) %></td>
              <td class="py-3 pr-6">
                <div class="flex flex-wrap gap-1">
                  <%= render "shared/status_badge", label: order.status_label, tone: order_status_tone(order.status) %>
                  <% if order.oversold? %>
                    <%= render "shared/status_badge", label: "Oversold", tone: :orange %>
                  <% end %>
                </div>
                <% if order.partially_refunded? %>
                  <p class="mt-1 text-xs text-gray-500">Partially refunded <%= price(order.refunded_cents) %></p>
                <% end %>
              </td>
              <td class="py-3 text-right">
                <%= link_to "View", admin_order_path(order.number), class: "font-bold text-xs uppercase tracking-widest text-brand-green" %>
              </td>
            </tr>
          <% end %>
        <% end %>

        <% if @matching > @orders.size %>
          <p class="mt-4 text-xs text-gray-500">Showing the newest <%= @orders.size %> of <%= @matching %>. Search to narrow it down.</p>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

`app/views/admin/orders/show.html.erb`:

```erb
<% label_class = "block text-xs font-bold uppercase tracking-widest text-gray-500" %>
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ORDER", heading_bottom: "#{@order.number}." %>

  <%= render "admin/tabs" %>

  <section class="max-w-5xl mx-auto px-6 py-12 space-y-8">
    <div class="grid md:grid-cols-2 gap-8">
      <%= render layout: "shared/panel", locals: { title: "Customer" } do %>
        <dl class="space-y-4 text-sm">
          <div>
            <dt class="<%= label_class %>">Email</dt>
            <dd class="mt-1 font-bold"><%= @order.email || "—" %></dd>
          </div>
          <div>
            <dt class="<%= label_class %>">Delivery</dt>
            <dd class="mt-1 text-gray-700">
              <% if @order.pickup? %>
                Pickup in McComb
              <% else %>
                <p class="font-bold"><%= @order.ship_name %></p>
                <% @order.address_lines.each do |line| %>
                  <p><%= line %></p>
                <% end %>
              <% end %>
            </dd>
          </div>
          <div>
            <dt class="<%= label_class %>">Paid</dt>
            <dd class="mt-1 text-gray-700"><%= @order.paid_at&.strftime("%Y-%m-%d %H:%M") || "—" %></dd>
          </div>
          <% if @order.oversold? %>
            <div><%= render "shared/status_badge", label: "Oversold", tone: :orange %>
              <p class="mt-1 text-xs text-gray-500">There was not enough stock for this order when it was paid.</p></div>
          <% end %>
          <% if @order.stripe_payment_intent_id.present? %>
            <div>
              <%= link_to "View payment in Stripe", "https://dashboard.stripe.com/payments/#{@order.stripe_payment_intent_id}",
                    target: "_blank", rel: "noopener", class: "font-bold text-brand-green underline decoration-2 underline-offset-4" %>
            </div>
          <% end %>
        </dl>
      <% end %>

      <%= render layout: "shared/panel", locals: { title: "Update" } do %>
        <%= form_with url: admin_order_path(@order.number), method: :patch, data: { turbo: false }, class: "space-y-4" do %>
          <% if @error %>
            <p class="text-sm font-bold text-brand-orange" data-order-error><%= @error %></p>
          <% end %>
          <div>
            <label for="status" class="<%= label_class %>">Status</label>
            <select id="status" name="status" class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md">
              <% Order::ADMIN_STATUSES.each do |status| %>
                <option value="<%= status %>" <%= "selected" if status == @order.status %>><%= Order::STATUS_LABELS.fetch(status) %></option>
              <% end %>
            </select>
          </div>
          <div>
            <label for="tracking_number" class="<%= label_class %>">Tracking number</label>
            <input id="tracking_number" name="tracking_number" type="text" value="<%= @order.tracking_number %>" maxlength="<%= Order::MAX_TRACKING %>"
                   class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md">
          </div>
          <button type="submit"
                  class="inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">
            Save <span aria-hidden="true">&rarr;</span>
          </button>
        <% end %>
      <% end %>
    </div>

    <%= render layout: "shared/panel", locals: { title: "Items" } do %>
      <%= render "orders/items", order: @order, show_sku: true %>
      <%= render "orders/totals", order: @order %>
    <% end %>

    <p><%= link_to "← All orders", admin_orders_path, class: "font-bold text-sm uppercase tracking-wide text-brand-green" %></p>
  </section>
</div>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_orders_test.rb test/integration/admin_pages_test.rb test/integration/admin_authorization_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add config/routes.rb app/controllers/admin/orders_controller.rb app/views/admin/orders test/integration/admin_orders_test.rb test/integration/admin_pages_test.rb
git commit -m "Show real orders in the admin and let the owner set each status

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Orders on the admin overview

**Files:**
- Modify: `app/controllers/admin/overview_controller.rb`
- Modify: `app/views/admin/overview/index.html.erb`
- Modify: `test/integration/admin_overview_test.rb`

**Interfaces:**
- Consumes: `Order.placed`, `#paid_at`, `#total_cents`, `#refunded_cents`, `#number` (Task 1).
- Produces: two more stat tiles, Orders and Revenue (both "Last 7 days"), and "Order BS-N paid — $X" activity items.

- [ ] **Step 1: Write the failing tests**

In `test/integration/admin_overview_test.rb`:
- Add `Order.dataset.delete` to `teardown`.
- In `"the tiles report real accounts, products and traffic"`, change `assert_equal expected, tiles` to `assert_equal expected, tiles.first(4)`.
- Add these tests:

```ruby
  test "the order tiles count this week's paid orders and their revenue after refunds" do
    build_order(status: "paid", items: [ { name: "A", label: "A", price: 3000, quantity: 1 } ])
    build_order(status: "shipped", refunded_cents: 500, items: [ { name: "B", label: "B", price: 2000, quantity: 1 } ])
    build_order(status: "pending")
    build_order(status: "completed", paid_at: 30.days.ago)

    get "/admin"
    assert_equal [ "2", "$45.00" ], tiles.last(2)
  end

  test "paid orders appear in recent activity" do
    order = build_order(status: "paid", items: [ { name: "A", label: "A", price: 3800, quantity: 1 } ])

    get "/admin"
    items = css_select("[data-activity] li").map { |li| li.text.squish }
    assert items.any? { |item| item.include?("Order #{order.number} paid — $38.00") }, "expected the order in #{items.inspect}"
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/admin_overview_test.rb`
Expected: the 2 new tests fail. The tile list has only 4 entries, and no order activity is shown.

- [ ] **Step 3: Controller and view**

In `app/controllers/admin/overview_controller.rb`, `index`, add after `@products_live = ...`:

```ruby
      paid = Order.placed.where { paid_at >= week }
      @orders_week  = paid.count
      @revenue_week = paid.get(Sequel.function(:coalesce, Sequel.function(:sum, Sequel[:total_cents] - Sequel[:refunded_cents]), 0)).to_i
```

In `recent_activity`, add the following before the final line, then change the final line to `(signups + products + orders).sort_by { |event| -event[:at].to_f }.first(ACTIVITY_LIMIT)`. Also update the comment above the method to "New sign-ups, product changes and paid orders, newest first."

```ruby
      orders = Order.placed.exclude(paid_at: nil).order(Sequel.desc(:paid_at)).limit(ACTIVITY_LIMIT).all.map do |order|
        total = ActiveSupport::NumberHelper.number_to_currency(order.total_cents / 100.0)
        { at: order.paid_at, text: "Order #{order.number} paid — #{total}" }
      end
```

In `app/views/admin/overview/index.html.erb`, change the tile grid to `grid grid-cols-2 md:grid-cols-3 gap-6`. Then add two tiles after the Page views tile:

```erb
      <%= render "shared/stat_tile", label: "Orders", value: @orders_week, delta: "Last 7 days" %>
      <%= render "shared/stat_tile", label: "Revenue", value: price(@revenue_week), delta: "Last 7 days" %>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_overview_test.rb`
Expected: 7 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/controllers/admin/overview_controller.rb app/views/admin/overview/index.html.erb test/integration/admin_overview_test.rb
git commit -m "Show this week's orders and revenue on the admin overview

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Dashboard orders, and removing the checkout mockup

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`
- Create: `app/views/dashboard/_orders_table.html.erb`
- Replace: `app/views/dashboard/orders.html.erb`
- Modify: `app/views/dashboard/index.html.erb` (real recent orders, lede)
- Modify: `app/views/dashboard/_tabs.html.erb` (drop Checkout)
- Delete: `app/views/dashboard/checkout.html.erb`
- Modify: `config/routes.rb` (drop `dashboard/checkout`)
- Modify: `test/integration/dashboard_pages_test.rb`, `test/integration/dashboard_authorization_test.rb`, `test/integration/removed_routes_test.rb`
- Test: `test/integration/dashboard_orders_test.rb`

**Interfaces:**
- Consumes: `Order.placed`, `#token`, `#number`, `#status_label` (Task 1); `order_status_tone`, `order_path(token)` (Tasks 4 and 8).
- Produces: `dashboard/_orders_table`, with local `orders:`.

- [ ] **Step 1: Write the failing tests**

`test/integration/dashboard_orders_test.rb`:

```ruby
require "test_helper"

class DashboardOrdersTest < ActionDispatch::IntegrationTest
  teardown { Order.dataset.delete }

  setup do
    @account = create_account
    sign_in @account
  end

  test "the orders page lists only this account's placed orders, each linking to its page" do
    mine = build_order(account: @account, status: "shipped")
    pending = build_order(account: @account, status: "pending")
    theirs = build_order(account: create_account, status: "paid")

    get "/dashboard/orders"
    assert_response :success
    assert_select "a[href='/orders/#{mine.token}']", text: "View"
    assert_select "tbody", text: /#{mine.number}.*Shipped/m
    refute_selector_text "tbody", /#{pending.number}/
    refute_selector_text "tbody", /#{theirs.number}/
  end

  test "with no orders the page says so and links to the shop" do
    get "/dashboard/orders"
    assert_select "body", text: /No orders yet\./
  end

  test "the dashboard shows the three most recent orders" do
    orders = 4.times.map { build_order(account: @account) }

    get "/dashboard"
    numbers = css_select("tbody tr td:first-child").map { |td| td.text.strip }
    assert_equal orders.last(3).reverse.map(&:number), numbers
  end

  test "the placeholder orders and the checkout tab are gone" do
    get "/dashboard"
    refute_selector_text "body", /#1041|#1042/
    assert_select "a[href='/dashboard/checkout']", count: 0
  end
end
```

Update the existing tests:
- **`test/integration/dashboard_pages_test.rb`:** delete the two checkout tests. Replace the orders test's body with:
  ```ruby
      get "/dashboard/orders"
      assert_response :success
      assert_select "h1 span", text: "YOUR"
  ```
- **`test/integration/dashboard_authorization_test.rb`:** change `PATHS` to `%w[/dashboard /dashboard/account /dashboard/orders].freeze`.
- **`test/integration/removed_routes_test.rb`:** inside `"new_issue route is gone"`, add `assert_routing_error "/dashboard/checkout"`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/integration/dashboard_orders_test.rb test/integration/removed_routes_test.rb`
Expected: failures, because the mockup rows are present and `/dashboard/checkout` still routes.

- [ ] **Step 3: Controller, views, route**

`app/controllers/dashboard_controller.rb`:

```ruby
class DashboardController < ApplicationController
  before_action :authenticate

  RECENT_ORDERS = 3

  def index
    @recent_orders = customer_orders.limit(RECENT_ORDERS).all
  end

  def account
  end

  def orders
    @orders = customer_orders.all
  end

  private

  def customer_orders
    Order.placed.where(account_id: current_account.id).order(Sequel.desc(:id))
  end
end
```

`app/views/dashboard/_orders_table.html.erb`:

```erb
<% if orders.empty? %>
  <%= render "shared/empty_state", message: "No orders yet.", cta_label: "Shop", cta_path: shop_path %>
<% else %>
  <%= render layout: "shared/data_table", locals: { headers: [ "Order", "Date", "Status", "Total", "" ] } do %>
    <% orders.each do |order| %>
      <tr>
        <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= order.number %></td>
        <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= (order.paid_at || order.created_at).to_date.iso8601 %></td>
        <td class="py-3 pr-6"><%= render "shared/status_badge", label: order.status_label, tone: order_status_tone(order.status) %></td>
        <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= price(order.total_cents) %></td>
        <td class="py-3 text-right">
          <%= link_to "View", order_path(order.token), class: "font-bold text-xs uppercase tracking-widest text-brand-green" %>
        </td>
      </tr>
    <% end %>
  <% end %>
<% end %>
```

Replace `app/views/dashboard/orders.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "YOUR", heading_bottom: "ORDERS." %>

  <%= render "dashboard/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Order history" } do %>
      <%= render "dashboard/orders_table", orders: @orders %>
    <% end %>
  </section>
</div>
```

In `app/views/dashboard/index.html.erb`, make two changes:
- Change the lede to `"Your orders and details in one place."`.
- In the "Recent orders" panel, replace the whole `render layout: "shared/data_table"` block (the hard-coded `#1042`/`#1041` rows) with `<%= render "dashboard/orders_table", orders: @recent_orders %>`. Keep the "All orders" link below it.

In `app/views/dashboard/_tabs.html.erb`, remove the `[ "Checkout", dashboard_checkout_path ]` entry and the comma before it.

In `config/routes.rb`, delete the `get "dashboard/checkout"` line.

```bash
git rm app/views/dashboard/checkout.html.erb
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/dashboard_orders_test.rb test/integration/dashboard_pages_test.rb test/integration/dashboard_authorization_test.rb test/integration/removed_routes_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Full suite, lint, commit**

Run the full suite in the background, with nothing else running against the test database. Then:

```bash
bin/rubocop && bin/brakeman --no-pager
git add app/controllers/dashboard_controller.rb app/views/dashboard config/routes.rb test/integration/dashboard_orders_test.rb test/integration/dashboard_pages_test.rb test/integration/dashboard_authorization_test.rb test/integration/removed_routes_test.rb
git commit -m "Show customers their real orders and remove the checkout mockup

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: suite 0 failures, 0 errors.

---

### Task 13: A real test-mode checkout in the browser

This task has no automated tests. It proves the parts the fake cannot prove: Stripe accepts the params the app sends, the webhook really arrives, and the API field names (`collected_information.shipping_details`, `total_details`) match.

**Before you start, the user must do these things.** Ask for them and wait.
1. Restart `bin/dev` (Task 1 added tables).
2. Put Stripe **test-mode** keys in `.env`:
   - `STRIPE_SECRET_KEY=sk_test_...`
   - `STRIPE_WEBHOOK_SECRET=whsec_...`

   The webhook secret is the one printed by `stripe listen`. `.env` is gitignored, so never commit it or echo its values.
3. Run `stripe listen --forward-to localhost:3000/stripe/webhooks` in a terminal, then restart `bin/dev` so it picks up the secret.

- [ ] **Step 1: Pickup checkout.**
  1. Add a product to the cart, choose Pickup, and check out.
  2. On Stripe's page, pay with card `4242 4242 4242 4242`, any future expiry, any CVC and any ZIP.
  3. Expect: you land on `/orders/<token>`, the page shows "Paid — we're getting it ready", the nav shows "Cart (0)", and the variant's stock has dropped.
- [ ] **Step 2: Shipping checkout with tax on.**
  1. In `/admin/settings`, turn tax on at 7 and save.
  2. Check out with Shipping, using a Mississippi address.
  3. Expect: Stripe shows $8.00 shipping and 7% tax on the items. Afterwards, `/admin/orders/<number>` shows the address, the tax amount and a working Stripe payment link.
  4. Repeat with a non-MS address. Expect: no tax.
- [ ] **Step 3: Status and refund.**
  1. In the admin, set the order to Shipped with a tracking number.
  2. Expect: the customer page shows "Shipped" and "Tracking: …".
  3. Refund the order in the Stripe dashboard. Expect: the admin shows Refunded within a few seconds.
- [ ] **Step 4: Abandoned checkout.** Start a checkout and press Stripe's back link. Expect: you are back on `/cart` with the cart intact.
- [ ] **Step 5: Record the results.** Ledger them as `Task 13: complete (manual: pickup ✓, shipping+tax ✓, status ✓, refund ✓, cancel ✓)`, and note anything that differed. Any fix gets a failing test first, under the TDD rules.
