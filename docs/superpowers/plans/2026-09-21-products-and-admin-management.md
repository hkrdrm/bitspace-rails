# Products, Public Catalog, and Admin Product Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `products` and `product_variants` tables with Sequel models, a read-only public catalog at `/shop`, and full product management in the `/admin` namespace, where a variant is a SKU carrying stock for one size and colour combination.

**Architecture:** A product owns many variants; each variant is one (size, colour) pair with its own price and stock, unique on `[product_id, size, color]`. Colour is derived from the variants rather than stored on the product, so there is one source of truth. The admin writes a product and reconciles its whole variant grid inside one transaction. Everything renders through the existing `shared/` partial vocabulary and, in the admin, inherits `Admin::BaseController`'s superuser gate.

**Tech Stack:** Rails 8.0, Ruby 3.3.1, Sequel + `sequel-rails`, PostgreSQL, rodauth-rails 2.1, Tailwind CSS v4, Stimulus via importmap, Minitest.

**Spec:** `docs/superpowers/specs/2026-09-21-products-and-admin-management-design.md`

## Global Constraints

- **This app uses Sequel, not ActiveRecord.** Models subclass `Sequel::Model`. Migrations are `Sequel.migration do change do ... end end`. Query with `Product.where(...)`, `dataset.delete`, `select_map`. There is no usable `ApplicationRecord`.
- **Sequel raises on invalid saves.** `Model.create` and `#save` raise `Sequel::ValidationFailed` by default — they do not return `false`. Use `#valid?` when you want a boolean. A database-level unique index raises `Sequel::UniqueConstraintViolation` instead.
- **Test command:** `bin/rails test test/` for all, `bin/rails test path/to/file.rb -n test_name` for one. Never bare `bin/rails test` — it triggers sequel-rails' test database maintenance, which tries to drop and recreate through `template1`, and the managed cluster rejects that.
- **Tests are not transactional.** `use_transactional_tests` is an ActiveRecord feature and does nothing here. Every test must delete the rows it creates, in `teardown`.
- **Do not remove the `setup_fixtures` / `teardown_fixtures` overrides** in `test/test_helper.rb`. Without them every test errors before its body runs.
- **Money is integer cents everywhere.** No floats, no decimals in the database.
- **Sizes:** `S, M, L, XL, 2XL, 3XL` — exactly, in that order.
- **Colour palette:** `Black #0d1114`, `White #f7f7f5`, `Heather Grey #b5b8ba`, `Navy #1b2a41`, `Sand #d8cbb4`, `Red #b3261e` — exactly these names and hexes.
- **Style tokens** (in `app/assets/tailwind/application.css`): `font-display` (Anton), `text-ink` / `bg-ink` (`#0d1114`), `brand-green` (`#5c7a1e`), `brand-green-dark` (`#4a621a`), `brand-orange` (`#dd440c`).
- **Page chrome convention:** every page wraps content in `<div class="bg-white text-ink">`, because `body` is `bg-gray-900 text-white` in the layout.
- **Form convention:** `form_with url: ..., method: :post, data: { turbo: false }`. Every existing form in this app disables Turbo; match it.
- **Do not run `bin/rails tailwindcss:build`.** The `bin/dev` watcher handles CSS. New utility classes appear after the next `bin/dev` run.
- **Migrations:** after writing one, run `bin/rails db:migrate` **and** `RAILS_ENV=test bin/rails db:migrate`. Commit the regenerated `db/schema.rb`; never hand-edit it.
- **Lint and scan:** `bin/rubocop` and `bin/brakeman --no-pager` both run in CI and must exit 0. Run both before each commit.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/20260921140000_create_products.rb` | Both tables in one migration |
| `app/models/product.rb` | Product, the size and colour vocabularies, derived readers |
| `app/models/product_variant.rb` | One SKU: size, colour, price, stock |
| `app/controllers/shop_controller.rb` | Public catalog, no auth |
| `app/controllers/admin/products_controller.rb` | Admin CRUD and grid reconciliation |
| `app/views/shop/index.html.erb` | Catalog grid |
| `app/views/shop/show.html.erb` | Product detail, colour sections, size ladders |
| `app/views/admin/products/index.html.erb` | Admin product list |
| `app/views/admin/products/_form.html.erb` | Shared new/edit form, price rows, stock grid |
| `app/views/admin/products/new.html.erb` | Wrapper |
| `app/views/admin/products/edit.html.erb` | Wrapper plus delete |
| `app/javascript/controllers/variant_grid_controller.js` | Hides unselected colour columns in the admin grid |
| `app/javascript/controllers/color_switcher_controller.js` | Switches size ladders on the public product page |
| `test/models/product_test.rb` | Validations, constraints, derived readers |
| `test/integration/shop_test.rb` | Public catalog |
| `test/integration/admin_products_test.rb` | Admin authorization and CRUD round trip |

**Modified:**

| File | Change |
|---|---|
| `app/helpers/application_helper.rb` | Add `#price` |
| `config/routes.rb` | Add `/shop` routes and `resources :products` in the admin namespace |
| `app/views/admin/_tabs.html.erb` | Add a Products tab |
| `app/views/layouts/partials/_navigation.html.erb` | Turn the inert "Store" text into a Shop link, twice |
| `db/seeds.rb` | Three sample shirts |
| `db/schema.rb` | Regenerated by the migration |

---

### Task 1: Schema and models

**Files:**
- Create: `db/migrate/20260921140000_create_products.rb`, `app/models/product.rb`, `app/models/product_variant.rb`
- Modify: `db/schema.rb` (regenerated — commit, never hand-edit)
- Test: `test/models/product_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Product` — `Sequel::Model`; columns `id, name, slug, description, image, base_price_cents, active, created_at, updated_at`
  - `Product::SIZES` → `["S", "M", "L", "XL", "2XL", "3XL"]`
  - `Product::COLORS` → `Hash` of colour name to hex string, in display order
  - `Product::NEUTRAL_SWATCH` → `String` hex, used for a colour no longer in the palette
  - `Product#variants` → `Array<ProductVariant>`, ordered by `position` then `color`
  - `ProductVariant` — `Sequel::Model`; columns `id, product_id, size, color, price_cents, stock, position`

- [ ] **Step 1: Write the failing test**

Create `test/models/product_test.rb`:

```ruby
require "test_helper"

class ProductTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def build_product(**overrides)
    Product.create({
      name: "Test Tee",
      slug: "test-tee-#{SecureRandom.hex(4)}",
      description: "A shirt.",
      image: "3crow.png",
      base_price_cents: 1200,
      active: true
    }.merge(overrides))
  end

  def build_variant(product, size: "S", color: "Black", price_cents: 1200, stock: 5, position: 0)
    ProductVariant.create(
      product_id: product.id, size: size, color: color,
      price_cents: price_cents, stock: stock, position: position
    )
  end

  test "a product can be created" do
    product = build_product
    assert product.id
    assert_equal true, product.active?
  end

  test "slug must be unique" do
    build_product(slug: "taken")
    assert_raises(Sequel::ValidationFailed) { build_product(slug: "taken") }
  end

  test "slug must be lowercase letters, numbers and dashes" do
    assert_raises(Sequel::ValidationFailed) { build_product(slug: "Not A Slug") }
  end

  test "name is required" do
    assert_raises(Sequel::ValidationFailed) { build_product(name: nil) }
  end

  test "base price cannot be negative" do
    assert_raises(Sequel::ValidationFailed) { build_product(base_price_cents: -1) }
  end

  test "a variant size must be one of the known sizes" do
    product = build_product
    assert_raises(Sequel::ValidationFailed) { build_variant(product, size: "XXS") }
  end

  test "a variant colour must be in the palette" do
    product = build_product
    assert_raises(Sequel::ValidationFailed) { build_variant(product, color: "Chartreuse") }
  end

  test "variant stock cannot be negative" do
    product = build_product
    assert_raises(Sequel::ValidationFailed) { build_variant(product, stock: -1) }
  end

  test "the same size and colour cannot repeat on one product" do
    product = build_product
    build_variant(product, size: "M", color: "Black")
    assert_raises(Sequel::ValidationFailed) { build_variant(product, size: "M", color: "Black") }
  end

  test "the same size and colour may repeat across different products" do
    a = build_product
    b = build_product
    build_variant(a, size: "M", color: "Black")
    assert build_variant(b, size: "M", color: "Black").id
  end

  test "deleting a product deletes its variants" do
    product = build_product
    build_variant(product, size: "S", color: "Black")
    build_variant(product, size: "M", color: "Black")
    assert_equal 2, ProductVariant.where(product_id: product.id).count

    product.destroy
    assert_equal 0, ProductVariant.where(product_id: product.id).count
  end

  test "variants come back in size order, not alphabetical order" do
    product = build_product
    Product::SIZES.each_with_index { |size, i| build_variant(product, size: size, position: i) }

    assert_equal Product::SIZES, product.variants.map(&:size)
  end
end
```

