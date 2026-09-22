# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# Sample products for the shop. Idempotent on slug, so running this repeatedly
# leaves the data unchanged.

[].tap do
  seed_products = [
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
  ]

  # $12 through XL, $14 for the big sizes, matching the homepage.
  seed_price_for = ->(size) { %w[2XL 3XL].include?(size) ? 1400 : 1200 }

  seed_products.each do |attributes|
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
          price_cents: seed_price_for.call(size),
          stock: attributes.dig(:stock, color, size).to_i,
          position: index
        )
        variant.save
      end
    end
  end
end

puts "Seeded #{Product.count} products, #{ProductVariant.count} variants."
