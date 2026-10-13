# Flexible Product Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed size × colour variant grid with per-product options (zero to three, any names, any values), so the shop can sell simple items like stickers, one-offs, and apparel with custom options, with price on the product and an optional per-variant price override.

**Architecture:** Four tables replace one. `product_options` and `option_values` belong to a product, `product_variants` holds one row per combination of values, and `variant_option_values` joins them. A unique `options_key` per product makes duplicate combinations impossible. A plain Ruby `ProductEditor` turns the admin form into rows inside one transaction. It derives the variant set from the options, refuses to delete stock without confirmation, and keeps the controller thin. Views are server-rendered and work without JavaScript. Three small Stimulus controllers add conveniences.

**Tech Stack:** Rails 8, Sequel (not ActiveRecord), PostgreSQL, Minitest integration and model tests, Stimulus via importmap, Tailwind.

**Spec:** `docs/superpowers/specs/2026-10-13-flexible-product-options-design.md`

## Global Constraints

- Work on a branch, not `master`: `git switch -c ms-product-options` before Task 1.
- Sequel, not ActiveRecord. Models subclass `Sequel::Model`. Migrations are `Sequel.migration do ... end`.
- Money is integer cents everywhere. Malformed money input is an error, never zero.
- Run tests as `bin/rails test <path>`. The full suite is `bin/rails test test/`, never bare `bin/rails test`.
- The full suite takes ~400s against a shared remote database. Run it in the background and never run two test processes at once, from any session or agent. Concurrent runs delete each other's rows and produce fake failures.
- Do not remove the `setup_fixtures` / `teardown_fixtures` overrides in `test/test_helper.rb`.
- Do not run `bin/rails tailwindcss:build`. The `bin/dev` watcher compiles CSS.
- `bin/rubocop` and `bin/brakeman --no-pager` must exit 0 at the end of every task.
- Every test that creates products deletes them in teardown with `Product.dataset.delete`. The foreign keys cascade to everything else.
- `Product::MAX_OPTIONS = 3`, `Product::MAX_VARIANTS = 100`, `ProductEditor::MAX_STOCK = 1_000_000`.
- The association is `option_values`, never `values`, because `Sequel::Model#values` is the built-in column hash.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Between Task 1 and Task 7, `/shop` and `/admin/products` are broken at runtime.** Task 1 replaces the model those pages read, and Tasks 5–7 rebuild them. Task 1 deletes the three test files that covered the old pages, and their replacements arrive in Tasks 4, 5 and 7. The branch is not mergeable until Task 8 is done.

## Review Focus

1. **Saving the edit form unchanged must change nothing**, including variant ids, stock, positions and swatches. A reasonable admin clicks Save without editing. *Pinned in Task 2 (`saving the edit form unchanged changes nothing`) and Task 5 (`an unchanged save goes back to the list and changes nothing`).*
2. **Whitespace and case in names must not create duplicates or replace variants.** `"  BLACK "` on an existing `Black` is the same value with a new spelling. *Pinned in Task 2 (`names are trimmed, and values are matched to existing rows ignoring case`).*
3. **Replacing an option on a product already at three options must work.** The cap must not count the option being removed. *Pinned in Task 2 (`replacing an option on a product already at the limit works`).*
4. **The same SKU typed on two variants in one save must produce an error, not a 500.** *Pinned in Task 3 (`the same SKU on two variants in one save is an error, not a crash`).*
5. **Markup in option and value names must render as text.** Admins type names freely, and they reach the public page and a JSON data attribute. *Pinned in Task 7 (`markup in a value name is shown as text`).*

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `db/migrate/20261013120000_rebuild_products_with_options.rb` | Drop and recreate the product tables in the new shape | 1 |
| `app/models/product.rb` | Product, its scope and derived readers | 1 |
| `app/models/product_option.rb` | One option (Size, Colour…) of one product | 1 |
| `app/models/option_value.rb` | One value of one option, with swatch and photo | 1 |
| `app/models/product_variant.rb` | One combination, with stock, override and SKU | 1 |
| `app/models/product_editor.rb` | Form params → rows, in one transaction | 2, 3 |
| `test/test_helper.rb` | `build_product`, `form_params_for` and friends | 2 |
| `db/seeds.rb` | Three shirts and a sticker, built through `ProductEditor` | 4 |
| `app/controllers/admin/products_controller.rb` | Thin wrapper around `ProductEditor` | 5 |
| `app/views/admin/products/{index,new,edit,_form}.html.erb` | Admin pages | 5 |
| `app/views/admin/products/{_variants,_pending_loss}.html.erb` | Variant table and stock-loss confirmation | 6 |
| `app/views/shared/_swatch.html.erb` | One swatch dot (hex or image) | 5 |
| `app/helpers/application_helper.rb` | `asset_url_if_exists`, `product_image_tag` | 5 |
| `app/helpers/shop_helper.rb` | `price_label`, picker JSON | 7 |
| `app/controllers/shop_controller.rb`, `app/views/shop/{index,show}.html.erb` | Public catalog | 7 |
| `app/javascript/controllers/{variant_picker,option_editor,variant_filter}_controller.js` | Progressive enhancement | 8 |
| `app/javascript/controllers/{color_switcher,variant_grid}_controller.js` | Deleted | 8 |

---

### Task 1: Schema and models

**Files:**
- Create: `db/migrate/20261013120000_rebuild_products_with_options.rb`
- Create: `app/models/product_option.rb`, `app/models/option_value.rb`
- Modify (rewrite): `app/models/product.rb`, `app/models/product_variant.rb`
- Modify: `db/schema.rb` (regenerated), `db/seeds.rb` (product section removed)
- Test (rewrite): `test/models/product_test.rb`
- Delete: `test/integration/admin_products_test.rb`, `test/integration/shop_test.rb`, `test/models/seeds_test.rb`

**Interfaces:**
- Produces:
  - `Product` columns `name, slug, description, image, price_cents, active, created_at, updated_at`. `Product::MAX_OPTIONS`, `Product::MAX_VARIANTS`. `Product.published`, `Product.asset_exists?(filename) -> bool`. `#options` (ordered by position), `#variants` (ordered by position), `#simple? -> bool`, `#price_range -> [Integer, Integer]`, `#in_stock? -> bool`, `#total_stock -> Integer`, `#swatch_option -> ProductOption | nil`.
  - `ProductOption` columns `product_id, name, position`. `#product`, `#option_values` (ordered by position).
  - `OptionValue` columns `product_option_id, name, position, swatch_hex, swatch_image, image`. `#product_option`, `#swatch? -> bool`.
  - `ProductVariant` columns `product_id, options_key, price_override_cents, stock, sku, position`. `ProductVariant.key_for(Array<Integer>) -> String`. `#product`, `#option_values`, `#price_cents -> Integer`, `#sold_out? -> bool`, `#value_for(option) -> OptionValue | nil`, `#label -> String`.
  - Table `variant_option_values(product_variant_id, option_value_id)`.

- [ ] **Step 1: Create the branch**

```bash
git switch -c ms-product-options
```

- [ ] **Step 2: Write the failing model tests**

Replace all of `test/models/product_test.rb` with:

```ruby
require "test_helper"

class ProductTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def make_product(**overrides)
    Product.create({
      name: "Test Tee", slug: "test-tee-#{SecureRandom.hex(4)}", description: "A shirt.",
      image: "3crow.png", price_cents: 1200, active: true
    }.merge(overrides))
  end

  # values are names, or hashes of option value columns.
  def make_option(product, name, values, position: 0)
    option = ProductOption.create(product_id: product.id, name: name, position: position)
    values.each_with_index do |value, index|
      fields = value.is_a?(Hash) ? value : { name: value }
      OptionValue.create({ product_option_id: option.id, position: index }.merge(fields))
    end
    option.refresh
  end

  def make_variant(product, values, stock: 5, override: nil, position: 0, sku: nil)
    variant = ProductVariant.create(
      product_id: product.id, options_key: ProductVariant.key_for(values.map(&:id)),
      stock: stock, price_override_cents: override, position: position, sku: sku
    )
    values.each { |value| variant.add_option_value(value) }
    variant
  end

  def value(option, name)
    option.option_values.find { |candidate| candidate.name == name }
  end

  test "a product can be created" do
    product = make_product
    assert product.id
    assert_equal true, product.active?
  end

  test "slug must be unique" do
    make_product(slug: "taken")
    assert_raises(Sequel::ValidationFailed) { make_product(slug: "taken") }
  end

  test "slug must be lowercase letters, numbers and dashes" do
    assert_raises(Sequel::ValidationFailed) { make_product(slug: "Not A Slug") }
  end

  test "name is required" do
    assert_raises(Sequel::ValidationFailed) { make_product(name: nil) }
  end

  test "price cannot be negative" do
    assert_raises(Sequel::ValidationFailed) { make_product(price_cents: -1) }
  end

  test "image must resolve to a real asset, and may be blank" do
    assert_raises(Sequel::ValidationFailed) { make_product(image: "definitely_missing.png") }
    assert make_product(image: nil).id
  end

  test "published returns only active products, ordered by name" do
    make_product(name: "Zebra", slug: "zebra")
    make_product(name: "Apple", slug: "apple")
    make_product(name: "Hidden", slug: "hidden", active: false)

    assert_equal [ "Apple", "Zebra" ], Product.published.select_map(:name)
  end

  test "option names are unique per product but may repeat across products" do
    a = make_product
    b = make_product
    make_option(a, "Size", [ "S" ])

    assert_raises(Sequel::ValidationFailed) { make_option(a, "Size", [ "M" ], position: 1) }
    assert make_option(b, "Size", [ "S" ]).id
  end

  test "a product may have at most three options" do
    product = make_product
    3.times { |i| make_option(product, "Option #{i}", [ "x" ], position: i) }

    assert_raises(Sequel::ValidationFailed) { make_option(product, "One too many", [ "x" ], position: 3) }
  end

  test "value names are unique within an option" do
    option = make_option(make_product, "Colour", [ "Black" ])
    assert_raises(Sequel::ValidationFailed) do
      OptionValue.create(product_option_id: option.id, name: "Black", position: 1)
    end
  end

  test "a swatch hex must be a six digit colour" do
    product = make_product
    assert_raises(Sequel::ValidationFailed) { make_option(product, "A", [ { name: "x", swatch_hex: "black" } ]) }
    assert_raises(Sequel::ValidationFailed) { make_option(product, "B", [ { name: "x", swatch_hex: "#12345" } ], position: 1) }
    assert make_option(product, "C", [ { name: "x", swatch_hex: "#0D1114" } ], position: 2).id
  end

  test "a swatch image and a value photo must resolve to real assets" do
    product = make_product
    assert_raises(Sequel::ValidationFailed) { make_option(product, "A", [ { name: "x", swatch_image: "nope.png" } ]) }
    assert_raises(Sequel::ValidationFailed) { make_option(product, "B", [ { name: "x", image: "nope.png" } ], position: 1) }
    assert make_option(product, "C", [ { name: "x", swatch_image: "3crow.png", image: "3crow.png" } ], position: 2).id
  end

  test "swatch? is true for a hex or an image and false for neither" do
    option = make_option(make_product, "Colour", [
      { name: "Hex", swatch_hex: "#0d1114" }, { name: "Image", swatch_image: "3crow.png" }, "Plain"
    ])

    assert value(option, "Hex").swatch?
    assert value(option, "Image").swatch?
    refute value(option, "Plain").swatch?
  end

  test "a nil options key is rejected, but the empty key of a simple variant is allowed" do
    product = make_product
    assert_raises(Sequel::ValidationFailed) do
      ProductVariant.create(product_id: product.id, options_key: nil, stock: 0, position: 0)
    end
    assert ProductVariant.create(product_id: product.id, options_key: "", stock: 0, position: 0).id
  end

  test "the same combination cannot repeat on one product" do
    product = make_product
    size = make_option(product, "Size", [ "M" ])
    make_variant(product, [ value(size, "M") ])

    assert_raises(Sequel::ValidationFailed) { make_variant(product, [ value(size, "M") ], position: 1) }
  end

  test "stock and price override cannot be negative" do
    product = make_product
    size = make_option(product, "Size", [ "S", "M" ])

    assert_raises(Sequel::ValidationFailed) { make_variant(product, [ value(size, "S") ], stock: -1) }
    assert_raises(Sequel::ValidationFailed) { make_variant(product, [ value(size, "M") ], override: -1) }
  end

  test "a SKU is unique when present, and any number of variants may have none" do
    product = make_product
    size = make_option(product, "Size", [ "S", "M", "L" ])
    make_variant(product, [ value(size, "S") ], sku: nil)
    make_variant(product, [ value(size, "M") ], sku: "CROW-M", position: 1)

    assert_raises(Sequel::ValidationFailed) { make_variant(product, [ value(size, "L") ], sku: "CROW-M", position: 2) }
    assert make_variant(product, [ value(size, "L") ], sku: nil, position: 2).id
  end

  test "price_cents is the override when there is one, else the product price" do
    product = make_product(price_cents: 1200)
    size = make_option(product, "Size", [ "S", "2XL" ])
    plain = make_variant(product, [ value(size, "S") ])
    big = make_variant(product, [ value(size, "2XL") ], override: 1400, position: 1)

    assert_equal 1200, plain.price_cents
    assert_equal 1400, big.price_cents
  end

  test "price_range spans effective prices and falls back to the product price" do
    product = make_product(price_cents: 1200)
    assert_equal [ 1200, 1200 ], product.price_range

    size = make_option(product, "Size", [ "S", "2XL" ])
    make_variant(product, [ value(size, "S") ])
    make_variant(product, [ value(size, "2XL") ], override: 1400, position: 1)

    assert_equal [ 1200, 1400 ], product.refresh.price_range
  end

  test "a variant label follows option order, not the order values were attached" do
    product = make_product
    colour = make_option(product, "Colour", [ "Black" ], position: 0)
    size = make_option(product, "Size", [ "L" ], position: 1)
    variant = make_variant(product, [ value(size, "L"), value(colour, "Black") ])

    assert_equal "Black / L", variant.refresh.label
    assert_equal value(size, "L"), variant.value_for(size)
  end

  test "a simple product's one variant is labelled with the product name" do
    product = make_product(name: "Sticker")
    variant = make_variant(product, [])

    assert product.simple?
    assert_equal "", variant.options_key
    assert_equal "Sticker", variant.refresh.label
  end

  test "in_stock?, total_stock and sold_out? reflect the variants" do
    product = make_product
    size = make_option(product, "Size", [ "S", "M" ])
    small = make_variant(product, [ value(size, "S") ], stock: 0)
    refute product.in_stock?
    assert small.sold_out?

    make_variant(product, [ value(size, "M") ], stock: 4, position: 1)
    product.refresh
    assert product.in_stock?
    assert_equal 4, product.total_stock
  end

  test "swatch_option is the first option whose values carry a swatch" do
    product = make_product
    make_option(product, "Size", [ "S" ], position: 0)
    assert_nil product.refresh.swatch_option

    make_option(product, "Colour", [ { name: "Black", swatch_hex: "#0d1114" } ], position: 1)
    assert_equal "Colour", product.refresh.swatch_option.name
  end

  test "variants come back in position order" do
    product = make_product
    size = make_option(product, "Size", [ "S", "M", "L" ])
    make_variant(product, [ value(size, "L") ], position: 2)
    make_variant(product, [ value(size, "S") ], position: 0)
    make_variant(product, [ value(size, "M") ], position: 1)

    assert_equal [ "S", "M", "L" ], product.refresh.variants.map(&:label)
  end

  test "deleting a product removes its options, values, variants and links" do
    product = make_product
    size = make_option(product, "Size", [ "S" ])
    make_variant(product, [ value(size, "S") ])

    product.destroy

    assert_equal 0, ProductOption.where(product_id: product.id).count
    assert_equal 0, OptionValue.where(product_option_id: size.id).count
    assert_equal 0, ProductVariant.where(product_id: product.id).count
    assert_equal 0, Product.db[:variant_option_values].count
  end

  # ProductEditor relies on this: deleting a value cascades to the links but
  # leaves the variant behind with a stale options_key, so the editor must
  # delete affected variants itself, before it deletes values.
  test "deleting a value removes its links but not the variant" do
    product = make_product
    size = make_option(product, "Size", [ "S" ])
    variant = make_variant(product, [ value(size, "S") ])

    value(size, "S").destroy

    assert ProductVariant[variant.id], "the variant survives"
    assert_equal 0, Product.db[:variant_option_values].where(product_variant_id: variant.id).count
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/models/product_test.rb`
Expected: errors such as `NameError: uninitialized constant ProductTest::ProductOption`, and failures on `price_cents`.