`teardown` deletes only products; variants go with them through the cascade.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/product_test.rb`
Expected: every test errors with `NameError: uninitialized constant ProductTest::Product`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260921140000_create_products.rb`:

```ruby
# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :products do
      primary_key :id
      String    :name, null: false
      String    :slug, null: false, unique: true
      String    :description, text: true
      String    :image
      Integer   :base_price_cents, null: false
      TrueClass :active, null: false, default: true
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
    end

    create_table :product_variants do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :size, null: false
      String  :color, null: false
      Integer :price_cents, null: false
      Integer :stock, null: false, default: 0
      Integer :position, null: false

      index [ :product_id, :size, :color ], unique: true
    end
  end
end
```

- [ ] **Step 4: Run the migration in both environments**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
```

Expected: both succeed silently, and `db/schema.rb` gains `create_table(:products)` and `create_table(:product_variants)`.

- [ ] **Step 5: Write the Product model**

Create `app/models/product.rb`:

```ruby
class Product < Sequel::Model
  SIZES = %w[S M L XL 2XL 3XL].freeze

  # The shop's stocked blanks. Hash order is display order.
  COLORS = {
    "Black"        => "#0d1114",
    "White"        => "#f7f7f5",
    "Heather Grey" => "#b5b8ba",
    "Navy"         => "#1b2a41",
    "Sand"         => "#d8cbb4",
    "Red"          => "#b3261e"
  }.freeze

  # Shown for a colour that has left the palette but still has rows.
  NEUTRAL_SWATCH = "#9ca3af"

  one_to_many :variants, class: :ProductVariant, order: [ :position, :color ]

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  def validate
    super
    validates_presence [ :name, :slug, :base_price_cents ]
    validates_format(/\A[a-z0-9-]+\z/, :slug, message: "must be lowercase letters, numbers and dashes")
    validates_unique(:slug)
    validates_operator(:>=, 0, :base_price_cents, allow_nil: true)
  end
end
```

`allow_nil: true` on the operator check matters: without it a nil price raises `NoMethodError` comparing `nil >= 0` before `validates_presence` can report the real problem.

- [ ] **Step 6: Write the ProductVariant model**

Create `app/models/product_variant.rb`:

```ruby
class ProductVariant < Sequel::Model
  many_to_one :product

  plugin :validation_helpers
  plugin :boolean_readers

  def validate
    super
    validates_presence [ :product_id, :size, :color, :price_cents, :stock, :position ]
    validates_includes Product::SIZES, :size
    validates_includes Product::COLORS.keys, :color
    validates_operator(:>=, 0, :price_cents, allow_nil: true)
    validates_operator(:>=, 0, :stock, allow_nil: true)
    validates_unique([ :product_id, :size, :color ])
  end
end
```

`validates_unique` on the trio catches the duplicate in Ruby and raises `Sequel::ValidationFailed`. The database index is the backstop and would raise `Sequel::UniqueConstraintViolation` instead; the test expects the validation, so both must exist.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/models/product_test.rb`
Expected: 12 runs, 0 failures, 0 errors.

- [ ] **Step 8: Run the full suite and lint**

Run: `bin/rails test test/` then `bin/rubocop` then `bin/brakeman --no-pager`
Expected: suite green, rubocop 0 offenses, brakeman exit 0.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Add product and product variant models

A variant is a SKU: one row per size and colour, carrying its own
price and stock, unique on [product_id, size, color]. Colour is NOT
NULL because PostgreSQL treats NULLs as distinct in unique indexes,
so a nullable column would silently allow duplicate rows."
```

---

### Task 2: Derived readers on Product

Views must never sort or do arithmetic. These readers are the whole interface the catalog and admin pages read through.

**Files:**
- Modify: `app/models/product.rb`
- Test: `test/models/product_test.rb`

**Interfaces:**
- Consumes: `Product`, `ProductVariant`, `Product::SIZES`, `Product::COLORS` from Task 1.
- Produces:
  - `Product.published` → dataset of `active` products ordered by name
  - `Product#colors` → `Array<String>` distinct colours in palette order
  - `Product#variants_for(color)` → `Array<ProductVariant>` for one colour, in size order
  - `Product#price_range` → `[Integer, Integer]` min and max cents; `[base_price_cents, base_price_cents]` when there are no variants
  - `Product#stock_for(size:, color:)` → `Integer`, `0` when no such row
  - `Product#in_stock?` → `true` when any variant has stock above zero
  - `Product#total_stock` → `Integer` sum of all variant stock
  - `Product#swatch_for(color)` → `String` hex, `NEUTRAL_SWATCH` for an unknown name

- [ ] **Step 1: Write the failing test**

Append to `test/models/product_test.rb`, inside the class, before the final `end`:

```ruby
  test "published returns only active products, ordered by name" do
    build_product(name: "Zebra", slug: "zebra", active: true)
    build_product(name: "Apple", slug: "apple", active: true)
    build_product(name: "Hidden", slug: "hidden", active: false)

    assert_equal [ "Apple", "Zebra" ], Product.published.select_map(:name)
  end

  test "colors returns distinct colours in palette order" do
    product = build_product
    build_variant(product, size: "S", color: "Red")
    build_variant(product, size: "M", color: "Black")
    build_variant(product, size: "L", color: "Red")

    assert_equal [ "Black", "Red" ], product.colors
  end

  test "variants_for returns one colour in size order" do
    product = build_product
    Product::SIZES.each_with_index do |size, i|
      build_variant(product, size: size, color: "Black", position: i)
      build_variant(product, size: size, color: "White", position: i)
    end

    black = product.variants_for("Black")
    assert_equal Product::SIZES, black.map(&:size)
    assert_equal [ "Black" ], black.map(&:color).uniq
  end

  test "price_range spans the cheapest and dearest variant" do
    product = build_product
    build_variant(product, size: "S", price_cents: 1200)
    build_variant(product, size: "2XL", price_cents: 1400, position: 4)

    assert_equal [ 1200, 1400 ], product.price_range
  end

  test "price_range falls back to the base price when there are no variants" do
    product = build_product(base_price_cents: 1500)
    assert_equal [ 1500, 1500 ], product.price_range
  end

  test "stock_for returns the count for one SKU and zero for a missing one" do
    product = build_product
    build_variant(product, size: "M", color: "Black", stock: 7)

    assert_equal 7, product.stock_for(size: "M", color: "Black")
    assert_equal 0, product.stock_for(size: "M", color: "White")
    assert_equal 0, product.stock_for(size: "3XL", color: "Black")
  end

  test "in_stock? and total_stock reflect the whole grid" do
    product = build_product
    build_variant(product, size: "S", stock: 0)
    refute product.in_stock?
    assert_equal 0, product.total_stock

    build_variant(product, size: "M", stock: 4, position: 1)
    product.refresh
    assert product.in_stock?
    assert_equal 4, product.total_stock
  end

  test "swatch_for returns palette hex, or neutral grey for an unknown colour" do
    product = build_product
    assert_equal "#0d1114", product.swatch_for("Black")
    assert_equal Product::NEUTRAL_SWATCH, product.swatch_for("Chartreuse")
  end
```

`product.refresh` clears Sequel's cached association so the newly added variant is seen. Without it the second half of the `in_stock?` test reads a stale array.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/product_test.rb`
Expected: the eight new tests fail with `NoMethodError` — `undefined method 'published' for class Product`, `undefined method 'colors'`, and so on. The twelve from Task 1 still pass.

- [ ] **Step 3: Add the readers**

In `app/models/product.rb`, insert after the `plugin :boolean_readers` line and before `def validate`:

