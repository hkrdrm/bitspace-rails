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
    refute_selector_text "body", /Hidden Tee/
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
    refute_selector_text "body", /1 colour\b/
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
    refute_selector_text "b", "Bold"
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

  test "the picker is described to assistive technology" do
    shirt(slug: "described", colours: [ "Black", "Red" ])

    get "/shop/described"
    groups = css_select("[role='group'][aria-labelledby]")
    assert_equal 2, groups.size, "one labelled group per option with several values"
    groups.each { |group| assert_select "##{group['aria-labelledby']}", 1 }
    assert_select "[aria-live='polite'] [data-variant-picker-target='status']"
    assert_select "button[data-variant-picker-target='button'] .sr-only[data-availability]", 5
  end

  test "a product with no stock at all gets a sold out overlay on its card and page" do
    shirt(slug: "gone", name: "Gone Tee", stock: 0)
    shirt(slug: "around", name: "Around Tee")

    get "/shop"
    assert_select "a[href='/shop/gone'] [data-sold-out-overlay]", text: "Sold out"
    assert_select "a[href='/shop/around'] [data-sold-out-overlay]", count: 0

    get "/shop/gone"
    assert_select "[data-sold-out-overlay]", text: "Sold out"
  end

  test "a product with only some sizes sold out gets no overlay" do
    product = shirt(slug: "partly")
    variant_named(product, "Black / M").update(stock: 0)

    get "/shop/partly"
    assert_select "[data-sold-out-overlay]", count: 0
  end

  test "a sold out simple product gets the overlay too" do
    build_product(name: "Gone Sticker", slug: "gone-sticker", price: "4.00", stock: 0)

    get "/shop/gone-sticker"
    assert_select "[data-sold-out-overlay]", text: "Sold out"
  end
end