- [ ] **Step 4: Write the migration**

Create `db/migrate/20261013120000_rebuild_products_with_options.rb`:

```ruby
# frozen_string_literal: true

# Replaces the fixed size-by-colour variant grid with per-product options.
# There was no real product data when this was written (confirmed 2026-10-13),
# so the product tables are dropped and rebuilt rather than converted.
# Development gets its sample products back from bin/rails db:seed.
Sequel.migration do
  up do
    drop_table :product_variants
    drop_table :products

    create_table :products do
      primary_key :id
      String    :name, null: false
      String    :slug, null: false, unique: true
      String    :description, text: true
      String    :image
      Integer   :price_cents, null: false
      TrueClass :active, null: false, default: true
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
    end

    create_table :product_options do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :name, null: false
      Integer :position, null: false

      index [ :product_id, :name ], unique: true
    end

    create_table :option_values do
      primary_key :id
      foreign_key :product_option_id, :product_options, null: false, on_delete: :cascade
      String  :name, null: false
      Integer :position, null: false
      String  :swatch_hex
      String  :swatch_image
      String  :image

      index [ :product_option_id, :name ], unique: true
    end

    create_table :product_variants do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :options_key, null: false
      Integer :price_override_cents
      Integer :stock, null: false, default: 0
      String  :sku, unique: true
      Integer :position, null: false

      index [ :product_id, :options_key ], unique: true
    end

    create_table :variant_option_values do
      foreign_key :product_variant_id, :product_variants, null: false, on_delete: :cascade
      foreign_key :option_value_id, :option_values, null: false, on_delete: :cascade
      primary_key [ :product_variant_id, :option_value_id ]

      index :option_value_id
    end
  end

  down do
    raise Sequel::Error, "irreversible: the size-by-colour shape cannot hold arbitrary options"
  end
end
```

PostgreSQL treats NULLs as distinct in a unique constraint, so `sku` can be unique and still blank on any number of rows.

- [ ] **Step 5: Run the migration in both environments**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
```

Expected: `db/schema.rb` now shows `products.price_cents`, the four new tables and no `size`/`color` columns.

- [ ] **Step 6: Write the models**

Replace all of `app/models/product.rb`:

```ruby
class Product < Sequel::Model
  MAX_OPTIONS  = 3
  MAX_VARIANTS = 100

  one_to_many :options,  class: :ProductOption,  order: :position
  one_to_many :variants, class: :ProductVariant, order: :position

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  dataset_module do
    def published
      where(active: true).order(:name)
    end
  end

  # Whether a filename resolves to an image Propshaft can serve. Images are
  # filenames under app/assets/images until uploads exist.
  def self.asset_exists?(filename)
    Rails.application.assets.load_path.find(filename).present?
  end

  # A product with no options is a single item: a sticker, a print. It still
  # has exactly one variant, which holds its stock.
  def simple?
    options.empty?
  end

  def price_range
    prices = variants.map(&:price_cents)
    return [ price_cents, price_cents ] if prices.empty?

    [ prices.min, prices.max ]
  end

  def in_stock?
    variants.any? { |variant| variant.stock.positive? }
  end

  def total_stock
    variants.sum(&:stock)
  end

  # The option the catalog shows as swatches: the first whose values carry one.
  def swatch_option
    options.find { |option| option.option_values.any?(&:swatch?) }
  end

  def validate
    super
    validates_presence [ :name, :slug, :price_cents ]
    validates_format(/\A[a-z0-9-]+\z/, :slug, message: "must be lowercase letters, numbers and dashes")
    validates_unique(:slug)
    validates_operator(:>=, 0, :price_cents, allow_nil: true)

    if image.present? && !Product.asset_exists?(image)
      errors.add(:image, "is not a file in app/assets/images")
    end
  end
end
```

Create `app/models/product_option.rb`:

```ruby
# One option of one product, such as Size or Colour. Options belong to a single
# product, so changing one never touches another product.
class ProductOption < Sequel::Model
  many_to_one :product
  one_to_many :option_values, class: :OptionValue, order: :position

  plugin :validation_helpers

  def validate
    super
    validates_presence [ :product_id, :name, :position ]
    validates_unique([ :product_id, :name ])

    if new? && product_id && ProductOption.where(product_id: product_id).count >= Product::MAX_OPTIONS
      errors.add(:product, "already has #{Product::MAX_OPTIONS} options")
    end
  end
end
```

Create `app/models/option_value.rb`:

```ruby
# One value of one option, such as "2XL" or "Tie-Dye". The swatch is what the
# product page's selector shows; the image, when set, replaces the product
# photo while this value is selected.
class OptionValue < Sequel::Model
  HEX = /\A#\h{6}\z/

  many_to_one :product_option

  plugin :validation_helpers

  def swatch?
    swatch_hex.present? || swatch_image.present?
  end

  def validate
    super
    validates_presence [ :product_option_id, :name, :position ]
    validates_unique([ :product_option_id, :name ])
    validates_format(HEX, :swatch_hex, allow_nil: true, message: "must be a colour like #1b2a41")

    [ :swatch_image, :image ].each do |column|
      filename = public_send(column)
      next if filename.blank? || Product.asset_exists?(filename)

      errors.add(column, "is not a file in app/assets/images")
    end
  end
end
```

Replace all of `app/models/product_variant.rb`:

```ruby
# One combination of option values: the thing that has stock and that a future
# order line will point at. A simple product has one variant with no values.
class ProductVariant < Sequel::Model
  many_to_one :product
  many_to_many :option_values, join_table: :variant_option_values,
               left_key: :product_variant_id, right_key: :option_value_id

  plugin :validation_helpers

  # A combination's identity: its option value ids, sorted and joined. The
  # unique index on [product_id, options_key] is what makes a duplicate
  # combination impossible, which the join table alone cannot enforce.
  def self.key_for(option_value_ids)
    option_value_ids.sort.join("-")
  end

  # What this variant sells for. The only price reader views and future order
  # lines should use.
  def price_cents
    price_override_cents || product.price_cents
  end

  def sold_out?
    stock.zero?
  end

  def value_for(option)
    option_values.find { |value| value.product_option_id == option.id }
  end

  def label
    return product.name if product.simple?

    product.options.filter_map { |option| value_for(option)&.name }.join(" / ")
  end

  def validate
    super
    validates_presence [ :product_id, :stock, :position ]
    # Not validates_presence: a simple variant's key is "", which counts as blank.
    errors.add(:options_key, "is missing") if options_key.nil?
    validates_operator(:>=, 0, :stock, allow_nil: true)
    validates_operator(:>=, 0, :price_override_cents, allow_nil: true)
    validates_unique([ :product_id, :options_key ])
    validates_unique(:sku)
  end
end
```

`validates_unique(:sku)` skips nil values, which is what lets any number of variants leave the SKU blank. `ProductEditor` turns blank text into nil before saving.

- [ ] **Step 7: Remove what covered the old shape**

These test files exercise pages and seeds that no longer match the model. Tasks 4, 5 and 7 replace them.

```bash
git rm test/integration/admin_products_test.rb test/integration/shop_test.rb test/models/seeds_test.rb
```

In `db/seeds.rb`, delete everything from the line `# Sample products for the shop.` to the end of the file, keeping only the generated comment header above it. Task 4 rewrites the seeds.

- [ ] **Step 8: Run the model tests to verify they pass**

Run: `bin/rails test test/models/product_test.rb`
Expected: 26 runs, 0 failures, 0 errors.

- [ ] **Step 9: Run the full suite and lint**

Run the suite in the background (`bin/rails test test/`, ~400s), and nothing else against the test database until it finishes. Then:

```bash
bin/rubocop && bin/brakeman --no-pager
```

Expected: 0 failures, 0 offenses, 0 warnings.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Replace the size-by-colour grid with per-product options

Products now own up to three options, each with its own values, and a
variant is one combination of them. A product with no options is a
simple item with a single variant. Price moves to the product, with an
optional override per variant.

No real product data exists yet, so the migration drops and rebuilds
the tables instead of converting rows. The shop and admin pages are
broken until they are rebuilt later on this branch; their old tests go
with the old shape.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: ProductEditor — products, options and variant generation

**Files:**
- Create: `app/models/product_editor.rb`
- Modify: `test/test_helper.rb` (add product builders)
- Test: `test/models/product_editor_test.rb`

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces:
  - `ProductEditor.new(product, params)`. `params` is a Hash (string or symbol keys) shaped like the form: `"product" => { "name", "slug", "description", "image", "price", "active" }`, `"options" =>` an array or index-keyed hash of `{ "name", "values" => array or index-keyed hash of { "name", "position", "swatch_hex", "swatch_image", "image" } }`, `"variants" => { "<id>" => { "stock", "price_override", "sku" } }`, `"confirm_loss" => "1"`, `"simple_stock"`.
  - `#save -> true | false` (never raises on invalid input).
  - Readers: `#product`, `#errors -> Array<String>` (sentences), `#pending_loss -> Array<ProductEditor::Loss>`, `#option_inputs -> Array<{ name:, values: [{ name:, position:, swatch_hex:, swatch_image:, image:, index: }] }>`, `#variant_inputs -> Hash<String id, Hash<String, String>>`, `#price_input -> String`, `#simple_stock_input -> String`, `#created_count -> Integer`, `#variants_changed? -> bool`.
  - `ProductEditor.from_product(product)`, `ProductEditor.blank(copy_from: nil)`, `ProductEditor.format_money(cents) -> String`, `#copy_options_from(product)`.
  - `ProductEditor::Loss = Data.define(:label, :stock)`.
  - Test helpers in `ActiveSupport::TestCase`: `build_product(name:, slug:, price:, options:, stock:, active:, image:) -> Product`, `form_params_for(product) -> Hash`, `with_value(params, option_name, value_name) -> Hash`, `without_value(params, option_name, value_name) -> Hash`, `variant_named(product, label) -> ProductVariant`.

- [ ] **Step 1: Add the test helpers**

In `test/test_helper.rb`, inside `class ActiveSupport::TestCase`, after `create_account`, add:

```ruby
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

    private def indexed(rows)
      rows.each_with_index.to_h { |row, index| [ index.to_s, row ] }
    end
```

- [ ] **Step 2: Write the failing editor tests**

Create `test/models/product_editor_test.rb`:

```ruby
require "test_helper"

class ProductEditorTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def product_fields(**overrides)
    {
      "name" => "Editor Tee", "slug" => "editor-tee", "description" => "A shirt.",
      "image" => "3crow.png", "price" => "12.00", "active" => "1"
    }.merge(overrides.stringify_keys)
  end

  def option(name, *values)
    { "name" => name, "values" => values.map { |value| value.is_a?(Hash) ? value.stringify_keys : { "name" => value } } }
  end

  def create(options: [], **fields)
    ProductEditor.new(Product.new, { "product" => product_fields(**fields), "options" => options })
  end

  test "a product with no options gets one simple variant" do
    editor = create
    assert editor.save, editor.errors.join(" ")

    product = editor.product
    assert product.simple?
    assert_equal 1, product.variants.size
    assert_equal "", product.variants.first.options_key
    assert_equal "Editor Tee", product.variants.first.label
    assert_equal 1200, product.variants.first.price_cents
  end

  test "options multiply into one variant per combination, in option then value order" do
    editor = create(options: [ option("Colour", "Black", "White"), option("Size", "S", "M", "L") ])
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Black / S", "Black / M", "Black / L", "White / S", "White / M", "White / L" ],
      editor.product.variants.map(&:label)
    assert_equal 6, editor.created_count
    assert editor.variants_changed?
  end

  test "blank padding rows from the form are ignored" do
    editor = ProductEditor.new(Product.new, {
      "product" => product_fields,
      "options" => {
        "0" => { "name" => "Size", "values" => { "0" => { "name" => "S" }, "1" => { "name" => "" }, "2" => { "name" => "  " } } },
        "1" => { "name" => "", "values" => { "0" => { "name" => "" } } }
      }
    })
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Size" ], editor.product.options.map(&:name)
    assert_equal [ "S" ], editor.product.variants.map(&:label)
  end

  test "index-keyed rows are ordered numerically, not as strings" do
    values = (0..10).to_h { |i| [ i.to_s, { "name" => "V#{i}" } ] }
    editor = ProductEditor.new(Product.new, { "product" => product_fields, "options" => { "0" => { "name" => "Pick", "values" => values } } })
    assert editor.save, editor.errors.join(" ")

    assert_equal (0..10).map { |i| "V#{i}" }, editor.product.options.first.option_values.map(&:name)
  end

  test "a value's position field reorders it" do
    editor = create(options: [ option("Size", { name: "L", position: "2" }, { name: "S", position: "1" }) ])
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "S", "L" ], editor.product.options.first.option_values.map(&:name)
  end

  test "the slug is derived from the name when left blank" do
    editor = create(slug: "", name: "Fresh Print")
    assert editor.save, editor.errors.join(" ")
    assert_equal "fresh-print", editor.product.slug
  end

  test "dollar signs and thousands commas are accepted in the price" do
    editor = create(price: "$1,200.50")
    assert editor.save, editor.errors.join(" ")
    assert_equal 120050, editor.product.price_cents
  end

  test "a malformed price is an error, never zero, and writes nothing" do
    editor = create(price: "12.0.0")
    refute editor.save

    assert_includes editor.errors, "Price must be an amount like 12.00."
    assert_equal "12.0.0", editor.price_input, "the form must redisplay what was typed"
    assert_equal 0, Product.count
  end

  test "product validation errors are reported as sentences" do
    build_product(slug: "taken")
    editor = create(slug: "taken")

    refute editor.save
    assert_includes editor.errors, "Slug is already taken."
  end

  test "an option with no values is an error" do
    editor = create(options: [ option("Size") ])
    refute editor.save
    assert_includes editor.errors, "Size needs at least one value."
    assert_equal 0, Product.count
  end

  test "values without an option name are an error" do
    editor = create(options: [ option("", "S") ])
    refute editor.save
    assert_includes editor.errors, "Option 1 needs a name."
  end

  test "two options with the same name, ignoring case, are an error" do
    editor = create(options: [ option("Size", "S"), option("size", "M") ])
    refute editor.save
    assert_includes editor.errors, "There are two options called size."
  end

  test "a value listed twice in one option, ignoring case, is an error" do
    editor = create(options: [ option("Colour", "Black", "black") ])
    refute editor.save
    assert_includes editor.errors, "Colour lists Black more than once."
  end

  test "more than three options is an error" do
    editor = create(options: [ option("A", "1"), option("B", "1"), option("C", "1"), option("D", "1") ])
    refute editor.save
    assert_includes editor.errors, "A product can have at most 3 options."
  end

  test "more than one hundred variants is an error and writes nothing" do
    editor = create(options: [ option("A", *("a".."k").to_a), option("B", *("a".."j").to_a) ])
    refute editor.save

    assert_includes editor.errors, "Those options make 110 variants; the limit is 100."
    assert_equal 0, Product.count
  end

  test "a bad swatch is reported against its value and rolls the whole save back" do
    editor = create(options: [ option("Colour", { name: "Black", swatch_hex: "black" }) ])
    refute editor.save

    assert_includes editor.errors, "Black: Swatch hex must be a colour like #1b2a41."
    assert_equal 0, Product.count
    assert_equal 0, ProductOption.count
    assert editor.product.new?, "the re-rendered form must still post to create"
  end

  test "swatch and photo fields are saved on the value" do
    editor = create(options: [
      option("Colour", { name: "Tie-Dye", swatch_image: "3crow.png", image: "3crow.png" }, { name: "Black", swatch_hex: "#0d1114" })
    ])
    assert editor.save, editor.errors.join(" ")

    tie_dye, black = editor.product.options.first.option_values
    assert_equal [ "3crow.png", "3crow.png" ], [ tie_dye.swatch_image, tie_dye.image ]
    assert_equal "#0d1114", black.swatch_hex
  end

  test "adding a value creates only the new combinations, at zero stock" do
    product = build_product(options: { "Colour" => [ "Black" ], "Size" => [ "S", "M" ] }, stock: 7)
    old_ids = product.variants.map(&:id)

    editor = ProductEditor.new(product, with_value(form_params_for(product), "Colour", "Red"))
    assert editor.save, editor.errors.join(" ")

    product.refresh
    assert_equal [ "Black / S", "Black / M", "Red / S", "Red / M" ], product.variants.map(&:label)
    assert_equal 2, editor.created_count
    assert editor.variants_changed?
    assert_equal [ 7, 7 ], product.variants.select { |v| old_ids.include?(v.id) }.map(&:stock)
    assert_equal [ 0, 0 ], product.variants.reject { |v| old_ids.include?(v.id) }.map(&:stock)
  end

  test "removing a value with no stock deletes its variants" do
    product = build_product(options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S" ] }, stock: 0)

    editor = ProductEditor.new(product, without_value(form_params_for(product), "Colour", "Red"))
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Black / S" ], product.refresh.variants.map(&:label)
    assert_equal [ "Black" ], product.options.first.option_values.map(&:name)
    assert_equal 2, Product.db[:variant_option_values].count, "one variant, linked to Black and to S"
  end

  test "names are trimmed, and values are matched to existing rows ignoring case" do
    product = build_product(options: { "Colour" => [ "Black" ] })
    variant_id = product.variants.first.id
    params = form_params_for(product)
    params["options"]["0"]["values"]["0"]["name"] = "  BLACK  "

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "BLACK" ], product.refresh.options.first.option_values.map(&:name)
    assert_equal [ variant_id ], product.variants.map(&:id), "a change of case must not replace the variant"
    refute editor.variants_changed?
  end

  test "reordering options keeps the variants and relabels them" do
    product = build_product(options: { "Colour" => [ "Black" ], "Size" => [ "S" ] })
    ids = product.variants.map(&:id)
    params = form_params_for(product)
    params["options"] = { "0" => params["options"]["1"], "1" => params["options"]["0"] }

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")

    assert_equal ids, product.refresh.variants.map(&:id)
    assert_equal [ "S / Black" ], product.variants.map(&:label)
    refute editor.variants_changed?
  end

  test "replacing an option on a product already at the limit works" do
    product = build_product(options: { "A" => [ "1" ], "B" => [ "1" ], "C" => [ "1" ] }, stock: 0)
    params = form_params_for(product)
    params["options"]["2"]["name"] = "D"

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")
    assert_equal [ "A", "B", "D" ], product.refresh.options.map(&:name)
  end

  test "saving the edit form unchanged changes nothing" do
    product = build_product(options: { "Colour" => [ { name: "Black", swatch_hex: "#0d1114" } ], "Size" => [ "S", "M" ] }, stock: 3)
    before = product.variants.map { |v| [ v.id, v.options_key, v.stock, v.position ] }

    editor = ProductEditor.new(product, form_params_for(product))
    assert editor.save, editor.errors.join(" ")

    refute editor.variants_changed?
    assert_equal before, product.refresh.variants.map { |v| [ v.id, v.options_key, v.stock, v.position ] }
    assert_equal "#0d1114", product.options.first.option_values.first.swatch_hex
  end

  test "blank copies another product's options onto a new product" do
    source = build_product(options: { "Size" => [ "S", "M" ] })
    editor = ProductEditor.blank(copy_from: source)

    assert editor.product.new?
    assert_equal [ "Size" ], editor.option_inputs.map { |option| option[:name] }
    assert_equal [ "S", "M" ], editor.option_inputs.first[:values].map { |value| value[:name] }
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/models/product_editor_test.rb`
Expected: errors with `NameError: uninitialized constant ProductEditorTest::ProductEditor`.

- [ ] **Step 4: Write ProductEditor**

Create `app/models/product_editor.rb`:

```ruby
# Saves a product together with its options and the variants derived from
# them. Sequel has no nested attributes, and the set of variants is computed
# from the options rather than submitted, so this is the one place that turns
# the admin form into rows.
#
# Every write happens inside one transaction: a save either applies in full or
# leaves the database as it was.
class ProductEditor
  MONEY = /\A\d+(\.\d{1,2})?\z/
  WHOLE = /\A\d+\z/
  MAX_STOCK = 1_000_000

  # A variant this save would delete while it still holds stock.
  Loss = Data.define(:label, :stock)

  attr_reader :product, :errors, :pending_loss, :option_inputs, :variant_inputs,
              :price_input, :simple_stock_input, :created_count

  # The form state for an existing product, as the edit page first shows it.
  def self.from_product(product)
    new(product, {
      "options" => product.options.map do |option|
        {
          "name" => option.name,
          "values" => option.option_values.map.with_index(1) do |value, position|
            {
              "name" => value.name, "position" => position.to_s, "swatch_hex" => value.swatch_hex,
              "swatch_image" => value.swatch_image, "image" => value.image
            }
          end
        }
      end,
      "variants" => product.variants.to_h do |variant|
        [ variant.id.to_s, {
          "stock" => variant.stock.to_s,
          "price_override" => format_money(variant.price_override_cents),
          "sku" => variant.sku.to_s
        } ]
      end
    })
  end

  # A new, unsaved product, optionally starting from another product's options.
  def self.blank(copy_from: nil)
    editor = new(Product.new(price_cents: 1200, active: true), {})
    editor.copy_options_from(copy_from) if copy_from
    editor
  end

  # Integer cents as a money field shows them: 1200 => "12.00", nil => "".
  def self.format_money(cents)
    return "" if cents.nil?

    format("%d.%02d", cents / 100, cents % 100)
  end

  def initialize(product, params)
    @product = product
    @params = params.to_h.deep_stringify_keys
    @errors = []
    @pending_loss = []
    @created_count = 0
    @variants_changed = false
    @price_input = @params.dig("product", "price")&.to_s || self.class.format_money(product.price_cents)
    @simple_stock_input = @params["simple_stock"].to_s.strip
    @option_inputs = parse_options(@params["options"])
    @variant_inputs = (@params["variants"] || {}).to_h do |id, fields|
      [ id.to_s, fields.to_h.transform_values(&:to_s) ]
    end
  end

  def copy_options_from(source)
    @option_inputs = self.class.from_product(source).option_inputs
  end

  def variants_changed?
    @variants_changed
  end

  def save
    @was_new = product.new?
    assign_product_fields
    validate_options
    validate_variant_count
    validate_product
    return false if errors.any?

    combos = combinations
    doomed = doomed_variants(combos)

    Product.db.transaction do
      product.save
      ProductVariant.where(id: doomed.map(&:id)).delete if doomed.any?
      value_ids = sync_options
      sync_variants(combos, value_ids, doomed)
    end

    @variants_changed = doomed.any? || created_count.positive?
    product.refresh
    true
  rescue Sequel::ValidationFailed => e
    restore_after_rollback
    errors.concat(messages_for(e.model))
    false
  rescue Sequel::UniqueConstraintViolation
    restore_after_rollback
    errors << "Something else saved a clashing slug or SKU at the same moment. Try again."
    false
  end

  private

  # Options arrive as index-keyed hashes from the form ("0" => {...}) or as
  # arrays from code. Both become ordered arrays. Blank rows, which are the
  # spares the form pads with, are dropped here so nothing downstream sees them.
  def parse_options(raw)
    ordered(raw).filter_map do |option|
      name = option["name"].to_s.strip
      values = ordered(option["values"]).each_with_index.filter_map do |value, index|
        value_name = value["name"].to_s.strip
        next if value_name.empty?

        position = value["position"].to_s.strip
        {
          name: value_name,
          position: position.match?(WHOLE) ? position.to_i : index + 1,
          swatch_hex: value["swatch_hex"].to_s.strip.presence,
          swatch_image: value["swatch_image"].to_s.strip.presence,
          image: value["image"].to_s.strip.presence,
          index: index
        }
      end
      next if name.empty? && values.empty?

      { name: name, values: values.sort_by { |value| [ value[:position], value[:index] ] } }
    end
  end

  def ordered(raw)
    rows = raw.is_a?(Hash) ? raw.sort_by { |key, _| key.to_i }.map(&:last) : Array(raw)
    rows.select { |row| row.is_a?(Hash) }
  end

  def assign_product_fields
    fields = @params["product"] || {}
    name = fields["name"].to_s.strip
    @product_fields = {
      name: name,
      slug: fields["slug"].to_s.strip.presence || name.parameterize,
      description: fields["description"].to_s.strip,
      image: fields["image"].to_s.strip.presence,
      price_cents: cents(fields["price"]),
      active: fields["active"] == "1"
    }
    product.set(@product_fields)
  end

  def validate_options
    if option_inputs.size > Product::MAX_OPTIONS
      errors << "A product can have at most #{Product::MAX_OPTIONS} options."
    end

    seen = []
    option_inputs.each.with_index(1) do |option, number|
      title = option[:name].presence || "Option #{number}"
      errors << "Option #{number} needs a name." if option[:name].empty?
      errors << "#{title} needs at least one value." if option[:values].empty?
      if option[:name].present? && seen.include?(option[:name].downcase)
        errors << "There are two options called #{option[:name]}."
      end
      seen << option[:name].downcase

      option[:values].group_by { |value| value[:name].downcase }.each_value do |same|
        errors << "#{title} lists #{same.first[:name]} more than once." if same.size > 1
      end
    end
  end

  # Counted before the combinations are built, so a hostile form cannot make
  # the server enumerate millions of them.
  def validate_variant_count
    count = option_inputs.map { |option| option[:values].size }.inject(1, :*)
    return if count <= Product::MAX_VARIANTS

    errors << "Those options make #{count} variants; the limit is #{Product::MAX_VARIANTS}."
  end

  def validate_product
    errors << "Price must be an amount like 12.00." if product.price_cents.nil?
    return if product.valid?

    product.errors.each do |attribute, messages|
      next if attribute == :price_cents && product.price_cents.nil?

      messages.each { |message| errors << "#{attribute.to_s.humanize} #{message}." }
    end
  end

  # Every combination of one value per option, in option order and then value
  # order, as [option name, value name] pairs. A product with no options has
  # exactly one combination: the empty one.
  def combinations
    axes = option_inputs.map { |option| option[:values].map { |value| [ option[:name], value[:name] ] } }
    return [ [] ] if axes.empty?

    axes.first.product(*axes.drop(1))
  end

  # The variants this save removes: those whose combination is no longer
  # wanted. Matched by name, ignoring case, because names are what the form
  # submits; ids for new values do not exist yet.
  def doomed_variants(combos)
    wanted = combos.map { |pairs| signature(pairs) }.to_set
    existing_variants.reject { |variant| wanted.include?(signature(existing_pairs(variant))) }
  end

  def signature(pairs)
    pairs.map { |option, value| [ option.downcase, value.downcase ] }.sort
  end

  # Snapshots taken before any write, so they describe the product as it was.
  def existing_variants
    @existing_variants ||= if product.new?
      []
    else
      ProductVariant.where(product_id: product.id).eager(:option_values).order(:position).all
    end
  end

  def existing_options
    @existing_options ||= if product.new?
      {}
    else
      ProductOption.where(product_id: product.id).all.to_h { |option| [ option.id, option ] }
    end
  end

  # A stored variant's [option name, value name] pairs, in option order.
  def existing_pairs(variant)
    variant.option_values
      .map { |value| [ existing_options.fetch(value.product_option_id), value ] }
      .sort_by { |option, _| option.position }
      .map { |option, value| [ option.name, value.name ] }
  end

  def existing_labels
    @existing_labels ||= existing_variants.to_h do |variant|
      pairs = existing_pairs(variant)
      [ variant.id, pairs.empty? ? product.name : pairs.map(&:last).join(" / ") ]
    end
  end

  # Upserts options and values by name, ignoring case, and deletes the ones no
  # longer listed. Removed rows go first, so replacing an option on a product
  # already at the option limit does not trip the limit. Returns a map from
  # [option name, value name], downcased, to value id.
  def sync_options
    current = existing_options.values.to_h { |option| [ option.name.downcase, option ] }
    wanted = option_inputs.map { |input| input[:name].downcase }
    stale = current.reject { |name, _| wanted.include?(name) }
    ProductOption.where(id: stale.values.map(&:id)).delete if stale.any?

    option_inputs.each_with_index.with_object({}) do |(input, position), value_ids|
      option = current[input[:name].downcase] || ProductOption.new(product_id: product.id)
      option.set(name: input[:name], position: position)
      option.save

      sync_values(option, input[:values]).each do |value|
        value_ids[[ input[:name].downcase, value.name.downcase ]] = value.id
      end
    end
  end

  def sync_values(option, inputs)
    current = OptionValue.where(product_option_id: option.id).all.to_h { |value| [ value.name.downcase, value ] }
    wanted = inputs.map { |input| input[:name].downcase }
    stale = current.reject { |name, _| wanted.include?(name) }
    OptionValue.where(id: stale.values.map(&:id)).delete if stale.any?

    inputs.each_with_index.map do |input, position|
      value = current[input[:name].downcase] || OptionValue.new(product_option_id: option.id)
      value.set(
        name: input[:name], position: position,
        swatch_hex: input[:swatch_hex], swatch_image: input[:swatch_image], image: input[:image]
      )
      value.save
      value
    end
  end

  # Creates a variant for each new combination and renumbers the survivors.
  def sync_variants(combos, value_ids, doomed)
    survivors = (existing_variants - doomed).to_h { |variant| [ variant.options_key, variant ] }

    combos.each_with_index do |pairs, position|
      ids = pairs.map { |option, value| value_ids.fetch([ option.downcase, value.downcase ]) }
      key = ProductVariant.key_for(ids)

      if (variant = survivors[key])
        variant.update(position: position) unless variant.position == position
      else
        variant = ProductVariant.create(product_id: product.id, options_key: key, position: position, stock: 0)
        Product.db[:variant_option_values].import(
          [ :product_variant_id, :option_value_id ], ids.map { |id| [ variant.id, id ] }
        )
        @created_count += 1
      end
    end
  end

  # The transaction rolled back, but a new product object still believes it
  # was saved, because it holds an id. Swap in an unsaved copy so the
  # re-rendered form posts to create again.
  def restore_after_rollback
    @created_count = 0
    @product = Product.new(@product_fields) if @was_new
  end

  def messages_for(model)
    subject = if model.is_a?(Product)
      nil
    elsif model.is_a?(ProductVariant)
      existing_labels.fetch(model.id, "A variant")
    else
      model.name.presence || "A value"
    end

    model.errors.flat_map do |attribute, messages|
      messages.map { |message| [ subject, "#{attribute.to_s.humanize} #{message}." ].compact.join(": ") }
    end
  end

  # Cents, or nil when the text is not a well-formed non-negative amount.
  # Callers treat nil as an error, never as zero: a silently zeroed price
  # would put a product in the shop for free.
  def cents(value)
    text = value.to_s.strip.delete("$").delete(",")
    return nil unless text.match?(MONEY)

    (BigDecimal(text) * 100).round
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/product_editor_test.rb test/models/product_test.rb`
Expected: 50 runs, 0 failures, 0 errors.

