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
