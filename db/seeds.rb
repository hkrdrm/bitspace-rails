# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

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