```ruby
  dataset_module do
    def published
      where(active: true).order(:name)
    end
  end

  # Which colours this design comes in. Derived from the variants so there is
  # one source of truth rather than a list that can drift from the rows.
  def colors
    variants.map(&:color).uniq.sort_by { |color| COLORS.keys.index(color) || COLORS.size }
  end

  def variants_for(color)
    variants.select { |variant| variant.color == color }
  end

  def price_range
    prices = variants.map(&:price_cents)
    return [ base_price_cents, base_price_cents ] if prices.empty?

    [ prices.min, prices.max ]
  end

  def stock_for(size:, color:)
    variants.find { |variant| variant.size == size && variant.color == color }&.stock || 0
  end

  def in_stock?
    variants.any? { |variant| variant.stock.positive? }
  end

  def total_stock
    variants.sum(&:stock)
  end

  def swatch_for(color)
    COLORS.fetch(color, NEUTRAL_SWATCH)
  end
```

`variants` is loaded once and cached by Sequel, so these readers do not each hit the database.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/product_test.rb`
Expected: 20 runs, 0 failures, 0 errors.

- [ ] **Step 5: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add derived readers to Product

colors, variants_for, price_range, stock_for, in_stock?, total_stock
and swatch_for, so views never sort or do arithmetic. The published
scope is named for clarity next to the active column, which
boolean_readers already exposes as #active?."
```

---

### Task 3: Price helper and sample data

**Files:**
- Modify: `app/helpers/application_helper.rb`, `db/seeds.rb`
- Test: `test/models/seeds_test.rb`

**Interfaces:**
- Consumes: `Product`, `ProductVariant`, `Product::SIZES` from Tasks 1 and 2.
- Produces:
  - `ApplicationHelper#price(cents)` → `String`, e.g. `price(1200)` → `"$12.00"`, `price(nil)` → `"$0.00"`
  - Seed products at slugs `3-crow`, `see-that-shit`, `third-eye-smiley`

- [ ] **Step 1: Write the failing test**

Create `test/models/seeds_test.rb`:

```ruby
require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def load_seeds
    load Rails.root.join("db/seeds.rb")
  end

  test "seeding creates three products with their variant grids" do
    load_seeds

    assert_equal 3, Product.count

    crow = Product.first(slug: "3-crow")
    assert_equal [ "Black", "White", "Heather Grey" ], crow.colors
    assert_equal 18, crow.variants.count

    smiley = Product.first(slug: "third-eye-smiley")
    assert_equal [ "Black" ], smiley.colors
    assert_equal 6, smiley.variants.count
  end

  test "sizes are priced twelve dollars through XL and fourteen above it" do
    load_seeds
    crow = Product.first(slug: "3-crow")

    assert_equal 1200, crow.stock_for(size: "S", color: "Black").then { crow.variants.find { |v| v.size == "S" && v.color == "Black" }.price_cents }
    assert_equal 1400, crow.variants.find { |v| v.size == "2XL" && v.color == "Black" }.price_cents
  end

  test "one product has a sold out size so the catalog shows that state" do
    load_seeds
    shit = Product.first(slug: "see-that-shit")

    assert_equal 0, shit.stock_for(size: "3XL", color: "Black")
    assert_equal 0, shit.stock_for(size: "3XL", color: "Red")
    assert shit.in_stock?, "the product should still have stock in other sizes"
  end

  test "seeding twice changes nothing" do
    load_seeds
    first_count = ProductVariant.count
    load_seeds

    assert_equal 3, Product.count
    assert_equal first_count, ProductVariant.count
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/seeds_test.rb`
Expected: `4 runs, 4 failures` — `Expected: 3, Actual: 0`, because `db/seeds.rb` still only contains comments.

- [ ] **Step 3: Add the price helper**

Replace `app/helpers/application_helper.rb`:

```ruby
module ApplicationHelper
  # Money is stored as integer cents everywhere. This is the only place that
  # converts it for display.
  def price(cents)
    number_to_currency((cents || 0) / 100.0)
  end
end
```

- [ ] **Step 4: Write the seeds**

Replace `db/seeds.rb`:

```ruby
# Sample products for the shop. Idempotent on slug, so running this repeatedly
# leaves the data unchanged.

SEED_PRODUCTS = [
  {
    name: "3 Crow",
    slug: "3-crow",
    description: "Three crows, one shirt. Front print, heavy cotton.",
    image: "3crow.png",
    colors: [ "Black", "White", "Heather Grey" ],
    stock: {
      "Black"        => { "S" => 24, "M" => 31, "L" => 17, "XL" => 8, "2XL" => 3, "3XL" => 1 },
      "White"        => { "S" => 18, "M" => 22, "L" => 14, "XL" => 5, "2XL" => 2, "3XL" => 0 },
      "Heather Grey" => { "S" => 6,  "M" => 9,  "L" => 4,  "XL" => 2, "2XL" => 0, "3XL" => 0 }
    }
  },
  {
    name: "See That Shit",
    slug: "see-that-shit",
    description: "Say it with a shirt. Front and back print.",
    image: "see_that_shit.png",
    colors: [ "Black", "Red" ],
    stock: {
      "Black" => { "S" => 12, "M" => 15, "L" => 11, "XL" => 6, "2XL" => 2, "3XL" => 0 },
      "Red"   => { "S" => 7,  "M" => 10, "L" => 8,  "XL" => 3, "2XL" => 1, "3XL" => 0 }
    }
  },
  {
    name: "Third Eye Smiley",
    slug: "third-eye-smiley",
    description: "Single colour print, one garment colour, no fuss.",
    image: "3rd_eye_smiley.png",
    colors: [ "Black" ],
    stock: {
      "Black" => { "S" => 9, "M" => 13, "L" => 10, "XL" => 4, "2XL" => 2, "3XL" => 1 }
    }
  }
].freeze

# $12 through XL, $14 for the big sizes, matching the homepage.
def seed_price_for(size)
  %w[2XL 3XL].include?(size) ? 1400 : 1200
end

SEED_PRODUCTS.each do |attributes|
  product = Product.first(slug: attributes[:slug]) || Product.new(slug: attributes[:slug])
  product.set(
    name: attributes[:name],
    description: attributes[:description],
    image: attributes[:image],
    base_price_cents: 1200,
    active: true
  )
  product.save

  attributes[:colors].each do |color|
    Product::SIZES.each_with_index do |size, index|
      variant = ProductVariant.first(product_id: product.id, size: size, color: color) ||
                ProductVariant.new(product_id: product.id, size: size, color: color)
      variant.set(
        price_cents: seed_price_for(size),
        stock: attributes.dig(:stock, color, size).to_i,
        position: index
      )
      variant.save
    end
  end
end

puts "Seeded #{Product.count} products, #{ProductVariant.count} variants."
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/seeds_test.rb`
Expected: 4 runs, 0 failures.

- [ ] **Step 6: Load the seeds into development**

```bash
bin/rails db:seed
```

Expected: `Seeded 3 products, 30 variants.`

- [ ] **Step 7: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add price helper and sample products

Three shirts built from artwork already in the repo, covering three
colours, two colours and one so every rendering path has data. Stock
counts vary by cell so the sold-out treatment is visible on a fresh
database."
```

---

### Task 4: Public catalog

**Files:**
- Create: `app/controllers/shop_controller.rb`, `app/views/shop/index.html.erb`, `app/views/shop/show.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/partials/_navigation.html.erb`
- Test: `test/integration/shop_test.rb`

**Interfaces:**
- Consumes: `Product.published`, `Product#colors`, `#variants_for`, `#price_range`, `#swatch_for` from Task 2; `ApplicationHelper#price` from Task 3; `shared/page_header`, `shared/section_divider`, `shared/empty_state` from the existing partial set.
- Produces: `shop_path` → `/shop`, `shop_product_path(slug)` → `/shop/:slug`.

**Note:** every colour's size ladder renders on the page at once in this task. Task 8 adds the Stimulus controller that shows one at a time; until then the page is correct but long, which is the no-JavaScript fallback behaviour by design.

- [ ] **Step 1: Write the failing test**

Create `test/integration/shop_test.rb`:

