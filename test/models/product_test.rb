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
