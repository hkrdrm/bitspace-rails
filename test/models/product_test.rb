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
end