```ruby
require "test_helper"

class ShopTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def create_product(slug:, name: "Tee", active: true, colors: [ "Black" ], stock: 5)
    product = Product.create(
      name: name, slug: slug, description: "A shirt.", image: "3crow.png",
      base_price_cents: 1200, active: active
    )
    colors.each do |color|
      Product::SIZES.each_with_index do |size, index|
        ProductVariant.create(
          product_id: product.id, size: size, color: color,
          price_cents: %w[2XL 3XL].include?(size) ? 1400 : 1200,
          stock: size == "3XL" ? 0 : stock, position: index
        )
      end
    end
    product
  end

  test "the catalog lists published products" do
    create_product(slug: "listed", name: "Listed Tee")

    get "/shop"
    assert_response :success
    assert_select "h1 span", text: "THE"
    assert_select "body", text: /Listed Tee/
  end

  test "the catalog omits inactive products" do
    create_product(slug: "hidden", name: "Hidden Tee", active: false)

    get "/shop"
    assert_response :success
    assert_select "body", text: /Hidden Tee/, count: 0
  end

  test "a product page renders its sizes and prices" do
    create_product(slug: "detail", name: "Detail Tee")

    get "/shop/detail"
    assert_response :success
    assert_select "body", text: /Detail Tee/
    assert_select "body", text: /\$12\.00/
    assert_select "body", text: /\$14\.00/
  end

  test "a sold out size is shown rather than hidden" do
    create_product(slug: "soldout")

    get "/shop/soldout"
    assert_response :success
    assert_select "[data-sold-out]", minimum: 1
    assert_select "body", text: /3XL/
  end

  test "a multi colour product names each colour" do
    create_product(slug: "many", colors: [ "Black", "Red" ])

    get "/shop/many"
    assert_select "[data-color-section]", 2
    assert_select "body", text: /Black/
    assert_select "body", text: /Red/
  end

  test "a single colour product renders one section" do
    create_product(slug: "one", colors: [ "Black" ])

    get "/shop/one"
    assert_select "[data-color-section]", 1
  end

  test "an unknown slug is a 404" do
    get "/shop/nope"
    assert_response :not_found
  end

  test "an inactive product 404s rather than revealing itself" do
    create_product(slug: "draft", active: false)

    get "/shop/draft"
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/shop_test.rb`
Expected: all eight fail — `/shop` is not routed, so every request is a 404 and the success assertions fail. The two 404 tests pass vacuously at this point and only become meaningful after Step 3.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, add directly below the `contact` line:

```ruby
  get "shop"       => "shop#index", as: :shop
  get "shop/:slug" => "shop#show",  as: :shop_product
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/shop_controller.rb`:

```ruby
class ShopController < ApplicationController
  def index
    @products = Product.published.all
  end

  def show
    @product = Product.first(slug: params[:slug], active: true)

    # A 404 rather than a redirect: an unpublished product should not announce
    # that it exists.
    raise ActionController::RoutingError, "Not Found" unless @product
  end
end
```

- [ ] **Step 5: Build the catalog index**

Create `app/views/shop/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header",
        heading_top: "THE",
        heading_bottom: "SHOP.",
        lede: "Small batch shirts, printed in McComb." %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <% if @products.empty? %>
      <%= render "shared/empty_state", message: "Nothing in the shop just yet. Check back soon." %>
    <% else %>
      <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-8">
        <% @products.each do |product| %>
          <%= link_to shop_product_path(product.slug), class: "group block border-2 border-brand-green rounded-xl overflow-hidden" do %>
            <div class="aspect-square bg-gray-100 flex items-center justify-center overflow-hidden">
              <% if product.image.present? %>
                <%= image_tag product.image, alt: product.name, class: "w-full h-full object-cover group-hover:scale-105 transition-transform" %>
              <% end %>
            </div>
            <div class="p-5">
              <h2 class="font-display text-2xl tracking-tight"><%= product.name %></h2>
              <% low, high = product.price_range %>
              <p class="mt-1 font-bold text-sm">
                <%= low == high ? price(low) : "#{price(low)} – #{price(high)}" %>
              </p>
              <% if product.colors.many? %>
                <div class="mt-3 flex items-center gap-2">
                  <% product.colors.each do |color| %>
                    <span class="inline-block w-4 h-4 rounded-full border border-gray-300"
                          style="background-color: <%= product.swatch_for(color) %>"
                          title="<%= color %>"></span>
                  <% end %>
                  <span class="text-xs text-gray-500"><%= product.colors.size %> colours</span>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    <% end %>
  </section>
</div>
```

- [ ] **Step 6: Build the product page**

Create `app/views/shop/show.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header",
        heading_top: @product.name.upcase,
        heading_bottom: "$#{'%.2f' % (@product.price_range.first / 100.0)}." %>

  <section class="max-w-5xl mx-auto px-6 py-12 grid md:grid-cols-2 gap-10">
    <div class="aspect-square bg-gray-100 rounded-xl overflow-hidden flex items-center justify-center">
      <% if @product.image.present? %>
        <%= image_tag @product.image, alt: @product.name, class: "w-full h-full object-cover" %>
      <% end %>
    </div>

    <div>
      <p class="text-gray-700"><%= @product.description %></p>

      <div class="mt-8 space-y-8">
        <% @product.colors.each do |color| %>
          <div data-color-section data-color="<%= color %>">
            <div class="flex items-center gap-3">
              <span class="inline-block w-6 h-6 rounded-full border border-gray-300"
                    style="background-color: <%= @product.swatch_for(color) %>"></span>
              <h2 class="font-display text-xl tracking-wide uppercase"><%= color %></h2>
            </div>

            <ul class="mt-4 space-y-2">
              <% @product.variants_for(color).each do |variant| %>
                <% sold_out = variant.stock.zero? %>
                <li class="flex items-center justify-between gap-4 text-sm py-2 border-b border-gray-200
                           <%= "text-gray-400" if sold_out %>"
                    <%= "data-sold-out" if sold_out %>>
                  <span class="font-bold <%= "line-through" if sold_out %>"><%= variant.size %></span>
                  <span class="<%= "line-through" if sold_out %>"><%= price(variant.price_cents) %></span>
                  <span class="text-xs uppercase tracking-widest">
                    <%= sold_out ? "Sold out" : "In stock" %>
                  </span>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>

      <p class="mt-8 text-xs text-gray-500">Ordering online is not open yet — get in touch for a quote.</p>
    </div>
  </section>
</div>
```

- [ ] **Step 7: Link the shop from the navigation**

`app/views/layouts/partials/_navigation.html.erb` already has an inert `Store` in both the desktop bar and the mobile menu. Replace both.

Desktop — change:

```erb
      <span>Store</span>
```

to:

```erb
      <span><%= link_to "Shop", shop_path %></span>
```

Mobile — change:

```erb
    <span class="block py-2 border-b border-white/10">Store</span>
```

to:

```erb
    <span class="block py-2 border-b border-white/10"><%= link_to "Shop", shop_path %></span>
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/integration/shop_test.rb`
Expected: 8 runs, 0 failures.

- [ ] **Step 9: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add the public shop catalog

Read-only: an index grid and a product page listing every colour's
size ladder with prices. Sold out sizes are shown struck through
rather than hidden, so a missing size reads as sold out rather than
never offered. An inactive product 404s instead of redirecting, so it
does not announce that it exists."
```

---

### Task 5: Admin products index

**Files:**
- Create: `app/controllers/admin/products_controller.rb`, `app/views/admin/products/index.html.erb`
- Modify: `config/routes.rb`, `app/views/admin/_tabs.html.erb`
- Test: `test/integration/admin_products_test.rb`

**Interfaces:**
- Consumes: `Admin::BaseController` and its `require_superuser` gate; `shared/data_table`, `shared/status_badge`, `shared/empty_state`, `shared/panel`, `admin/tabs`; `Product#price_range`, `#colors`, `#total_stock`, `#swatch_for`.
- Produces: `admin_products_path` → `/admin/products`, plus the `new`, `edit`, `create`, `update` and `destroy` routes that Tasks 6 and 7 fill in.

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_products_test.rb`:

```ruby
require "test_helper"

class AdminProductsTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def create_product(slug: "sample", name: "Sample Tee")
    product = Product.create(
      name: name, slug: slug, description: "A shirt.", image: "3crow.png",
      base_price_cents: 1200, active: true
    )
    Product::SIZES.each_with_index do |size, index|
      ProductVariant.create(
        product_id: product.id, size: size, color: "Black",
        price_cents: 1200, stock: 3, position: index
      )
    end
    product
  end

  test "signed out visitors are redirected away from the product pages" do
    product = create_product

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "a non-superuser gets a 404 from the product pages" do
    product = create_product
    sign_in create_account(superuser: false)

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :not_found, "expected #{path} to 404 for a non-superuser"
    end
  end

  test "a non-superuser cannot create, update or delete" do
    product = create_product
    sign_in create_account(superuser: false)

    post "/admin/products", params: { product: { name: "Nope" } }
    assert_response :not_found

    patch "/admin/products/#{product.id}", params: { product: { name: "Nope" } }
    assert_response :not_found

    delete "/admin/products/#{product.id}"
    assert_response :not_found

    assert_equal 1, Product.count, "nothing should have been written"
  end

  test "a superuser sees the product list" do
    create_product(name: "Listed Tee")
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Product"
    assert_select "body", text: /Listed Tee/
  end

  test "the list shows an empty state with no products" do
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "table", count: 0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: the two superuser tests fail because `/admin/products` is not routed. The three authorization tests pass vacuously — everything 404s when nothing is routed — and only become meaningful once the routes exist.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the existing `namespace :admin do` block, add below the `traffic` line:

```ruby
    resources :products, except: [ :show ]
```

- [ ] **Step 4: Add the Products tab**

Replace `app/views/admin/_tabs.html.erb`:

```erb
<%= render "shared/tab_nav",
      current: request.path,
      tabs: [
        [ "Overview", admin_root_path ],
        [ "Products", admin_products_path ],
        [ "Accounts", admin_accounts_path ],
        [ "Orders",   admin_orders_path ],
        [ "Traffic",  admin_traffic_path ]
      ] %>
```

- [ ] **Step 5: Write the controller with only index for now**

Create `app/controllers/admin/products_controller.rb`:

```ruby
module Admin
  class ProductsController < BaseController
    def index
      @products = Product.order(:name).all
    end
  end
end
```

The superuser gate is inherited from `Admin::BaseController`; no `before_action` is needed here.

- [ ] **Step 6: Build the index view**

Create `app/views/admin/products/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ALL", heading_bottom: "PRODUCTS." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Products", subtitle: "#{@products.size} total" } do %>
      <div class="mb-6">
        <%= link_to "New product", new_admin_product_path,
              class: "inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded" %>
      </div>

      <% if @products.empty? %>
        <%= render "shared/empty_state", message: "No products yet.", cta_label: "Add the first one", cta_path: new_admin_product_path %>
      <% else %>
        <%= render layout: "shared/data_table", locals: { headers: [ "", "Product", "Price", "Colours", "In stock", "Status", "" ] } do %>
          <% @products.each do |product| %>
            <tr>
              <td class="py-3 pr-6">
                <div class="w-10 h-10 rounded bg-gray-100 overflow-hidden flex items-center justify-center">
                  <% if product.image.present? %>
                    <%= image_tag product.image, alt: "", class: "w-full h-full object-cover" %>
                  <% end %>
                </div>
              </td>
              <td class="py-3 pr-6 font-bold"><%= product.name %></td>
              <td class="py-3 pr-6 whitespace-nowrap">
                <% low, high = product.price_range %>
                <%= low == high ? price(low) : "#{price(low)} – #{price(high)}" %>
              </td>
              <td class="py-3 pr-6">
                <div class="flex items-center gap-1">
                  <% product.colors.each do |color| %>
                    <span class="inline-block w-4 h-4 rounded-full border border-gray-300"
                          style="background-color: <%= product.swatch_for(color) %>"
                          title="<%= color %>"></span>
                  <% end %>
                </div>
              </td>
              <td class="py-3 pr-6 text-gray-600"><%= product.total_stock %></td>
              <td class="py-3 pr-6">
                <%= render "shared/status_badge",
                      label: product.active? ? "Active" : "Draft",
                      tone:  product.active? ? :green : :gray %>
              </td>
              <td class="py-3 text-right">
                <%= link_to "Edit", edit_admin_product_path(product.id),
                      class: "font-bold text-xs uppercase tracking-widest text-brand-green" %>
              </td>
            </tr>
          <% end %>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: 6 runs, 0 failures. The `new` and `edit` paths route but their actions do not exist yet — the authorization tests only assert redirect and 404, both of which the gate produces before any missing-action error, so they pass. `create`, `update` and `destroy` likewise 404 for a non-superuser because the gate runs first.

- [ ] **Step 8: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Add the admin product list

Inherits the superuser gate from Admin::BaseController, so every
product route 404s for a non-superuser before any action runs. Adds a
Products tab to the admin sub-nav."
```

---

### Task 6: Admin create

The heaviest task. The form is shared with Task 7's edit, and the grid reconciliation written here is reused by `update`.

**Files:**
- Modify: `app/controllers/admin/products_controller.rb`
- Create: `app/views/admin/products/_form.html.erb`, `app/views/admin/products/new.html.erb`
- Test: `test/integration/admin_products_test.rb`

**Interfaces:**
- Consumes: everything from Task 5.
- Produces:
  - Form parameter shape, which Task 7 reuses exactly:
    - `product[name]`, `product[slug]`, `product[description]`, `product[image]`, `product[base_price]`, `product[active]`
    - `colors[]` — array of palette names
    - `prices[<SIZE>]` — dollars as a string, one per size
    - `stock[<COLOR>][<SIZE>]` — integer as a string, one per cell
  - `Admin::ProductsController#rebuild_variants(product)` — private; deletes variants whose colour is no longer selected, then upserts a row per selected colour and size

- [ ] **Step 1: Write the failing test**

Append to `test/integration/admin_products_test.rb`, inside the class, before the final `end`:

```ruby
  def valid_params(overrides = {})
    {
      product: {
        name: "New Tee", slug: "new-tee", description: "Fresh.",
        image: "3crow.png", base_price: "12.00", active: "1"
      },
      colors: [ "Black", "White" ],
      prices: { "S" => "12.00", "M" => "12.00", "L" => "12.00",
                "XL" => "12.00", "2XL" => "14.00", "3XL" => "14.00" },
      stock: {
        "Black" => { "S" => "5", "M" => "6", "L" => "7", "XL" => "0", "2XL" => "1", "3XL" => "0" },
        "White" => { "S" => "2", "M" => "3", "L" => "4", "XL" => "0", "2XL" => "0", "3XL" => "0" }
      }
    }.deep_merge(overrides)
  end

  test "the new form renders for a superuser" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    assert_response :success
    assert_select "form"
    assert_select "input[name='colors[]']", count: Product::COLORS.size
    assert_select "input[name='prices[S]']"
    assert_select "input[name='stock[Black][S]']"
  end

  test "creating a product builds the whole variant grid" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params
    assert_redirected_to "/admin/products"

    product = Product.first(slug: "new-tee")
    assert product, "the product should exist"
    assert_equal 12, product.variants.count, "two colours by six sizes"
    assert_equal [ "Black", "White" ], product.colors
    assert_equal 1200, product.base_price_cents
  end

  test "prices are applied to every colour of a size" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal 1400, product.variants.find { |v| v.size == "2XL" && v.color == "Black" }.price_cents
    assert_equal 1400, product.variants.find { |v| v.size == "2XL" && v.color == "White" }.price_cents
    assert_equal 1200, product.variants.find { |v| v.size == "S" && v.color == "White" }.price_cents
  end

  test "stock is stored per cell" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal 5, product.stock_for(size: "S", color: "Black")
    assert_equal 2, product.stock_for(size: "S", color: "White")
    assert_equal 0, product.stock_for(size: "XL", color: "Black")
  end

  test "sizes are stored in ladder order" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal Product::SIZES, product.variants_for("Black").map(&:size)
  end

  test "creating without a colour re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(colors: [])
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_select "body", text: /at least one colour/i
  end

  test "an invalid product re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { name: "" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count, "no variants should be left behind"
  end

  test "a duplicate slug re-renders rather than raising" do
    create_product(slug: "taken")
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { slug: "taken" })
    assert_response :unprocessable_entity
    assert_equal 1, Product.count
  end

  test "the slug is derived from the name when left blank" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { name: "Big Loud Shirt", slug: "" })
    assert_redirected_to "/admin/products"
    assert Product.first(slug: "big-loud-shirt"), "expected a slug generated from the name"
  end
```