If `saving the edit form unchanged changes nothing` fails on positions, check that `sync_variants` compares against `variant.position` before updating. If `names are trimmed…` fails with a new variant id, check that `sync_values` looks values up by `name.downcase` and calls `set`, rather than creating a new row.

- [ ] **Step 6: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.
Expected: 0 failures, 0 offenses, 0 warnings. If rubocop reports only layout offenses in the new file, run `bin/rubocop -a app/models/product_editor.rb` and re-run the editor tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add ProductEditor to turn the admin form into product rows

Options and values are upserted by name, ignoring case, and the variant
set is derived from them: one row per combination, or a single simple
variant when there are no options. Existing combinations keep their
rows and stock; new ones start at zero. Everything runs in one
transaction, and invalid input comes back as sentences for the form.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: ProductEditor — the stock-loss guard and per-variant fields

**Files:**
- Modify: `app/models/product_editor.rb`
- Test: `test/models/product_editor_test.rb` (append)

**Interfaces:**
- Consumes: `ProductEditor` from Task 2, `build_product`, `form_params_for`, `without_value`, `variant_named`.
- Produces: `#pending_loss` populated whenever a save would delete variants holding stock. `save` returns false unless `params["confirm_loss"] == "1"`. `params["variants"]` applied by id. `params["simple_stock"]` applied to a newly created simple variant.

- [ ] **Step 1: Append the failing tests**

Add to the end of `ProductEditorTest`, before the final `end`:

```ruby
  test "removing a value that still has stock stops and lists what would be lost" do
    product = build_product(name: "Loss Tee", options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S" ] }, stock: 4)
    params = without_value(form_params_for(product), "Colour", "Red")
    params["product"]["name"] = "Renamed Tee"

    editor = ProductEditor.new(product, params)
    refute editor.save

    assert_equal [ ProductEditor::Loss.new(label: "Red / S", stock: 4) ], editor.pending_loss
    assert_equal 2, ProductVariant.where(product_id: product.id).count
    assert_equal "Loss Tee", Product[product.id].name, "nothing may be written, not even the product fields"
  end

  test "confirming the loss goes ahead" do
    product = build_product(options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S" ] }, stock: 4)
    params = without_value(form_params_for(product), "Colour", "Red").merge("confirm_loss" => "1")

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")
    assert_equal [ "Black / S" ], product.refresh.variants.map(&:label)
  end

  test "renaming a value counts as removing it" do
    product = build_product(options: { "Colour" => [ "Black" ] }, stock: 2)
    params = form_params_for(product)
    params["options"]["0"]["values"]["0"]["name"] = "Jet Black"

    editor = ProductEditor.new(product, params)
    refute editor.save
    assert_equal [ "Black" ], editor.pending_loss.map(&:label)
  end

  test "adding a whole option replaces every variant, so the loss check applies" do
    product = build_product(options: { "Size" => [ "S", "M" ] }, stock: 1)
    params = form_params_for(product)
    params["options"]["1"] = { "name" => "Colour", "values" => { "0" => { "name" => "Black" } } }

    editor = ProductEditor.new(product, params)
    refute editor.save
    assert_equal [ "S", "M" ], editor.pending_loss.map(&:label)

    # The submitted stock fields still name the old variant ids; they must be
    # ignored rather than crash once those variants are gone.
    editor = ProductEditor.new(product.refresh, params.merge("confirm_loss" => "1"))
    assert editor.save, editor.errors.join(" ")
    assert_equal [ "S / Black", "M / Black" ], product.refresh.variants.map(&:label)
    assert_equal [ 0, 0 ], product.variants.map(&:stock)
  end

  test "removing every option collapses to one simple variant" do
    product = build_product(name: "Collapse Tee", options: { "Size" => [ "S", "M" ] }, stock: 0)

    editor = ProductEditor.new(product, form_params_for(product).merge("options" => {}))
    assert editor.save, editor.errors.join(" ")

    assert product.refresh.simple?
    assert_equal [ "Collapse Tee" ], product.variants.map(&:label)
    assert_equal 0, ProductOption.where(product_id: product.id).count
  end

  test "stock, price override and SKU are saved per variant" do
    product = build_product(options: { "Size" => [ "S", "M" ] }, stock: 1)
    small, medium = product.variants
    params = form_params_for(product)
    params["variants"][small.id.to_s] = { "stock" => "9", "price_override" => "14.00", "sku" => " CROW-S " }

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")

    small.refresh
    medium.refresh
    assert_equal [ 9, 1400, "CROW-S" ], [ small.stock, small.price_override_cents, small.sku ]
    assert_equal [ 1, nil, nil ], [ medium.stock, medium.price_override_cents, medium.sku ]
    assert_equal 1400, small.price_cents
  end

  test "a blank price override goes back to the product price" do
    product = build_product(options: { "Size" => [ "S" ] })
    variant = product.variants.first
    variant.update(price_override_cents: 1400)
    params = form_params_for(product.refresh)
    params["variants"][variant.id.to_s]["price_override"] = ""

    assert ProductEditor.new(product, params).save
    assert_nil variant.refresh.price_override_cents
  end

  test "a malformed override or stock is reported against its variant and writes nothing" do
    product = build_product(options: { "Size" => [ "S", "M" ] }, stock: 1)
    small, medium = product.variants
    params = form_params_for(product)
    params["variants"][small.id.to_s]["price_override"] = "free"
    params["variants"][medium.id.to_s]["stock"] = "-3"

    editor = ProductEditor.new(product, params)
    refute editor.save

    assert_includes editor.errors, "Price for S must be an amount like 12.00, or blank to use the product price."
    assert_includes editor.errors, "Stock for M must be a whole number from 0 to 1,000,000."
    assert_equal [ 1, 1 ], product.refresh.variants.map(&:stock)
  end

  test "variant ids from another product are ignored" do
    mine = build_product(options: { "Size" => [ "S" ] }, stock: 1)
    theirs = build_product(options: { "Size" => [ "S" ] }, stock: 1)
    params = form_params_for(mine)
    params["variants"][theirs.variants.first.id.to_s] = { "stock" => "99" }

    assert ProductEditor.new(mine, params).save
    assert_equal 1, theirs.variants.first.refresh.stock
  end

  test "the same SKU on two variants in one save is an error, not a crash" do
    product = build_product(options: { "Size" => [ "S", "M" ] })
    params = form_params_for(product)
    product.variants.each { |variant| params["variants"][variant.id.to_s]["sku"] = "DUP" }

    editor = ProductEditor.new(product, params)
    refute editor.save

    assert_includes editor.errors, "M: Sku is already taken."
    assert_equal [ nil, nil ], product.refresh.variants.map(&:sku)
  end

  test "a new simple product takes the stock typed on the new form" do
    editor = ProductEditor.new(Product.new, { "product" => product_fields, "simple_stock" => "50" })
    assert editor.save, editor.errors.join(" ")
    assert_equal 50, editor.product.variants.first.stock
  end

  test "simple stock is ignored when the product has options" do
    editor = ProductEditor.new(Product.new, {
      "product" => product_fields, "options" => [ option("Size", "S") ], "simple_stock" => "50"
    })
    assert editor.save, editor.errors.join(" ")
    assert_equal 0, editor.product.variants.first.stock
  end

  test "malformed simple stock is an error" do
    editor = ProductEditor.new(Product.new, { "product" => product_fields, "simple_stock" => "lots" })
    refute editor.save
    assert_includes editor.errors, "Stock must be a whole number from 0 to 1,000,000."
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/product_editor_test.rb`
Expected: the 13 new tests fail. For example, `removing a value that still has stock…` saves when it should refuse, and `stock, price override and SKU…` sees stock 1 instead of 9.

- [ ] **Step 3: Add the guard and the per-variant fields**

In `app/models/product_editor.rb`, replace the whole `save` method with:

```ruby
  def save
    @was_new = product.new?
    assign_product_fields
    validate_options
    validate_simple_stock
    validate_variant_count
    validate_product
    updates = parse_variant_updates
    return false if errors.any?

    combos = combinations
    doomed = doomed_variants(combos)
    return false if unconfirmed_loss?(doomed)

    Product.db.transaction do
      product.save
      ProductVariant.where(id: doomed.map(&:id)).delete if doomed.any?
      value_ids = sync_options
      sync_variants(combos, value_ids, doomed)
      apply_variant_updates(updates, doomed)
    end

    @variants_changed = doomed.any? || created_count.positive?
    product.refresh
    true
  rescue Sequel::ValidationFailed => e
    restore_after_rollback
    errors.concat(messages_for(e.model))
    false
  rescue Sequel::UniqueConstraintViolation
    restore_after_rollback
    errors << "Something else saved a clashing slug or SKU at the same moment. Try again."
    false
  end
```

In `sync_variants`, change the `stock: 0` argument of `ProductVariant.create` to `stock: initial_stock(pairs)`:

```ruby
        variant = ProductVariant.create(product_id: product.id, options_key: key, position: position, stock: initial_stock(pairs))
```

Add these private methods after `validate_product`:

```ruby
  def validate_simple_stock
    return if simple_stock_input.empty? || whole_stock?(simple_stock_input)

    errors << "Stock must be a whole number from 0 to #{MAX_STOCK.to_fs(:delimited)}."
  end

  def whole_stock?(text)
    text.match?(WHOLE) && text.to_i <= MAX_STOCK
  end

  # Per-variant fields from the variants table, keyed by variant id. Ids that
  # do not belong to this product are ignored, so a crafted form cannot touch
  # another product's stock. A field missing from the submission is left alone.
  def parse_variant_updates
    variant_inputs.each_with_object({}) do |(id, fields), updates|
      label = existing_labels[id.to_i] or next
      update = {}

      if fields.key?("stock")
        stock = fields["stock"].strip
        if stock.empty?
          update[:stock] = 0
        elsif whole_stock?(stock)
          update[:stock] = stock.to_i
        else
          errors << "Stock for #{label} must be a whole number from 0 to #{MAX_STOCK.to_fs(:delimited)}."
        end
      end

      if fields.key?("price_override")
        text = fields["price_override"].strip
        if text.empty?
          update[:price_override_cents] = nil
        elsif (amount = cents(text))
          update[:price_override_cents] = amount
        else
          errors << "Price for #{label} must be an amount like 12.00, or blank to use the product price."
        end
      end

      update[:sku] = fields["sku"].strip.presence if fields.key?("sku")
      updates[id.to_i] = update
    end
  end

  # Records every variant this save would delete while it holds stock, and
  # refuses unless the admin ticked the confirmation box.
  def unconfirmed_loss?(doomed)
    @pending_loss = doomed.select { |variant| variant.stock.positive? }
                          .map { |variant| Loss.new(label: existing_labels.fetch(variant.id), stock: variant.stock) }
    return false if pending_loss.empty? || @params["confirm_loss"] == "1"

    errors << "This change deletes variants that still have stock. Tick the box below to confirm."
    true
  end

  def apply_variant_updates(updates, doomed)
    doomed_ids = doomed.map(&:id)

    existing_variants.each do |variant|
      update = updates[variant.id]
      next if update.blank? || doomed_ids.include?(variant.id)

      variant.update(update)
    end
  end

  # A brand-new simple variant takes the stock typed on the new-product form.
  # Every other new variant starts at zero, because the admin had nowhere to
  # type its stock yet.
  def initial_stock(pairs)
    pairs.empty? && whole_stock?(simple_stock_input) ? simple_stock_input.to_i : 0
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/product_editor_test.rb`
Expected: 37 runs, 0 failures, 0 errors.

- [ ] **Step 5: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Guard stock against accidental deletion and save per-variant fields

A save that would delete variants still holding stock is refused and
lists them, until the admin confirms. Stock, price override and SKU are
applied by variant id, ignoring ids from other products and ids this
save removed. A new simple product takes its stock from the new form.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Sample data

**Files:**
- Modify: `db/seeds.rb`
- Test: `test/models/seeds_test.rb` (recreate)

**Interfaces:**
- Consumes: `ProductEditor`, `variant_named`.
- Produces: four seeded products. Slugs are `3-crow`, `see-that-shit`, `third-eye-smiley` and `3-crow-sticker`. The shirts have options `Colour` (with swatch hexes) then `Size` (`S M L XL 2XL 3XL`).

- [ ] **Step 1: Write the failing test**

Create `test/models/seeds_test.rb`:

```ruby
require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def load_seeds
    load Rails.root.join("db/seeds.rb")
  end

  test "seeding creates three shirts and a sticker" do
    load_seeds
    assert_equal 4, Product.count

    crow = Product.first(slug: "3-crow")
    assert_equal [ "Colour", "Size" ], crow.options.map(&:name)
    assert_equal [ "Black", "White", "Heather Grey" ], crow.options.first.option_values.map(&:name)
    assert_equal "#0d1114", crow.options.first.option_values.first.swatch_hex
    assert_equal 18, crow.variants.size
  end

  test "3 Crow charges more for the big sizes through overrides" do
    load_seeds
    crow = Product.first(slug: "3-crow")

    assert_equal 1200, crow.price_cents
    assert_nil variant_named(crow, "Black / S").price_override_cents
    assert_equal 1200, variant_named(crow, "Black / S").price_cents
    assert_equal 1400, variant_named(crow, "Black / 2XL").price_cents
    assert_equal 1400, variant_named(crow, "White / 3XL").price_cents
  end

  test "See That Shit has 3XL sold out in both colours and stock elsewhere" do
    load_seeds
    shirt = Product.first(slug: "see-that-shit")

    assert variant_named(shirt, "Black / 3XL").sold_out?
    assert variant_named(shirt, "Red / 3XL").sold_out?
    assert shirt.in_stock?
  end

  test "Third Eye Smiley comes in a single colour" do
    load_seeds
    smiley = Product.first(slug: "third-eye-smiley")

    assert_equal [ "Black" ], smiley.options.first.option_values.map(&:name)
    assert_equal 6, smiley.variants.size
  end

  test "the sticker is a simple item" do
    load_seeds
    sticker = Product.first(slug: "3-crow-sticker")

    assert sticker.simple?
    assert_equal 1, sticker.variants.size
    assert_equal 50, sticker.variants.first.stock
    assert_equal 400, sticker.variants.first.price_cents
  end

  test "seeding twice changes nothing" do
    load_seeds
    snapshot = ProductVariant.order(:id).select_map([ :id, :stock, :price_override_cents ])
    load_seeds

    assert_equal 4, Product.count
    assert_equal snapshot, ProductVariant.order(:id).select_map([ :id, :stock, :price_override_cents ])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/seeds_test.rb`
