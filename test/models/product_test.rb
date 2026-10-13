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