`valid_params(colors: [])` relies on `deep_merge`; passing an empty array replaces the key outright, which is what we want.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: the nine new tests fail with `AbstractController::ActionNotFound` or a routing error for `new` and `create`. The six from Task 5 still pass.

- [ ] **Step 3: Add new, create and the private helpers**

Replace `app/controllers/admin/products_controller.rb`:

```ruby
module Admin
  class ProductsController < BaseController
    def index
      @products = Product.order(:name).all
    end

    def new
      @product = Product.new(base_price_cents: 1200, active: true)
      @selected_colors = [ "Black" ]
      @prices = Product::SIZES.index_with(1200)
      @stock  = {}
      render :new
    end

    def create
      @product = Product.new(product_attributes)
      @selected_colors = selected_colors
      @prices = submitted_prices
      @stock  = submitted_stock

      if @selected_colors.empty?
        @product.errors.add(:colors, "must include at least one colour")
        return render :new, status: :unprocessable_entity
      end

      unless @product.valid?
        return render :new, status: :unprocessable_entity
      end

      Product.db.transaction do
        @product.save
        rebuild_variants(@product)
      end

      redirect_to admin_products_path, notice: "#{@product.name} created."
    end

    private

    def product_attributes
      attributes = params.require(:product)
      name = attributes[:name].to_s.strip
      slug = attributes[:slug].to_s.strip.presence || name.parameterize

      {
        name: name,
        slug: slug,
        description: attributes[:description].to_s.strip,
        image: attributes[:image].to_s.strip.presence,
        base_price_cents: cents(attributes[:base_price]),
        active: attributes[:active] == "1"
      }
    end

    # Only palette colours are accepted, so a hand-crafted request cannot
    # introduce a colour the shop does not stock.
    def selected_colors
      Array(params[:colors]).map(&:to_s).select { |color| Product::COLORS.key?(color) }
    end

    def submitted_prices
      Product::SIZES.index_with { |size| cents(params.dig(:prices, size)) }
    end

    def submitted_stock
      selected_colors.index_with do |color|
        Product::SIZES.index_with { |size| params.dig(:stock, color, size).to_i.clamp(0, 1_000_000) }
      end
    end

    # Deletes rows for colours no longer selected, then upserts one row per
    # selected colour and size. Callers must wrap this in a transaction.
    def rebuild_variants(product)
      colors = selected_colors
      prices = submitted_prices
      stock  = submitted_stock

      product.variants_dataset.exclude(color: colors).delete

      colors.each do |color|
        Product::SIZES.each_with_index do |size, index|
          variant = ProductVariant.first(product_id: product.id, size: size, color: color) ||
                    ProductVariant.new(product_id: product.id, size: size, color: color)
          variant.set(
            price_cents: prices.fetch(size),
            stock: stock.dig(color, size).to_i,
            position: index
          )
          variant.save
        end
      end

      product.refresh
    end

    def cents(value)
      digits = value.to_s.gsub(/[^0-9.]/, "")
      return 0 if digits.blank?

      (BigDecimal(digits) * 100).round
    rescue ArgumentError
      0
    end
  end
end
```

`product.refresh` at the end of `rebuild_variants` clears the cached `variants` association, so anything reading the product afterwards sees the new rows.

- [ ] **Step 4: Build the form partial**

Create `app/views/admin/products/_form.html.erb`:

```erb
<%= form_with url: form_url, method: form_method, data: { turbo: false }, class: "space-y-8" do %>
  <% if @product.errors.any? %>
    <div class="border-2 border-brand-orange rounded-lg p-4">
      <p class="font-bold text-sm uppercase tracking-widest text-brand-orange">Could not save</p>
      <ul class="mt-2 space-y-1 text-sm text-gray-700">
        <% @product.errors.each do |field, messages| %>
          <% Array(messages).each do |message| %>
            <li><%= "#{field.to_s.humanize} #{message}" %></li>
          <% end %>
        <% end %>
      </ul>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Details" } do %>
    <div class="grid sm:grid-cols-2 gap-4">
      <div class="sm:col-span-2">
        <label for="product_name" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Name</label>
        <input id="product_name" name="product[name]" type="text" value="<%= @product.name %>"
               class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
      </div>

      <div class="sm:col-span-2">
        <label for="product_slug" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Slug</label>
        <input id="product_slug" name="product[slug]" type="text" value="<%= @product.slug %>" placeholder="left blank, generated from the name"
               class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
      </div>

      <div class="sm:col-span-2">
        <label for="product_description" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Description</label>
        <textarea id="product_description" name="product[description]" rows="3"
                  class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40"><%= @product.description %></textarea>
      </div>

      <div>
        <label for="product_image" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Image filename</label>
        <input id="product_image" name="product[image]" type="text" value="<%= @product.image %>" placeholder="3crow.png"
               class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
        <p class="mt-1 text-xs text-gray-500">A file in <code>app/assets/images/</code>.</p>
      </div>

      <div>
        <label for="product_base_price" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Base price</label>
        <input id="product_base_price" name="product[base_price]" type="text" value="<%= '%.2f' % ((@product.base_price_cents || 0) / 100.0) %>"
               class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
      </div>

      <div class="sm:col-span-2">
        <label class="flex items-center gap-3 text-sm">
          <input type="hidden" name="product[active]" value="0">
          <input type="checkbox" name="product[active]" value="1" class="accent-brand-green" <%= "checked" if @product.active %>>
          Visible in the shop
        </label>
      </div>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Colours" } do %>
    <p class="mb-4 text-sm text-brand-orange font-bold">
      Unticking a colour deletes its stock counts. Re-ticking it starts that colour back at zero.
    </p>
    <div class="grid sm:grid-cols-3 gap-3">
      <% Product::COLORS.each do |color, hex| %>
        <label class="flex items-center gap-3 p-3 border-2 border-gray-200 rounded-lg cursor-pointer">
          <input type="checkbox" name="colors[]" value="<%= color %>" class="accent-brand-green"
                 data-variant-grid-target="colorToggle" data-color="<%= color %>"
                 data-action="change->variant-grid#refresh"
                 <%= "checked" if @selected_colors.include?(color) %>>
          <span class="inline-block w-5 h-5 rounded-full border border-gray-300" style="background-color: <%= hex %>"></span>
          <span class="font-bold text-sm"><%= color %></span>
        </label>
      <% end %>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Price by size", subtitle: "Applied to every colour of that size" } do %>
    <div class="grid sm:grid-cols-3 gap-4">
      <% Product::SIZES.each do |size| %>
        <div>
          <label for="price_<%= size %>" class="block text-xs font-bold uppercase tracking-widest text-gray-500"><%= size %></label>
          <input id="price_<%= size %>" name="prices[<%= size %>]" type="text"
                 value="<%= '%.2f' % ((@prices[size] || 0) / 100.0) %>"
                 class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
        </div>
      <% end %>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Stock", subtitle: "Units on hand per size and colour" } do %>
    <div class="overflow-x-auto" data-controller="variant-grid">
      <table class="w-full text-left text-sm">
        <thead>
          <tr class="border-b-2 border-brand-green">
            <th class="py-3 pr-6 text-xs font-bold uppercase tracking-widest text-gray-500">Size</th>
            <% Product::COLORS.each_key do |color| %>
              <th class="py-3 pr-6 text-xs font-bold uppercase tracking-widest text-gray-500 whitespace-nowrap"
                  data-variant-grid-target="column" data-color="<%= color %>"><%= color %></th>
            <% end %>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200">
          <% Product::SIZES.each do |size| %>
            <tr>
              <td class="py-3 pr-6 font-bold"><%= size %></td>
              <% Product::COLORS.each_key do |color| %>
                <td class="py-3 pr-6" data-variant-grid-target="column" data-color="<%= color %>">
                  <input name="stock[<%= color %>][<%= size %>]" type="number" min="0" step="1"
                         value="<%= @stock.dig(color, size) || 0 %>"
                         class="w-20 px-2 py-1 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>

  <div class="flex flex-wrap items-center gap-4">
    <button type="submit"
            class="inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-8 py-3 rounded">
      <%= submit_label %> <span aria-hidden="true">&rarr;</span>
    </button>
    <%= link_to "Cancel", admin_products_path, class: "text-xs font-bold uppercase tracking-widest text-gray-500" %>
  </div>
<% end %>
```