Expected: failures. `Product.count` is 0, because Task 1 emptied the seeds.

- [ ] **Step 3: Write the seeds**

Replace everything in `db/seeds.rb` below the generated comment header with:

```ruby
# Sample products for the shop. Idempotent on slug: running this again leaves
# the data as it was. Products go through ProductEditor, the same path the
# admin uses; stock and price overrides are set afterwards by variant label.

sizes = %w[S M L XL 2XL 3XL]
swatches = { "Black" => "#0d1114", "White" => "#f7f7f5", "Heather Grey" => "#b5b8ba", "Red" => "#b3261e" }

shirt_options = lambda do |colours|
  [
    { "name" => "Colour", "values" => colours.map { |colour| { "name" => colour, "swatch_hex" => swatches.fetch(colour) } } },
    { "name" => "Size", "values" => sizes.map { |size| { "name" => size } } }
  ]
end

samples = [
  {
    slug: "3-crow", name: "3 Crow", description: "Three crows, one shirt. Front print, heavy cotton.",
    image: "3crow.png", price: "12.00", options: shirt_options.call([ "Black", "White", "Heather Grey" ]),
    stock: {
      "Black"        => [ 24, 31, 17, 8, 3, 1 ],
      "White"        => [ 18, 22, 14, 5, 2, 0 ],
      "Heather Grey" => [ 6,  9,  4,  2, 0, 0 ]
    },
    # The bigger blanks cost more, so this design charges more for them.
    overrides: { "2XL" => 1400, "3XL" => 1400 }
  },
  {
    slug: "see-that-shit", name: "See That Shit", description: "Say it with a shirt. Front and back print.",
    image: "see_that_shit.png", price: "12.00", options: shirt_options.call([ "Black", "Red" ]),
    stock: {
      "Black" => [ 12, 15, 11, 6, 2, 0 ],
      "Red"   => [ 7,  10, 8,  3, 1, 0 ]
    }
  },
  {
    slug: "third-eye-smiley", name: "Third Eye Smiley", description: "Single colour print, one garment colour, no fuss.",
    image: "3rd_eye_smiley.png", price: "12.00", options: shirt_options.call([ "Black" ]),
    stock: { "Black" => [ 9, 13, 10, 4, 2, 1 ] }
  },
  {
    slug: "3-crow-sticker", name: "3 Crow Sticker", description: "Die-cut vinyl sticker, three inches across.",
    image: "3crow.png", price: "4.00", options: [], stock: 50
  }
]

samples.each do |sample|
  editor = ProductEditor.new(Product.first(slug: sample[:slug]) || Product.new, {
    "product" => {
      "name" => sample[:name], "slug" => sample[:slug], "description" => sample[:description],
      "image" => sample[:image], "price" => sample[:price], "active" => "1"
    },
    "options" => sample[:options]
  })
  raise "Could not seed #{sample[:slug]}: #{editor.errors.join(' ')}" unless editor.save

  product = editor.product
  product.variants.each do |variant|
    if product.simple?
      variant.update(stock: sample[:stock])
    else
      colour, size = variant.label.split(" / ")
      variant.update(
        stock: sample[:stock].fetch(colour)[sizes.index(size)],
        price_override_cents: sample.fetch(:overrides, {})[size]
      )
    end
  end
end

puts "Seeded #{Product.count} products, #{ProductVariant.count} variants." unless Rails.env.test?
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/seeds_test.rb`
Expected: 6 runs, 0 failures. The output should not contain `Seeded`.

- [ ] **Step 5: Load the seeds into development**

```bash
bin/rails db:seed
```

Expected: `Seeded 4 products, 43 variants.` (18 + 12 + 6 + 1).

- [ ] **Step 6: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Seed three shirts and a sticker through ProductEditor

The shirts carry Colour and Size options with swatches; 3 Crow uses
price overrides for its big sizes; the sticker is a simple item.
Seeding no longer prints into test output.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Admin list, new, create and structural edits

**Files:**
- Modify (rewrite): `app/controllers/admin/products_controller.rb`
- Modify (rewrite): `app/views/admin/products/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Create: `app/views/shared/_swatch.html.erb`
- Modify: `app/helpers/application_helper.rb`
- Test: `test/integration/admin_products_test.rb` (recreate)

**Interfaces:**
- Consumes: `ProductEditor` (all of it), `Product#simple?`, `#swatch_option`, `#price_range`, `#total_stock`, the test helpers.
- Produces:
  - `ApplicationHelper#asset_url_if_exists(filename) -> String | nil`.
  - The partial `shared/_swatch`, with locals `value:` (an `OptionValue`) and optional `size:` (Tailwind size classes, default `"w-4 h-4"`).
  - Form parameter names: `product[...]`, `options[i][name]`, `options[i][values][j][name|position|swatch_hex|swatch_image|image]`, `simple_stock`.
  - Markup hooks for Task 8: `data-controller="image-preview option-editor"` on the form, `data-option-block` on each option fieldset, `data-option-editor-target="spareOption"` on empty option blocks, `data-value-row` on each value row, `data-option-editor-target="spareValue"` on empty value rows, and hidden buttons with `data-option-editor-target="addValue"` and `"addOption"`.
  - The `_form` partial takes locals `form_url`, `form_method`, `submit_label` and optional `show_simple_stock`.

- [ ] **Step 1: Write the failing tests**

Create `test/integration/admin_products_test.rb`:

```ruby
require "test_helper"

class AdminProductsTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def shirt(name: "Sample Tee", slug: "sample", stock: 3)
    build_product(name: name, slug: slug, stock: stock, options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S", "M" ] })
  end

  def new_product_params(overrides = {})
    {
      "product" => {
        "name" => "New Tee", "slug" => "new-tee", "description" => "Fresh.",
        "image" => "3crow.png", "price" => "12.00", "active" => "1"
      },
      "options" => {
        "0" => { "name" => "Colour", "values" => { "0" => { "name" => "Black" }, "1" => { "name" => "White" }, "2" => { "name" => "" } } },
        "1" => { "name" => "Size", "values" => { "0" => { "name" => "S" }, "1" => { "name" => "M" }, "2" => { "name" => "L" } } },
        "2" => { "name" => "", "values" => { "0" => { "name" => "" } } }
      }
    }.deep_merge(overrides)
  end

  def no_options
    { "options" => { "0" => { "name" => "", "values" => { "0" => { "name" => "" } } } } }
  end

  test "signed out visitors are redirected away from the product pages" do
    product = shirt

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "signed out visitors are redirected away from create, update and delete" do
    product = shirt

    post "/admin/products", params: new_product_params
    assert_response :redirect
    patch "/admin/products/#{product.id}", params: form_params_for(product).deep_merge("product" => { "name" => "Nope" })
    assert_response :redirect
    delete "/admin/products/#{product.id}"
    assert_response :redirect

    assert_equal 1, Product.count, "nothing should have been written"
    assert_equal "Sample Tee", Product[product.id].name
  end

  test "a non-superuser gets a 404 from every product route" do
    product = shirt
    sign_in create_account(superuser: false)

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :not_found, "expected #{path} to 404 for a non-superuser"
    end

    post "/admin/products", params: new_product_params
    assert_response :not_found
    patch "/admin/products/#{product.id}", params: form_params_for(product)
    assert_response :not_found
    delete "/admin/products/#{product.id}"
    assert_response :not_found

    assert_equal 1, Product.count
  end

  test "the list summarises options, variants and stock" do
    shirt(name: "Listed Tee")
    build_product(name: "Listed Sticker", options: {}, stock: 9)
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Options"
    assert_select "td", text: /Colour · Size/
    assert_select "td", text: "Simple item"
    assert_select "td", text: "4"
    assert_select "td", text: "12"
  end

  test "the list shows an empty state with no products" do
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "table", count: 0
  end

  test "the list still renders when a product's image no longer resolves" do
    product = shirt
    product.set(image: "no-longer-on-disk.png")
    product.save(validate: false)
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "body", text: /Sample Tee/
  end

  test "the new form offers three option blocks, value rows and a simple stock field" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    assert_response :success
    assert_select "input[name='product[price]'][value='12.00']"
    assert_select "fieldset[data-option-block]", 3
    assert_select "input[name='options[0][name]']"
    assert_select "input[name='options[0][values][0][name]']"
    assert_select "input[name='options[0][values][0][swatch_hex]']"
    assert_select "input[name='simple_stock']"
  end

  test "the new form can start from another product's options" do
    source = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/new", params: { copy_from: source.id }
    assert_response :success
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_select "input[name='options[0][values][1][name]'][value='Red']"
    assert_select "input[name='options[1][values][1][name]'][value='M']"
  end

  test "creating a product with options builds its variants and goes to edit for stock" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params
    product = Product.first(slug: "new-tee")
    assert product, "the product should exist"
    assert_redirected_to "/admin/products/#{product.id}/edit"

    assert_equal [ "Colour", "Size" ], product.options.map(&:name)
    assert_equal 6, product.variants.size
    assert_equal [ 0 ], product.variants.map(&:stock).uniq
    assert_equal 1200, product.price_cents
  end

  test "creating a simple product takes its stock and goes back to the list" do
    sign_in create_account(superuser: true)

    # merge, not deep_merge: the options must be replaced wholesale, not merged row by row.
    post "/admin/products", params: new_product_params.merge(no_options).merge("simple_stock" => "12")
    assert_redirected_to "/admin/products"

    product = Product.first(slug: "new-tee")
    assert product.simple?
    assert_equal 12, product.variants.first.stock
  end

  test "an invalid product re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "name" => "", "slug" => "" })
    assert_response :unprocessable_entity
    assert_select "li", text: "Name is not present."
    assert_equal 0, Product.count
  end

  test "a rejected malformed price is redisplayed as typed, not as 0.00" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "price" => "12.0.0" })
    assert_response :unprocessable_entity
    assert_select "input[name='product[price]'][value='12.0.0']"
    assert_select "li", text: "Price must be an amount like 12.00."
    assert_equal 0, Product.count
  end

  test "an option without values re-renders with the option kept" do
    sign_in create_account(superuser: true)

    params = new_product_params
    params["options"]["0"]["values"] = { "0" => { "name" => "" } }
    post "/admin/products", params: params

    assert_response :unprocessable_entity
    assert_select "li", text: "Colour needs at least one value."
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_equal 0, Product.count
  end

  test "a bogus image filename is rejected and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "image" => "nope.png" })
    assert_response :unprocessable_entity
    assert_select "body", text: /is not a file in app\/assets\/images/i
    assert_equal 0, Product.count
  end

  test "a duplicate slug re-renders rather than raising" do
    shirt(slug: "taken")
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "slug" => "taken" })
    assert_response :unprocessable_entity
    assert_select "li", text: "Slug is already taken."
  end

  # Propshaft serves only digested filenames in production, so the preview
  # must be handed asset_path URLs; a plain /assets/3crow.png would 404 there.
  test "the form carries digested asset urls for the image preview" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    sources = JSON.parse(css_select("form[data-image-preview-sources-value]").first["data-image-preview-sources-value"])

    assert_match %r{\A/assets/3crow-[0-9a-f]+\.png\z}, sources["3crow.png"]
    refute sources.key?("no-such-image.png")
  end

  test "the edit form is prefilled with the product's options" do
    product = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/#{product.id}/edit"
    assert_response :success
    assert_select "input[name='product[name]'][value='Sample Tee']"
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_select "input[name='options[0][values][1][name]'][value='Red']"
    assert_select "input[name='options[0][values][1][position]'][value='2']"
  end

  test "renaming a product goes back to the list" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: form_params_for(product).deep_merge("product" => { "name" => "Renamed Tee" })
    assert_redirected_to "/admin/products"
    assert_equal "Renamed Tee", product.refresh.name
  end

  test "an unchanged save goes back to the list and changes nothing" do
    product = shirt
    before = product.variants.map { |v| [ v.id, v.stock ] }
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: form_params_for(product)
    assert_redirected_to "/admin/products"
    assert_equal before, product.refresh.variants.map { |v| [ v.id, v.stock ] }
  end

  test "adding a value comes back to edit so the new stock can be filled in" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: with_value(form_params_for(product), "Size", "L")
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal 6, product.refresh.variants.size
  end

  test "editing an unknown product is a 404" do
    sign_in create_account(superuser: true)

    get "/admin/products/999999/edit"
    assert_response :not_found
  end

  test "deleting a product takes its options and variants with it" do
    product = shirt
    sign_in create_account(superuser: true)

    delete "/admin/products/#{product.id}"
    assert_redirected_to "/admin/products"
    assert_nil Product[product.id]
    assert_equal 0, ProductVariant.where(product_id: product.id).count
    assert_equal 0, ProductOption.where(product_id: product.id).count
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: most tests error with `NameError: uninitialized constant Product::SIZES` raised from the old controller or views.

- [ ] **Step 3: Add the asset helper**

In `app/helpers/application_helper.rb`, replace `product_image_tag` with these two methods:

```ruby
  # The served URL for a filename under app/assets/images, or nil when no such
  # file exists. Every render site guards this way rather than calling
  # image_tag directly: Propshaft raises on a missing asset, and a file can
  # disappear after a product was saved.
  def asset_url_if_exists(filename)
    return nil if filename.blank? || !Product.asset_exists?(filename)

    asset_path(filename)
  end

  # Renders a product's image, or nil (the caller's empty placeholder box)
  # when the filename does not resolve.
  def product_image_tag(product, **options)
    return nil unless asset_url_if_exists(product.image)

    image_tag(product.image, **options)
  end
```

- [ ] **Step 4: Add the swatch partial**

Create `app/views/shared/_swatch.html.erb`:

```erb
<%# One option value's swatch dot: its swatch image when it has one, else its hex. %>
<% size = local_assigns.fetch(:size, "w-4 h-4") %>
<% if (url = asset_url_if_exists(value.swatch_image)) %>
  <img src="<%= url %>" alt="" class="inline-block <%= size %> rounded-full border border-gray-300 object-cover">
<% else %>
  <span class="inline-block <%= size %> rounded-full border border-gray-300" style="background-color: <%= value.swatch_hex %>"></span>
<% end %>
```

- [ ] **Step 5: Rewrite the controller**

Replace all of `app/controllers/admin/products_controller.rb`:

```ruby
module Admin
  class ProductsController < BaseController
    def index
      @products = Product.order(:name).eager(:variants, options: :option_values).all
    end

    def new
      source = Product[params[:copy_from].to_i] if params[:copy_from].present?
      @editor = ProductEditor.blank(copy_from: source)
      @copy_sources = copy_sources
    end

    def create
      @editor = ProductEditor.new(Product.new, editor_params)

      unless @editor.save
        @copy_sources = copy_sources
        return render :new, status: :unprocessable_entity
      end

      product = @editor.product
      if product.simple?
        redirect_to admin_products_path, notice: "#{product.name} created."
      else
        redirect_to edit_admin_product_path(product.id),
          notice: "#{product.name} created with #{helpers.pluralize(product.variants.size, 'variant')}. Set stock below."
      end
    end

    def edit
      @editor = ProductEditor.from_product(find_product!)
    end

    def update
      @editor = ProductEditor.new(find_product!, editor_params)
      return render :edit, status: :unprocessable_entity unless @editor.save

      product = @editor.product
      if @editor.variants_changed?
        redirect_to edit_admin_product_path(product.id), notice: "#{product.name} saved. Its variants changed, so check stock below."
      else
        redirect_to admin_products_path, notice: "#{product.name} updated."
      end
    end

    def destroy
      product = find_product!
      name = product.name
      product.destroy

      redirect_to admin_products_path, notice: "#{name} deleted."
    end

    private

    # A 404 rather than a redirect, matching how the admin gate hides itself.
    def find_product!
      Product[params[:id].to_i] or raise ActionController::RoutingError, "Not Found"
    end

    def copy_sources
      Product.order(:name).select_map([ :id, :name ])
    end

    # ProductEditor reads every key it uses by name and never mass-assigns, so
    # handing it the raw hash is safe. Only the keys the form sends pass.
    def editor_params
      params.to_unsafe_h.slice("product", "options", "variants", "confirm_loss", "simple_stock")
    end
  end
