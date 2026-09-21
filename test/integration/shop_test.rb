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
end