Every palette colour gets a stock column. Task 8 hides the unselected ones; until then they all show, and the controller ignores columns whose colour was not ticked.

- [ ] **Step 5: Build the new page**

Create `app/views/admin/products/new.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "NEW", heading_bottom: "PRODUCT." %>

  <%= render "admin/tabs" %>

  <section class="max-w-4xl mx-auto px-6 py-12">
    <%= render "form", form_url: admin_products_path, form_method: :post, submit_label: "Create product" %>
  </section>
</div>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: 15 runs, 0 failures.

- [ ] **Step 7: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add admin product creation

One form: details, colour checkboxes, six prices by size, and a size
by colour stock grid. Price is entered once per size and applied to
every colour, because colour does not change what a shirt costs;
stock is the only genuinely per-SKU number.

The product and its whole grid are written in one transaction, so a
validation failure cannot leave a half-built grid behind. Only palette
colours are accepted, so a hand-crafted request cannot introduce a
colour the shop does not stock."
```

---

### Task 7: Admin edit, update and delete

**Files:**
- Modify: `app/controllers/admin/products_controller.rb`
- Create: `app/views/admin/products/edit.html.erb`
- Test: `test/integration/admin_products_test.rb`

**Interfaces:**
- Consumes: the form partial, parameter shape and `rebuild_variants` from Task 6.
- Produces: no new interfaces.

- [ ] **Step 1: Write the failing test**

Append to `test/integration/admin_products_test.rb`, inside the class, before the final `end`:

```ruby
  def create_two_color_product
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params
    Product.first(slug: "new-tee")
  end

  test "the edit form is prefilled from the product" do
    product = create_two_color_product

    get "/admin/products/#{product.id}/edit"
    assert_response :success
    assert_select "input[name='product[name]'][value=?]", "New Tee"
    assert_select "input[name='colors[]'][value='Black'][checked]"
    assert_select "input[name='colors[]'][value='White'][checked]"
    assert_select "input[name='colors[]'][value='Red'][checked]", count: 0
    assert_select "input[name='stock[Black][S]'][value=?]", "5"
  end

  test "updating a price applies it to every colour of that size" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(prices: { "S" => "19.50" })
    assert_redirected_to "/admin/products"

    product.refresh
    assert_equal 1950, product.variants.find { |v| v.size == "S" && v.color == "Black" }.price_cents
    assert_equal 1950, product.variants.find { |v| v.size == "S" && v.color == "White" }.price_cents
  end

  test "updating one stock cell leaves the others alone" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(stock: { "Black" => { "M" => "99" } })

    product.refresh
    assert_equal 99, product.stock_for(size: "M", color: "Black")
    assert_equal 5,  product.stock_for(size: "S", color: "Black")
    assert_equal 3,  product.stock_for(size: "M", color: "White")
  end

  test "adding a colour creates its six sizes at zero stock" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(colors: [ "Black", "White", "Red" ])

    product.refresh
    assert_equal 18, product.variants.count
    assert_equal [ "Black", "White", "Red" ], product.colors
    assert_equal 0, product.stock_for(size: "S", color: "Red")
  end

  test "removing a colour deletes its rows" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(colors: [ "Black" ])

    product.refresh
    assert_equal 6, product.variants.count
    assert_equal [ "Black" ], product.colors
    assert_equal 0, ProductVariant.where(product_id: product.id, color: "White").count
  end

  test "updating to an invalid product writes nothing" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(product: { name: "" })
    assert_response :unprocessable_entity

    product.refresh
    assert_equal "New Tee", product.name
    assert_equal 12, product.variants.count
  end

  test "updating with no colours selected writes nothing" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(colors: [])
    assert_response :unprocessable_entity

    product.refresh
    assert_equal 12, product.variants.count, "the grid should be untouched"
  end

  test "deleting a product takes its variants with it" do
    product = create_two_color_product

    delete "/admin/products/#{product.id}"
    assert_redirected_to "/admin/products"

    assert_nil Product[product.id]
    assert_equal 0, ProductVariant.where(product_id: product.id).count
  end

  test "editing an unknown product is a 404" do
    sign_in create_account(superuser: true)

    get "/admin/products/999999/edit"
    assert_response :not_found
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: the nine new tests fail with `AbstractController::ActionNotFound` for `edit`, `update` and `destroy`. The fifteen earlier tests still pass.

- [ ] **Step 3: Add edit, update and destroy**

In `app/controllers/admin/products_controller.rb`, insert these three actions after `create` and before `private`:

```ruby
    def edit
      @product = find_product!
      @selected_colors = @product.colors
      @prices = Product::SIZES.index_with do |size|
        @product.variants.find { |variant| variant.size == size }&.price_cents || @product.base_price_cents
      end
      @stock = @product.colors.index_with do |color|
        Product::SIZES.index_with { |size| @product.stock_for(size: size, color: color) }
      end
    end

    def update
      @product = find_product!
      @product.set(product_attributes)
      @selected_colors = selected_colors
      @prices = submitted_prices
      @stock  = submitted_stock

      if @selected_colors.empty?
        @product.errors.add(:colors, "must include at least one colour")
        return render :edit, status: :unprocessable_entity
      end

      unless @product.valid?
        return render :edit, status: :unprocessable_entity
      end

      Product.db.transaction do
        @product.save
        rebuild_variants(@product)
      end

      redirect_to admin_products_path, notice: "#{@product.name} updated."
    end

    def destroy
      product = find_product!
      name = product.name
      product.destroy

      redirect_to admin_products_path, notice: "#{name} deleted."
    end
```

And add this to the private section, directly under `private`:

```ruby
    # A 404 rather than a redirect, matching how the admin gate hides itself.
    def find_product!
      Product[params[:id].to_i] or raise ActionController::RoutingError, "Not Found"
    end
```

A failed `update` re-renders `:edit`, and `@product` still holds the rejected values in memory, so the form shows what the user typed rather than what is in the database. The `product.refresh` in the tests re-reads the row to prove nothing was written.

- [ ] **Step 4: Build the edit page**

Create `app/views/admin/products/edit.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "EDIT", heading_bottom: "PRODUCT." %>

  <%= render "admin/tabs" %>

  <section class="max-w-4xl mx-auto px-6 py-12 space-y-8">
    <%= render "form",
          form_url: admin_product_path(@product.id),
          form_method: :patch,
          submit_label: "Save changes" %>

    <div class="pt-8 border-t-2 border-gray-200">
      <%= button_to "Delete this product", admin_product_path(@product.id),
            method: :delete,
            form: { data: { turbo: false } },
            class: "text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-brand-orange underline decoration-2 underline-offset-4" %>
      <p class="mt-2 text-xs text-gray-500">
        Deletes the product and all of its stock records. Untick “Visible in the shop” instead to hide it without losing data.
      </p>
    </div>
  </section>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: 24 runs, 0 failures.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add admin product editing and deletion

Edit prefills prices and stock from the existing grid. Update
reconciles colours: adding one creates six rows at zero stock,
removing one deletes its rows and their counts. Both run in a
transaction, so a rejected edit leaves the grid untouched.

Delete is a hard delete and says so next to the button, pointing at
the visibility toggle as the non-destructive alternative."
```

---

### Task 8: Progressive enhancement

Two small Stimulus controllers. Both pages already work without them — this task only reduces noise.

**Files:**
- Create: `app/javascript/controllers/variant_grid_controller.js`, `app/javascript/controllers/color_switcher_controller.js`
- Modify: `app/views/shop/show.html.erb`
- Test: `test/integration/shop_test.rb`

**Interfaces:**
- Consumes: the `data-variant-grid-target="column"` and `data-color` attributes already emitted by the form in Task 6; the `data-color-section` attributes already emitted by `shop/show` in Task 4.
- Produces: no server-side interfaces.

Note: `app/javascript/controllers/index.js` uses `eagerLoadControllersFrom`, which discovers controllers from the importmap automatically. There is no registration list to edit — creating the files is the whole job.

- [ ] **Step 1: Write the failing test**

Append to `test/integration/shop_test.rb`, inside the class, before the final `end`:

```ruby
  test "a multi colour product renders a colour switcher" do
    create_product(slug: "switch", colors: [ "Black", "Red" ])

    get "/shop/switch"
    assert_select "[data-controller='color-switcher']"
    assert_select "button[data-color='Black']"
    assert_select "button[data-color='Red']"
  end

  test "a single colour product renders a label rather than a switcher" do
    create_product(slug: "single", colors: [ "Black" ])

    get "/shop/single"
    assert_select "[data-controller='color-switcher']", count: 0
    assert_select "button[data-color]", count: 0
    assert_select "body", text: /Black/
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/shop_test.rb -n "/colour switcher|single colour product renders a label/"`
Expected: the first fails with `Expected at least 1 element matching "[data-controller='color-switcher']", found 0`. The second passes already, since no switcher exists anywhere yet.

- [ ] **Step 3: Write the admin grid controller**

Create `app/javascript/controllers/variant_grid_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Hides stock columns for colours that are not ticked. The form works without
// this -- every column renders and the server ignores unticked colours -- so
// this only reduces noise.
export default class extends Controller {
  static targets = ["column"]