end
```

- [ ] **Step 6: Rewrite the list**

Replace all of `app/views/admin/products/index.html.erb`:

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
        <%= render layout: "shared/data_table", locals: { headers: [ "", "Product", "Price", "Options", "Variants", "In stock", "Status", "" ] } do %>
          <% @products.each do |product| %>
            <tr>
              <td class="py-3 pr-6">
                <div class="w-10 h-10 rounded bg-gray-100 overflow-hidden flex items-center justify-center">
                  <%= product_image_tag product, alt: "", class: "w-full h-full object-cover" %>
                </div>
              </td>
              <td class="py-3 pr-6 font-bold"><%= product.name %></td>
              <td class="py-3 pr-6 whitespace-nowrap">
                <% low, high = product.price_range %>
                <%= low == high ? price(low) : "#{price(low)} – #{price(high)}" %>
              </td>
              <% if product.simple? %>
                <td class="py-3 pr-6 text-gray-500">Simple item</td>
              <% else %>
                <td class="py-3 pr-6">
                  <%= product.options.map(&:name).join(" · ") %>
                  <% if (swatch_option = product.swatch_option) %>
                    <div class="mt-1 flex items-center gap-1">
                      <% swatch_option.option_values.select(&:swatch?).each do |value| %>
                        <span title="<%= value.name %>"><%= render "shared/swatch", value: value %></span>
                      <% end %>
                    </div>
                  <% end %>
                </td>
              <% end %>
              <td class="py-3 pr-6 text-gray-600"><%= product.variants.size %></td>
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

- [ ] **Step 7: Rewrite the form partial**

Replace all of `app/views/admin/products/_form.html.erb`:

```erb
<%
  field_class = "px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40"
  label_class = "block text-xs font-bold uppercase tracking-widest text-gray-500"
  product = @editor.product
  spare_value_rows = 3
  option_rows = @editor.option_inputs +
    Array.new([ Product::MAX_OPTIONS - @editor.option_inputs.size, 0 ].max) { { name: "", values: [] } }
%>
<%= form_with url: form_url, method: form_method,
      data: { turbo: false, controller: "image-preview option-editor", image_preview_sources_value: product_image_sources.to_json },
      class: "space-y-8" do %>
  <% if @editor.errors.any? %>
    <div class="border-2 border-brand-orange rounded-lg p-4">
      <p class="font-bold text-sm uppercase tracking-widest text-brand-orange">Could not save</p>
      <ul class="mt-2 space-y-1 text-sm text-gray-700">
        <% @editor.errors.each do |message| %>
          <li><%= message %></li>
        <% end %>
      </ul>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Details" } do %>
    <div class="grid sm:grid-cols-2 gap-4">
      <div class="sm:col-span-2">
        <label for="product_name" class="<%= label_class %>">Name</label>
        <input id="product_name" name="product[name]" type="text" value="<%= product.name %>" class="mt-2 w-full <%= field_class %>">
      </div>

      <div class="sm:col-span-2">
        <label for="product_slug" class="<%= label_class %>">Slug</label>
        <input id="product_slug" name="product[slug]" type="text" value="<%= product.slug %>" placeholder="left blank, generated from the name"
               class="mt-2 w-full <%= field_class %>">
      </div>

      <div class="sm:col-span-2">
        <label for="product_description" class="<%= label_class %>">Description</label>
        <textarea id="product_description" name="product[description]" rows="3" class="mt-2 w-full <%= field_class %>"><%= product.description %></textarea>
      </div>

      <div>
        <label for="product_image" class="<%= label_class %>">Image filename</label>
        <div class="mt-2 flex items-center gap-3">
          <input id="product_image" name="product[image]" type="text" value="<%= product.image %>" placeholder="3crow.png"
                 data-image-preview-target="input" data-action="input->image-preview#update"
                 class="w-full <%= field_class %>">
          <img data-image-preview-target="preview" alt="" class="hidden w-12 h-12 flex-shrink-0 rounded object-cover border-2 border-gray-200">
        </div>
        <p data-image-preview-target="status" class="mt-1 hidden text-xs font-bold text-brand-orange"></p>
        <p class="mt-1 text-xs text-gray-500">A file in <code>app/assets/images/</code>.</p>
      </div>

      <div>
        <label for="product_price" class="<%= label_class %>">Price</label>
        <input id="product_price" name="product[price]" type="text" inputmode="decimal" value="<%= @editor.price_input %>"
               class="mt-2 w-full <%= field_class %>">
        <p class="mt-1 text-xs text-gray-500">Every variant sells at this price unless you give it its own.</p>
      </div>

      <div class="sm:col-span-2">
        <label class="flex items-center gap-3 text-sm">
          <input type="hidden" name="product[active]" value="0">
          <input type="checkbox" name="product[active]" value="1" class="accent-brand-green" <%= "checked" if product.active %>>
          Visible in the shop
        </label>
      </div>
    </div>
  <% end %>

  <%= render layout: "shared/panel", locals: { title: "Options", subtitle: "Up to #{Product::MAX_OPTIONS}, such as Size or Colour. Leave them all empty for a simple item like a sticker." } do %>
    <p class="mb-4 text-sm text-brand-orange font-bold">
      Removing or renaming a value deletes its variants and their stock. If any of them have stock, you will be asked to confirm.
    </p>

    <div class="space-y-6">
      <% option_rows.each_with_index do |option, i| %>
        <fieldset class="border-2 border-gray-200 rounded-lg p-4" data-option-block
                  <% if option[:name].blank? && option[:values].empty? %>data-option-editor-target="spareOption"<% end %>>
          <legend class="px-2 <%= label_class %>">Option <%= i + 1 %></legend>
          <input name="options[<%= i %>][name]" type="text" value="<%= option[:name] %>" placeholder="Size, Colour, Finish…"
                 aria-label="Option <%= i + 1 %> name" class="w-full <%= field_class %>">

          <div class="mt-4 hidden sm:grid grid-cols-12 gap-2 <%= label_class %>">
            <span class="col-span-4">Value</span>
            <span class="col-span-1">Order</span>
            <span class="col-span-2">Swatch colour</span>
            <span class="col-span-2">Swatch image</span>
            <span class="col-span-3">Photo</span>
          </div>

          <div class="mt-2 space-y-2">
            <% (option[:values] + Array.new(spare_value_rows) { {} }).each_with_index do |value, j| %>
              <% base = "options[#{i}][values][#{j}]" %>
              <% described = "option #{i + 1} value #{j + 1}" %>
              <div class="grid grid-cols-2 sm:grid-cols-12 gap-2" data-value-row
                   <% if value[:name].blank? %>data-option-editor-target="spareValue"<% end %>>
                <input name="<%= base %>[name]" type="text" value="<%= value[:name] %>" placeholder="Value"
                       aria-label="Name of <%= described %>" class="col-span-2 sm:col-span-4 <%= field_class %>">
                <input name="<%= base %>[position]" type="number" min="1" step="1" value="<%= value[:position] %>"
                       aria-label="Order of <%= described %>" class="sm:col-span-1 <%= field_class %>">
                <input name="<%= base %>[swatch_hex]" type="text" value="<%= value[:swatch_hex] %>" placeholder="#0d1114"
                       aria-label="Swatch colour of <%= described %>" class="sm:col-span-2 <%= field_class %>">
                <input name="<%= base %>[swatch_image]" type="text" value="<%= value[:swatch_image] %>" placeholder="tie_dye.png"
                       aria-label="Swatch image of <%= described %>" class="sm:col-span-2 <%= field_class %>">
                <input name="<%= base %>[image]" type="text" value="<%= value[:image] %>" placeholder="3crow_red.png"
                       aria-label="Photo for <%= described %>" class="col-span-2 sm:col-span-3 <%= field_class %>">
              </div>
            <% end %>
          </div>

          <button type="button" class="hidden mt-3 text-xs font-bold uppercase tracking-widest text-brand-green"
                  data-option-editor-target="addValue" data-action="option-editor#addValue">+ Add value</button>
        </fieldset>
      <% end %>
    </div>

    <button type="button" class="hidden mt-4 text-xs font-bold uppercase tracking-widest text-brand-green"
            data-option-editor-target="addOption" data-action="option-editor#addOption">+ Add option</button>
  <% end %>

  <% if local_assigns[:show_simple_stock] %>
    <%= render layout: "shared/panel", locals: { title: "Stock", subtitle: "For a simple item with no options. Products with options get their stock on the next page." } do %>
      <label for="simple_stock" class="<%= label_class %>">Units on hand</label>
      <input id="simple_stock" name="simple_stock" type="number" min="0" step="1" value="<%= @editor.simple_stock_input %>"
             class="mt-2 w-32 <%= field_class %>">
    <% end %>
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

- [ ] **Step 8: Rewrite the new and edit pages**

Replace all of `app/views/admin/products/new.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "NEW", heading_bottom: "PRODUCT." %>

  <%= render "admin/tabs" %>

  <section class="max-w-4xl mx-auto px-6 py-12 space-y-8">
    <% if @copy_sources.any? %>
      <%= form_with url: new_admin_product_path, method: :get, data: { turbo: false }, class: "flex flex-wrap items-end gap-3" do %>
        <div>
          <label for="copy_from" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Copy options from</label>
          <select id="copy_from" name="copy_from"
                  class="mt-2 px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
            <option value="">Start blank</option>
            <% @copy_sources.each do |id, name| %>
              <option value="<%= id %>" <%= "selected" if params[:copy_from].to_i == id %>><%= name %></option>
            <% end %>
          </select>
        </div>
        <button type="submit" class="text-xs font-bold uppercase tracking-widest text-brand-green underline decoration-2 underline-offset-4">Copy</button>
      <% end %>
    <% end %>

    <%= render "form", form_url: admin_products_path, form_method: :post, submit_label: "Create product", show_simple_stock: true %>
  </section>
</div>
```

Replace all of `app/views/admin/products/edit.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "EDIT", heading_bottom: "PRODUCT." %>

  <%= render "admin/tabs" %>

  <section class="max-w-4xl mx-auto px-6 py-12 space-y-8">
    <%= render "form",
          form_url: admin_product_path(@editor.product.id),
          form_method: :patch,
          submit_label: "Save changes" %>

    <div class="pt-8 border-t-2 border-gray-200">
      <%= button_to "Delete this product", admin_product_path(@editor.product.id),
            method: :delete,
            form: { data: { turbo_confirm: "Delete #{@editor.product.name} and all of its stock records? This cannot be undone." } },
            class: "text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-brand-orange underline decoration-2 underline-offset-4" %>
      <p class="mt-2 text-xs text-gray-500">
        Deletes the product, its options and all of its stock records. Untick “Visible in the shop” instead to hide it without losing data.
      </p>
    </div>
  </section>
</div>
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: 22 runs, 0 failures, 0 errors.

- [ ] **Step 10: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`. `params.to_unsafe_h` is not a Brakeman mass-assignment finding, because `ProductEditor` is not an ActiveRecord model. If Brakeman still reports it, stop and report the warning rather than adding an ignore entry.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Rebuild the admin product pages around options

The list summarises each product's options, variant count and stock.
The form edits up to three options with their values, swatches and
photos, works without JavaScript by padding spare rows, and can copy
options from another product. Creating a product with options goes to
the edit page for stock; a simple product takes its stock up front.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Admin variant table and stock-loss confirmation

**Files:**
- Create: `app/views/admin/products/_variants.html.erb`, `app/views/admin/products/_pending_loss.html.erb`
- Modify: `app/views/admin/products/_form.html.erb`
- Test: `test/integration/admin_products_test.rb` (append)

**Interfaces:**
- Consumes: `@editor.pending_loss`, `@editor.variant_inputs`, `ProductVariant#label`, `ProductEditor.format_money`.
- Produces:
  - Parameter names `variants[ID][stock|price_override|sku]` and `confirm_loss`.
  - Markup hooks for Task 8: `data-controller="variant-filter"`, a hidden `data-variant-filter-target="query"` search box rendered only above 30 variants, and `data-variant-filter-target="row"` with `data-label` on each row.
  - `data-pending-loss` on the confirmation panel.

- [ ] **Step 1: Append the failing tests**

Add to `AdminProductsTest`, before the final `end`:

```ruby
  test "the edit form has a stock, price and SKU field for every variant" do
    product = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/#{product.id}/edit"
    product.variants.each do |variant|
      assert_select "input[name='variants[#{variant.id}][stock]'][value='3'][aria-label='Stock for #{variant.label}']"
      assert_select "input[name='variants[#{variant.id}][price_override]'][placeholder='12.00']"
      assert_select "input[name='variants[#{variant.id}][sku]']"
    end
    assert_select "td", text: "Red / M"
  end

  test "updating one stock cell leaves the others alone" do
    product = shirt
    target = variant_named(product, "Red / S")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["stock"] = "11"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_redirected_to "/admin/products"

    product.refresh.variants.each do |variant|
      assert_equal(variant.id == target.id ? 11 : 3, variant.stock, variant.label)
    end
  end

  test "a price override is saved for one variant" do
    product = shirt
    target = variant_named(product, "Black / M")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["price_override"] = "14.00"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_equal 1400, target.refresh.price_override_cents
    assert_equal [ 1200, 1400 ], product.refresh.price_range
  end

  test "a malformed override re-renders as typed and writes nothing" do
    product = shirt
    target = variant_named(product, "Black / M")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["price_override"] = "lots"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_response :unprocessable_entity
    assert_select "li", text: "Price for Black / M must be an amount like 12.00, or blank to use the product price."
    assert_select "input[name='variants[#{target.id}][price_override]'][value='lots']"
    assert_nil target.refresh.price_override_cents
  end

  test "a SKU used by another product re-renders rather than raising" do
    other = shirt(name: "Other Tee", slug: "other")
    variant_named(other, "Black / S").update(sku: "TAKEN")
    product = shirt
    target = variant_named(product, "Black / S")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["sku"] = "TAKEN"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_response :unprocessable_entity
    assert_select "li", text: "Black / S: Sku is already taken."
  end

  test "removing a value with stock asks for confirmation and deletes nothing" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: without_value(form_params_for(product), "Colour", "Red")
    assert_response :unprocessable_entity
    assert_select "[data-pending-loss] li", text: /Red \/ S — 3 in stock/
    assert_select "[data-pending-loss] li", text: /Red \/ M — 3 in stock/
    assert_select "input[type='checkbox'][name='confirm_loss']"
    assert_equal 4, product.refresh.variants.size
  end

  test "confirming the loss deletes the variants" do
    product = shirt
    sign_in create_account(superuser: true)

    params = without_value(form_params_for(product), "Colour", "Red").merge("confirm_loss" => "1")
    patch "/admin/products/#{product.id}", params: params
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal [ "Black / S", "Black / M" ], product.refresh.variants.map(&:label)
  end

  test "removing a value with no stock needs no confirmation" do
    product = shirt(stock: 0)
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: without_value(form_params_for(product), "Colour", "Red")
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal 2, product.refresh.variants.size
  end

  test "a filter box appears only when there are more than thirty variants" do
    small = shirt
    big = build_product(name: "Big Tee", options: { "Colour" => %w[A B C D E F], "Size" => %w[S M L XL 2XL 3XL] })
    sign_in create_account(superuser: true)

    get "/admin/products/#{small.id}/edit"
    assert_select "input[data-variant-filter-target='query']", count: 0

    get "/admin/products/#{big.id}/edit"
    assert_select "input[data-variant-filter-target='query']", count: 1
    assert_select "tr[data-variant-filter-target='row']", 36
  end

  test "a simple product's edit form has one variant row and no label column" do
    sticker = build_product(name: "Sticker", options: {}, stock: 8)
    sign_in create_account(superuser: true)

    get "/admin/products/#{sticker.id}/edit"
    assert_select "input[name='variants[#{sticker.variants.first.id}][stock]'][value='8']"
    assert_select "th", text: "Variant", count: 0
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: the tests that look for markup fail: the variant inputs, the redisplayed override, the pending-loss panel, the filter box and the simple product's row. The tests that only check saved data already pass, because `ProductEditor` does that work: one stock cell, the override, the SKU clash, confirming the loss and zero-stock removal. Keep them as regression checks over the full HTTP path.

- [ ] **Step 3: Write the pending-loss partial**

Create `app/views/admin/products/_pending_loss.html.erb`:

```erb
<div class="border-2 border-brand-orange rounded-lg p-4" data-pending-loss>
  <p class="font-bold text-sm uppercase tracking-widest text-brand-orange">This deletes stock</p>
  <p class="mt-2 text-sm text-gray-700">
    These variants no longer match the options and would be deleted along with their stock.
    Adding or removing a whole option replaces every variant, so you would re-enter stock afterwards.
  </p>
  <ul class="mt-3 space-y-1 text-sm text-gray-700">
    <% @editor.pending_loss.each do |loss| %>
      <li><span class="font-bold"><%= loss.label %></span> — <%= loss.stock %> in stock</li>
    <% end %>
  </ul>
  <label class="mt-4 flex items-center gap-3 text-sm font-bold">
    <input type="checkbox" name="confirm_loss" value="1" class="accent-brand-orange">
    Delete these variants and their stock
  </label>
</div>
```

- [ ] **Step 4: Write the variants partial**

Create `app/views/admin/products/_variants.html.erb`:

```erb
<%
  field_class = "px-2 py-1 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40"
  head_class = "py-3 pr-6 text-xs font-bold uppercase tracking-widest text-gray-500 whitespace-nowrap"
  product = @editor.product
  variants = product.variants
  default_price = ProductEditor.format_money(product.price_cents)
%>
<%= render layout: "shared/panel", locals: { title: "Variants", subtitle: "Stock on hand for each. Leave the price blank to sell at the product price." } do %>
  <div data-controller="variant-filter">
    <% if variants.size > 30 %>
      <input type="search" placeholder="Filter variants, e.g. black" aria-label="Filter variants"
             class="hidden mb-4 w-full <%= field_class %>"
             data-variant-filter-target="query" data-action="input->variant-filter#filter">
    <% end %>

    <div class="overflow-x-auto">
      <table class="w-full text-left text-sm">
        <thead>
          <tr class="border-b-2 border-brand-green">
            <% unless product.simple? %><th class="<%= head_class %>">Variant</th><% end %>
            <th class="<%= head_class %>">Stock</th>
            <th class="<%= head_class %>">Price</th>
            <th class="<%= head_class %>">SKU</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200">
          <% variants.each do |variant| %>
            <% input = @editor.variant_inputs.fetch(variant.id.to_s, {}) %>
            <% base = "variants[#{variant.id}]" %>
            <tr data-variant-filter-target="row" data-label="<%= variant.label.downcase %>">
              <% unless product.simple? %>
                <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= variant.label %></td>
              <% end %>
              <td class="py-3 pr-6">
                <input name="<%= base %>[stock]" type="number" min="0" step="1" value="<%= input.fetch("stock", variant.stock) %>"
                       aria-label="Stock for <%= variant.label %>" class="w-24 <%= field_class %>">
              </td>
              <td class="py-3 pr-6">
                <input name="<%= base %>[price_override]" type="text" inputmode="decimal"
                       value="<%= input.fetch("price_override", ProductEditor.format_money(variant.price_override_cents)) %>"
                       placeholder="<%= default_price %>" aria-label="Price for <%= variant.label %>" class="w-24 <%= field_class %>">
              </td>
              <td class="py-3 pr-6">
                <input name="<%= base %>[sku]" type="text" value="<%= input.fetch("sku", variant.sku) %>"
                       aria-label="SKU for <%= variant.label %>" class="w-36 <%= field_class %>">
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  </div>
<% end %>
```

- [ ] **Step 5: Render both from the form**

In `app/views/admin/products/_form.html.erb`, directly after the closing `<% end %>` of the `if @editor.errors.any?` block, add:

```erb

  <%= render "pending_loss" if @editor.pending_loss.any? %>
```

After the closing `<% end %>` of the `if local_assigns[:show_simple_stock]` block, and before the submit `div`, add:

```erb

  <%= render "variants" unless product.new? %>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/integration/admin_products_test.rb`
Expected: 32 runs, 0 failures.

- [ ] **Step 7: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add the variant table and stock-loss confirmation to the admin

Each variant gets stock, an optional price override and an optional
SKU on the edit page. When a save would delete variants that still
hold stock, the form comes back listing them with a confirmation box.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The public shop

**Files:**
- Modify: `app/controllers/shop_controller.rb`, `app/views/shop/index.html.erb`, `app/views/shop/show.html.erb`
- Create: `app/helpers/shop_helper.rb`
- Test: `test/integration/shop_test.rb` (recreate)

**Interfaces:**
- Consumes: `Product#simple?`, `#swatch_option`, `#price_range`, `ProductVariant#label`, `#price_cents`, `#sold_out?`, `shared/_swatch`, `asset_url_if_exists`, `build_product`, `variant_named`.
- Produces:
  - `ShopHelper#price_label(product) -> String` (`"$12.00"` or `"From $12.00"`), `#variant_picker_variants(product) -> Array<Hash>` (`{ id:, values: [ids], price: "$12.00", stock: }`), `#variant_picker_images(product) -> Hash<value id, url>`.
  - Markup hooks for Task 8: `data-controller="variant-picker"` on the product section, with `data-variant-picker-variants-value`, `-images-value` and `-from-value`. Targets: `picker` (hidden wrapper), `button` (with `data-option-id`, `data-value-id`), `fixed` (single-value option label, with the same data), `price`, `status`, `list`, `image`.

- [ ] **Step 1: Write the failing tests**

Create `test/integration/shop_test.rb`:

```ruby
require "test_helper"

class ShopTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def shirt(slug:, name: "Tee", active: true, colours: [ "Black" ], stock: 5)
    product = build_product(
      name: name, slug: slug, active: active, stock: stock,
      options: { "Colour" => colours.map { |colour| { name: colour, swatch_hex: "#0d1114" } }, "Size" => [ "S", "M", "2XL" ] }
    )
    product.variants.select { |variant| variant.label.end_with?("2XL") }.each { |variant| variant.update(price_override_cents: 1400) }
    product.refresh
  end

  def picker
    css_select("[data-controller='variant-picker']").first
  end

  test "the catalog lists published products" do
    shirt(slug: "listed", name: "Listed Tee")

    get "/shop"
    assert_response :success
    assert_select "h1 span", text: "THE"
    assert_select "body", text: /Listed Tee/
  end

  test "the catalog omits inactive products" do
    shirt(slug: "hidden", name: "Hidden Tee", active: false)

    get "/shop"
    assert_select "body", text: /Hidden Tee/, count: 0
  end

  test "the catalog and product page still render when an image no longer resolves" do
    product = shirt(slug: "broken-image", name: "Broken Image Tee")
    product.set(image: "no-longer-on-disk.png")
    product.save(validate: false)

    get "/shop"
    assert_response :success
    get "/shop/broken-image"
    assert_response :success
    assert_select "body", text: /Broken Image Tee/
  end

  test "a card says From when variants differ in price, and a plain price otherwise" do
    shirt(slug: "ranged", name: "Ranged Tee")
    build_product(name: "Sticker", slug: "sticker", price: "4.00")

    get "/shop"
    assert_select "p", text: "From $12.00"
    assert_select "p", text: "$4.00"
  end

  test "a card shows swatches for more than one colour" do
    shirt(slug: "two", name: "Two Tee", colours: [ "Black", "Red" ])
    shirt(slug: "one", name: "One Tee", colours: [ "Black" ])

    get "/shop"
    assert_select "[title='Red']", 1
    assert_select "body", text: /2 colours/
    assert_select "body", text: /1 colour\b/, count: 0
  end

  test "the product page lists every variant with its price" do
    product = shirt(slug: "detail", name: "Detail Tee", colours: [ "Black", "Red" ])

    get "/shop/detail"
    assert_response :success
    assert_select "[data-variant-list] li", 6
    assert_select "[data-variant-id='#{variant_named(product, 'Black / S').id}']", text: /Black \/ S.*\$12\.00/m
    assert_select "[data-variant-id='#{variant_named(product, 'Red / 2XL').id}']", text: /Red \/ 2XL.*\$14\.00/m
  end

  test "a sold out variant is shown rather than hidden" do
    product = shirt(slug: "soldout")
    gone = variant_named(product, "Black / M")
    gone.update(stock: 0)

    get "/shop/soldout"
    assert_select "[data-variant-id='#{gone.id}'][data-sold-out]", text: /Sold out/
    assert_select "[data-sold-out]", 1
  end

  test "each option with several values gets a button group" do
    shirt(slug: "picker", colours: [ "Black", "Red" ])

    get "/shop/picker"
    assert picker, "expected a variant picker"
    assert_select "button[data-variant-picker-target='button']", 5
    assert_select "button[data-value-id]", text: "Red"
  end

  test "an option with one value is a label, not a button group" do
    shirt(slug: "single", colours: [ "Black" ])

    get "/shop/single"
    assert_select "[data-variant-picker-target='fixed']", text: /Black/
    assert_select "button[data-variant-picker-target='button']", 3
  end

  test "the picker is handed each variant's price and stock" do
    product = shirt(slug: "data", colours: [ "Black" ])
    big = variant_named(product, "Black / 2XL")

    get "/shop/data"
    variants = JSON.parse(picker["data-variant-picker-variants-value"])
    assert_equal 3, variants.size

    entry = variants.find { |variant| variant["id"] == big.id }
    assert_equal "$14.00", entry["price"]
    assert_equal 5, entry["stock"]
    assert_equal big.option_values.map(&:id).sort, entry["values"].sort
  end

  test "a value with a photo hands the picker its digested url" do
    product = build_product(name: "Photo Tee", slug: "photo",
      options: { "Colour" => [ { name: "Black", image: "3crow.png" }, "White" ] })
    black = product.options.first.option_values.first

    get "/shop/photo"
    images = JSON.parse(picker["data-variant-picker-images-value"])
    assert_match %r{\A/assets/3crow-[0-9a-f]+\.png\z}, images[black.id.to_s]
    assert_equal 1, images.size
  end

  test "a simple product shows its price and stock with no picker" do
    build_product(name: "Sticker", slug: "sticker", price: "4.00", stock: 3)

    get "/shop/sticker"
    assert_nil picker
    assert_select "h1", text: /\$4\.00/
    assert_select "[data-simple-stock]", text: "In stock"
  end

  test "a sold out simple product says so" do
    build_product(name: "Sticker", slug: "gone-sticker", price: "4.00", stock: 0)

    get "/shop/gone-sticker"
    assert_select "[data-simple-stock][data-sold-out]", text: "Sold out"
  end

  test "markup in a value name is shown as text" do
    build_product(name: "Bold Tee", slug: "bold", options: { "Style" => [ "<b>Bold</b>", "Plain" ] })

    get "/shop/bold"
    assert_select "b", text: "Bold", count: 0
    assert_includes response.body, "&lt;b&gt;Bold&lt;/b&gt;"
  end

  test "an unknown slug is a 404" do
    get "/shop/nope"
    assert_response :not_found
  end

  test "an inactive product 404s rather than revealing itself" do
    shirt(slug: "draft", active: false)

    get "/shop/draft"
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/shop_test.rb`
Expected: errors from the old views (`undefined method 'colors'`, `uninitialized constant Product::SIZES`).

- [ ] **Step 3: Add the shop helper**

Create `app/helpers/shop_helper.rb`:

```ruby
module ShopHelper
  # "$12.00" when every variant costs the same, "From $12.00" when they differ.
  def price_label(product)
    low, high = product.price_range
    low == high ? price(low) : "From #{price(low)}"
  end

  # What the product page's picker needs, computed here so the JavaScript
  # never formats money or reads availability from the markup.
  def variant_picker_variants(product)
    product.variants.map do |variant|
      { id: variant.id, values: variant.option_values.map(&:id), price: price(variant.price_cents), stock: variant.stock }
    end
  end

  # Value id => photo URL, for the values that have their own photo.
  def variant_picker_images(product)
    product.options.flat_map(&:option_values).each_with_object({}) do |value, images|
      url = asset_url_if_exists(value.image)
      images[value.id] = url if url
    end
  end
end
```

- [ ] **Step 4: Update the controller**

Replace all of `app/controllers/shop_controller.rb`:

```ruby
class ShopController < ApplicationController
  def index
    @products = Product.published.eager(:variants, options: :option_values).all
  end

  def show
    @product = Product.where(slug: params[:slug].to_s, active: true)
      .eager(options: :option_values, variants: :option_values)
      .all.first

    # A 404 rather than a redirect: an unpublished product should not announce
    # that it exists.
    raise ActionController::RoutingError, "Not Found" unless @product
  end
end
```

- [ ] **Step 5: Rewrite the catalog**

In `app/views/shop/index.html.erb`, replace everything from `<% low, high = product.price_range %>` through the end of the `<% if product.colors.many? %> … <% end %>` block with:

```erb
              <p class="mt-1 font-bold text-sm"><%= price_label(product) %></p>
              <% swatch_option = product.swatch_option %>
              <% swatches = swatch_option ? swatch_option.option_values.select(&:swatch?) : [] %>
              <% if swatches.many? %>
                <div class="mt-3 flex items-center gap-2">
                  <% swatches.each do |value| %>
                    <span title="<%= value.name %>"><%= render "shared/swatch", value: value %></span>
                  <% end %>
                  <span class="text-xs text-gray-500"><%= pluralize(swatches.size, swatch_option.name.downcase) %></span>
                </div>
              <% end %>
```

- [ ] **Step 6: Rewrite the product page**

Replace all of `app/views/shop/show.html.erb`:

