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