  connect() {
    this.refresh()
  }

  refresh() {
    const selected = new Set(
      Array.from(document.querySelectorAll("input[name='colors[]']:checked")).map((input) => input.value)
    )

    this.columnTargets.forEach((cell) => {
      cell.classList.toggle("hidden", !selected.has(cell.dataset.color))
    })
  }
}
```

The colour checkboxes live outside the grid's element, so `refresh` queries the document rather than using a target. They already carry `data-action="change->variant-grid#refresh"` from Task 6, which Stimulus routes to this controller by name.

- [ ] **Step 4: Write the shop colour switcher**

Create `app/javascript/controllers/color_switcher_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Shows one colour's size ladder at a time. Without JavaScript every section
// stays visible, which is correct, just longer.
export default class extends Controller {
  static targets = ["section", "button"]

  connect() {
    this.show(this.sectionTargets[0]?.dataset?.color)
  }

  select(event) {
    this.show(event.currentTarget.dataset.color)
  }

  show(color) {
    if (!color) return

    this.sectionTargets.forEach((section) => {
      section.classList.toggle("hidden", section.dataset.color !== color)
    })

    this.buttonTargets.forEach((button) => {
      const active = button.dataset.color === color
      button.classList.toggle("border-brand-green", active)
      button.classList.toggle("border-gray-200", !active)
    })
  }
}
```

- [ ] **Step 5: Add the switcher to the product page**

In `app/views/shop/show.html.erb`, replace the whole `<div class="mt-8 space-y-8">` block (the one containing `@product.colors.each`) with:

```erb
      <div class="mt-8 space-y-8" data-controller="<%= "color-switcher" if @product.colors.many? %>">
        <% if @product.colors.many? %>
          <div class="flex flex-wrap gap-3">
            <% @product.colors.each do |color| %>
              <button type="button"
                      data-color="<%= color %>"
                      data-color-switcher-target="button"
                      data-action="click->color-switcher#select"
                      class="flex items-center gap-2 px-3 py-2 border-2 border-gray-200 rounded-lg text-sm font-bold">
                <span class="inline-block w-4 h-4 rounded-full border border-gray-300"
                      style="background-color: <%= @product.swatch_for(color) %>"></span>
                <%= color %>
              </button>
            <% end %>
          </div>
        <% else %>
          <div class="flex items-center gap-3">
            <span class="inline-block w-5 h-5 rounded-full border border-gray-300"
                  style="background-color: <%= @product.swatch_for(@product.colors.first) %>"></span>
            <span class="font-bold text-sm"><%= @product.colors.first %></span>
          </div>
        <% end %>

        <% @product.colors.each do |color| %>
          <div data-color-section data-color="<%= color %>" data-color-switcher-target="section">
            <% if @product.colors.many? %>
              <div class="flex items-center gap-3">
                <span class="inline-block w-6 h-6 rounded-full border border-gray-300"
                      style="background-color: <%= @product.swatch_for(color) %>"></span>
                <h2 class="font-display text-xl tracking-wide uppercase"><%= color %></h2>
              </div>
            <% end %>

            <ul class="mt-4 space-y-2">
              <% @product.variants_for(color).each do |variant| %>
                <% sold_out = variant.stock.zero? %>
                <li class="flex items-center justify-between gap-4 text-sm py-2 border-b border-gray-200
                           <%= "text-gray-400" if sold_out %>"
                    <%= "data-sold-out" if sold_out %>>
                  <span class="font-bold <%= "line-through" if sold_out %>"><%= variant.size %></span>
                  <span class="<%= "line-through" if sold_out %>"><%= price(variant.price_cents) %></span>
                  <span class="text-xs uppercase tracking-widest">
                    <%= sold_out ? "Sold out" : "In stock" %>
                  </span>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
```

A single-colour product renders no `data-controller`, so Stimulus does nothing and the one section stays visible.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/integration/shop_test.rb`
Expected: 10 runs, 0 failures.

- [ ] **Step 7: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop && bin/brakeman --no-pager`
Expected: whole suite green, 0 offenses, brakeman exit 0.

- [ ] **Step 8: Verify in a browser**

```bash
bin/rails db:seed
bin/dev
```

`bin/dev` must run in a real terminal — its Tailwind watcher exits without a TTY and takes the server down with it. This run is also what compiles the new utility classes these pages introduce.

Check at desktop width and at 390px:

- `/shop` — three products, swatch rows on the two multi-colour ones
- `/shop/3-crow` — three colour buttons, one ladder at a time, sizes priced $12 and $14
- `/shop/see-that-shit` — 3XL struck through as sold out in both colours
- `/shop/third-eye-smiley` — a colour label, no buttons
- `/admin/products` — three rows with thumbnails, price ranges, swatches and stock totals
- `/admin/products/new` — stock columns appear and disappear as colours are ticked
- Edit a product, change a price and a stock cell, save, confirm the list updates

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Add progressive enhancement for the variant grid and colour switcher

Two Stimulus controllers, both optional. The admin grid hides stock
columns for unticked colours; the product page shows one colour's size
ladder at a time. Without JavaScript both pages render everything,
which is correct and only longer. Single colour products render a
label and no controller at all."
```

---

## Self-Review Notes

Checked against the spec:

- **Two tables, SKU per size and colour** — Task 1, including the NOT NULL colour and the unique index.
- **Fixed size and colour vocabularies** — Task 1 (`SIZES`, `COLORS`, `NEUTRAL_SWATCH`).
- **Derived readers so views do no arithmetic** — Task 2, all eight.
- **`published` scope named to avoid colliding with `#active?`** — Task 2.
- **Price helper** — Task 3.
- **Sample data covering three, two and one colour** — Task 3, with varied stock and a sold-out size.
- **Public catalog, 404 for inactive** — Task 4.
- **Nav link** — Task 4, replacing the inert "Store" text rather than adding a sixth item.
- **Admin list with swatches and stock totals** — Task 5.
- **Admin tab** — Task 5.
- **Form: details, colours, price by size, stock grid** — Task 6.
- **Price entered once per size, applied across colours** — Task 6, asserted directly in both create and update tests.
- **Transaction around product plus grid** — Tasks 6 and 7.
- **Colour reconciliation, including the destructive removal** — Task 7, with the warning rendered in the form in Task 6.
- **Hard delete with the visibility toggle offered as the alternative** — Task 7.
- **Stimulus enhancement with a working no-JavaScript fallback** — Task 8.
- **Browser verification** — Task 8, Step 8.

Three places this plan is more specific than the spec:

1. The spec says the admin form hides unselected colour columns. The plan renders every column server-side and hides them in the browser, so the form is correct with JavaScript disabled and the server ignores columns for colours that were not ticked. This is the only shape that does not require the server to know what the browser is showing.
2. The spec does not say what happens to a blank slug. The plan derives it from the name via `parameterize`, and Task 6 tests that.
3. The spec does not name the parameter shape. Task 6 fixes it exactly — `colors[]`, `prices[SIZE]`, `stock[COLOR][SIZE]` — because Task 7 reuses it and a mismatch between the two would be invisible until the update tests fail.

Two things worth flagging to whoever executes this:

- **`Product.create` raises**, it does not return false. Tests assert `assert_raises(Sequel::ValidationFailed)`, and controllers call `#valid?` first. Anyone reaching for `if product.save` will be surprised.
- **`product.refresh` is load-bearing** in `rebuild_variants` and throughout the update tests. Sequel caches the `variants` association after first access, so without a refresh the assertions read a stale array and fail in ways that look like the write did not happen.