```erb
<%
  picker_data = if @product.simple?
    {}
  else
    {
      controller: "variant-picker",
      variant_picker_variants_value: variant_picker_variants(@product).to_json,
      variant_picker_images_value: variant_picker_images(@product).to_json,
      variant_picker_from_value: price_label(@product)
    }
  end
%>
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: @product.name, heading_bottom: "#{price_label(@product)}." %>

  <%= tag.section class: "max-w-5xl mx-auto px-6 py-12 grid md:grid-cols-2 gap-10", data: picker_data do %>
    <div class="aspect-square bg-gray-100 rounded-xl overflow-hidden flex items-center justify-center">
      <%= product_image_tag @product, alt: @product.name, class: "w-full h-full object-cover", data: { variant_picker_target: "image" } %>
    </div>

    <div>
      <p class="text-gray-700"><%= @product.description %></p>

      <% if @product.simple? %>
        <% sold_out = @product.variants.none? || @product.variants.first.sold_out? %>
        <p class="mt-8 text-xs font-bold uppercase tracking-widest <%= "text-gray-400" if sold_out %>"
           data-simple-stock <%= "data-sold-out" if sold_out %>><%= sold_out ? "Sold out" : "In stock" %></p>
      <% else %>
        <div class="mt-8 hidden space-y-6" data-variant-picker-target="picker">
          <% @product.options.each do |option| %>
            <% values = option.option_values %>
            <div>
              <p class="text-xs font-bold uppercase tracking-widest text-gray-500"><%= option.name %></p>
              <% if values.one? %>
                <p class="mt-2 flex items-center gap-2 text-sm font-bold"
                   data-variant-picker-target="fixed" data-option-id="<%= option.id %>" data-value-id="<%= values.first.id %>">
                  <%= render("shared/swatch", value: values.first) if values.first.swatch? %>
                  <span><%= values.first.name %></span>
                </p>
              <% else %>
                <div class="mt-2 flex flex-wrap gap-2">
                  <% values.each do |value| %>
                    <button type="button" aria-pressed="false"
                            data-variant-picker-target="button" data-action="variant-picker#choose"
                            data-option-id="<%= option.id %>" data-value-id="<%= value.id %>"
                            class="flex items-center gap-2 px-3 py-2 border-2 border-gray-200 rounded-lg text-sm font-bold"><%= render("shared/swatch", value: value) if value.swatch? %><%= value.name %></button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <div class="flex items-baseline justify-between gap-4 border-t-2 border-gray-200 pt-4">
            <span class="font-display text-2xl" data-variant-picker-target="price"></span>
            <span class="text-xs font-bold uppercase tracking-widest" data-variant-picker-target="status"></span>
          </div>
        </div>

        <ul class="mt-8 space-y-2" data-variant-list data-variant-picker-target="list">
          <% @product.variants.each do |variant| %>
            <li class="flex items-center justify-between gap-4 text-sm py-2 border-b border-gray-200 <%= "text-gray-400" if variant.sold_out? %>"
                data-variant-id="<%= variant.id %>" <%= "data-sold-out" if variant.sold_out? %>>
              <span class="font-bold <%= "line-through" if variant.sold_out? %>"><%= variant.label %></span>
              <span class="<%= "line-through" if variant.sold_out? %>"><%= price(variant.price_cents) %></span>
              <span class="text-xs uppercase tracking-widest"><%= variant.sold_out? ? "Sold out" : "In stock" %></span>
            </li>
          <% end %>
        </ul>
      <% end %>

      <p class="mt-8 text-xs text-gray-500">Ordering online is not open yet — get in touch for a quote.</p>
    </div>
  <% end %>
</div>
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/integration/shop_test.rb`
Expected: 16 runs, 0 failures.

- [ ] **Step 8: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Rebuild the shop pages around options

Cards show From pricing when variants differ and swatches from the
first option that has them. The product page lists every variant with
its price and stock, which is complete without JavaScript, and renders
a hidden option picker for the enhancement to switch on. Simple items
show a price and a stock line.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Progressive enhancement and browser check

**Files:**
- Create: `app/javascript/controllers/variant_picker_controller.js`, `option_editor_controller.js`, `variant_filter_controller.js`
- Delete: `app/javascript/controllers/color_switcher_controller.js`, `variant_grid_controller.js`
- Test: `test/integration/stimulus_controllers_test.rb`

**Interfaces:**
- Consumes: the markup hooks listed under Tasks 5, 6 and 7.
- Produces: nothing later tasks use.

- [ ] **Step 1: Write the failing test**

Create `test/integration/stimulus_controllers_test.rb`:

```ruby
require "test_helper"

# A data-controller naming a controller that does not exist fails silently in
# the browser: the page just stops being interactive. This catches that without
# a browser.
class StimulusControllersTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  test "the product pages only name controllers that exist" do
    big = build_product(name: "Big Tee", slug: "big-tee", options: { "Colour" => %w[A B C D E F], "Size" => %w[S M L XL 2XL 3XL] })
    sign_in create_account(superuser: true)

    seen = []
    [ "/admin/products/new", "/admin/products/#{big.id}/edit", "/shop/big-tee" ].each do |path|
      get path
      assert_response :success
      seen.concat(css_select("[data-controller]").flat_map { |element| element["data-controller"].split })
    end

    assert_includes seen, "option-editor"
    assert_includes seen, "variant-filter"
    assert_includes seen, "variant-picker"

    seen.uniq.each do |name|
      path = Rails.root.join("app/javascript/controllers/#{name.tr('-', '_')}_controller.js")
      assert File.exist?(path), "#{name} is used on a page but #{path.relative_path_from(Rails.root)} does not exist"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/stimulus_controllers_test.rb`
Expected: FAIL with `option-editor is used on a page but app/javascript/controllers/option_editor_controller.js does not exist`.

- [ ] **Step 3: Write the variant picker**

Create `app/javascript/controllers/variant_picker_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The product page's option picker. The server renders a full variant list
// that works without JavaScript; this hides it and shows one button group per
// option instead. Prices and stock come from the variants value, rendered by
// the server, so nothing here formats money or reads availability from markup.
export default class extends Controller {
  static targets = ["list", "picker", "button", "fixed", "price", "status", "image"]
  static values = { variants: Array, images: Object, from: String }

  connect() {
    this.selected = new Map()
    this.fixedTargets.forEach((label) => this.selected.set(label.dataset.optionId, Number(label.dataset.valueId)))
    this.optionIds = [...new Set([...this.fixedTargets, ...this.buttonTargets].map((element) => element.dataset.optionId))]
    this.originalImage = this.hasImageTarget ? this.imageTarget.src : null

    this.listTarget.classList.add("hidden")
    this.pickerTarget.classList.remove("hidden")
    this.render()
  }

  choose(event) {
    const optionId = event.currentTarget.dataset.optionId
    const valueId = Number(event.currentTarget.dataset.valueId)

    if (this.selected.get(optionId) === valueId) {
      this.selected.delete(optionId)
    } else {
      this.selected.set(optionId, valueId)
    }
    this.render()
  }

  render() {
    this.buttonTargets.forEach((button) => {
      const optionId = button.dataset.optionId
      const valueId = Number(button.dataset.valueId)
      const chosen = this.selected.get(optionId) === valueId
      const available = this.variantsValue.some((variant) =>
        variant.stock > 0 && variant.values.includes(valueId) && this.matchesOtherOptions(variant, optionId))

      button.setAttribute("aria-pressed", String(chosen))
      button.classList.toggle("border-brand-green", chosen)
      button.classList.toggle("border-gray-200", !chosen)
      button.classList.toggle("line-through", !available)
      button.classList.toggle("text-gray-400", !available)
    })

    const variant = this.selectedVariant()
    this.priceTarget.textContent = variant ? variant.price : this.fromValue
    this.statusTarget.textContent = variant ? (variant.stock > 0 ? "In stock" : "Sold out") : "Choose your options"
    this.showImage()
  }

  matchesOtherOptions(variant, optionId) {
    for (const [otherId, valueId] of this.selected) {
      if (otherId !== optionId && !variant.values.includes(valueId)) return false
    }
    return true
  }

  selectedVariant() {
    if (this.optionIds.some((optionId) => !this.selected.has(optionId))) return null

    const chosen = [...this.selected.values()]
    return this.variantsValue.find((variant) => chosen.every((id) => variant.values.includes(id))) || null
  }

  // The first selected value, in option order, that has its own photo wins.
  showImage() {
    if (!this.hasImageTarget) return

    const withPhoto = this.optionIds.map((optionId) => this.selected.get(optionId)).find((id) => this.imagesValue[id])
    this.imageTarget.src = withPhoto ? this.imagesValue[withPhoto] : this.originalImage
  }
}
```

- [ ] **Step 4: Write the option editor**

Create `app/javascript/controllers/option_editor_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Conveniences for the admin options section. Without JavaScript the form
// renders spare blank rows and option blocks, which the server ignores when
// left empty. With it, the spares start hidden and Add buttons reveal them.
export default class extends Controller {
  static targets = ["spareValue", "spareOption", "addValue", "addOption"]

  connect() {
    this.spareValueTargets.forEach((row) => row.classList.add("hidden"))
    this.spareOptionTargets.forEach((block) => block.classList.add("hidden"))
    this.addValueTargets.forEach((button) => button.classList.remove("hidden"))
    this.refreshAddOption()
  }

  addValue(event) {
    const block = event.currentTarget.closest("[data-option-block]")
    const spare = block.querySelector("[data-value-row].hidden")

    if (spare) {
      this.reveal(spare)
    } else {
      this.reveal(this.cloneValueRow(block))
    }
  }

  addOption() {
    const block = this.spareOptionTargets.find((candidate) => candidate.classList.contains("hidden"))
    if (!block) return

    block.classList.remove("hidden")
    block.querySelector("[data-value-row].hidden")?.classList.remove("hidden")
    block.querySelector("input")?.focus()
    this.refreshAddOption()
  }

  refreshAddOption() {
    if (!this.hasAddOptionTarget) return

    const anyHidden = this.spareOptionTargets.some((block) => block.classList.contains("hidden"))
    this.addOptionTarget.classList.toggle("hidden", !anyHidden)
  }

  // Every spare row is in use: copy the last row under the next free index.
  cloneValueRow(block) {
    const rows = block.querySelectorAll("[data-value-row]")
    const last = rows[rows.length - 1]
    const copy = last.cloneNode(true)

    copy.querySelectorAll("input").forEach((input) => {
      input.name = input.name.replace(/\[values\]\[\d+\]/, `[values][${rows.length}]`)
      input.value = ""
    })
    last.after(copy)
    return copy
  }

  reveal(row) {
    row.classList.remove("hidden")
    row.querySelector("input")?.focus()
  }
}
```

- [ ] **Step 5: Write the variant filter**

Create `app/javascript/controllers/variant_filter_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// A filter box over a long admin variant table. The server renders the box
// hidden, only when there are more than thirty variants; without JavaScript the
// table is simply complete.
export default class extends Controller {
  static targets = ["query", "row"]

  connect() {
    if (this.hasQueryTarget) this.queryTarget.classList.remove("hidden")
  }

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()

    this.rowTargets.forEach((row) => {
      row.classList.toggle("hidden", query !== "" && !row.dataset.label.includes(query))
    })
  }
}
```

- [ ] **Step 6: Delete the retired controllers**

```bash
git rm app/javascript/controllers/color_switcher_controller.js app/javascript/controllers/variant_grid_controller.js
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/integration/stimulus_controllers_test.rb`
Expected: 1 run, 0 failures.

- [ ] **Step 8: Run the full suite and lint**

Full suite in the background, then `bin/rubocop && bin/brakeman --no-pager`.
Expected: 0 failures, 0 offenses, 0 warnings.

- [ ] **Step 9: Verify in a browser**

This step is for the human. Note in the report that it was skipped if no browser is available. Never claim it passed without having seen it.

```bash
bin/rails db:seed
bin/dev
```

`bin/dev` must run in a real terminal. Its Tailwind watcher exits without a TTY and takes the server down with it. This run is also what compiles the new utility classes.

Check at desktop width and at 390px:

- `/shop`: four cards. 3 Crow says "From $12.00" with three swatches. The sticker says "$4.00" with no swatches.
- `/shop/3-crow`: Colour and Size button groups, and the variant list hidden. Picking Black then 2XL shows $14.00 and In stock. Picking Heather Grey strikes through 2XL and 3XL.
- `/shop/see-that-shit`: 3XL is struck through in both colours.
- `/shop/third-eye-smiley`: Colour shows as a "Black" label and Size as buttons.
- `/shop/3-crow-sticker`: a price and "In stock", with no selectors.
- With JavaScript disabled, `/shop/3-crow` shows the full variant list and no buttons.
- `/admin/products`: four rows. The sticker reads "Simple item".
- `/admin/products/new`: spare rows hidden, "+ Add value" reveals one, "+ Add option" reveals a block. Copy options from 3 Crow prefills Colour and Size.
- Edit 3 Crow: remove Heather Grey, save, see the stock-loss panel, tick it, save, and confirm the variants went away.
- Edit a product with more than 30 variants: the filter box narrows the table.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add the option picker, option editor and variant filter

The product page swaps its variant list for one button group per
option, striking through values with nothing in stock given the other
selections and swapping in a value's photo. The admin form hides its
spare rows behind Add buttons, and long variant tables get a filter.
Every page still works without JavaScript.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Self-Review Notes

Checked against the spec:

- **Per-product options, zero to three, values with swatch and photo:** Task 1 (schema, models, caps), Task 2 (editor).
- **Every product has at least one variant; a simple variant has an empty key:** Task 1 (validation), Task 2 (`combinations` returns `[[]]`).
- **Price on the product, nullable override, `ProductVariant#price_cents`:** Task 1, applied in Task 3, shown in Tasks 6 and 7.
- **`options_key` and its unique index:** Task 1.
- **Delete variants before values, because the cascade orphans them:** pinned by a Task 1 model test and done in Task 2's `save` order.
- **Matching by name ignoring case; rename is delete plus add:** Task 2 (case), Task 3 (rename hits the loss check).
- **Stock-loss confirmation:** Task 3 (logic), Task 6 (panel).
- **Limits of 3 options and 100 variants:** Tasks 1 and 2, with the variant count checked before enumeration.
- **Copy options from another product:** Tasks 2 and 5.
- **Create redirects to edit, simple create to the list, update redirects to edit when variants changed:** Task 5.
- **Variant table with filter above 30 rows:** Tasks 6 and 8.
- **No-JS variant list plus picker, single-value label, image swap, simple product:** Tasks 7 and 8.
- **"From" pricing and swatch card:** Task 7.
- **Seeds with an override in use and a simple item, plus the deferred seed clean-ups:** Task 4.
- **Drop-and-recreate migration, irreversible down:** Task 1.
- **Risks (uploads next, stock not enforced, hard delete):** no code. They stay in the spec.

Where the plan is more specific than the spec:

1. **Value order.** The spec says reordering happens through "its position field". The plan defaults a blank position to the row's place in the form, so spare rows and new values need no number typed.
2. **A partial variant submission.** A variant field missing from the submission leaves that field alone, but a present-and-blank stock means 0. This lets the structural tests in Task 5 submit only some fields without wiping stock.
3. **Redisplayed errors.** `ProductEditor#errors` holds whole sentences, and the form renders them verbatim. This retires the September `"Price s"` humanize defect.

Things worth flagging to whoever executes this:

- **Sequel `refresh` clears cached associations.** Tests rely on `product.refresh` before reading `variants` or `options` after a save. Without it they read stale arrays and fail in ways that look like the write did not happen.
- **`ProductEditor#save` never raises for bad input**, but `Product.create`, `ProductOption.create` and the other model calls in model tests do (`Sequel::ValidationFailed`).
- **`existing_variants` and `existing_options` are snapshots taken before the transaction.** Do not re-query them inside it. The deletion and survivor logic depends on the "before" picture.
