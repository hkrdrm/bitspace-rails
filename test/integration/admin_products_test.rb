require "test_helper"

class AdminProductsTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def create_product(slug: "sample", name: "Sample Tee")
    product = Product.create(
      name: name, slug: slug, description: "A shirt.", image: "3crow.png",
      base_price_cents: 1200, active: true
    )
    Product::SIZES.each_with_index do |size, index|
      ProductVariant.create(
        product_id: product.id, size: size, color: "Black",
        price_cents: 1200, stock: 3, position: index
      )
    end
    product
  end

  test "signed out visitors are redirected away from the product pages" do
    product = create_product

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "signed out visitors are redirected away from create, update and delete" do
    product = create_product

    post "/admin/products", params: valid_params
    assert_response :redirect

    patch "/admin/products/#{product.id}", params: { product: { name: "Nope" } }
    assert_response :redirect

    delete "/admin/products/#{product.id}"
    assert_response :redirect

    assert_equal 1, Product.count, "nothing should have been written"
    assert_equal "Sample Tee", Product[product.id].name, "the product should be untouched"
  end

  test "a non-superuser gets a 404 from the product pages" do
    product = create_product
    sign_in create_account(superuser: false)

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :not_found, "expected #{path} to 404 for a non-superuser"
    end
  end

  test "a non-superuser cannot create, update or delete" do
    product = create_product
    sign_in create_account(superuser: false)

    post "/admin/products", params: { product: { name: "Nope" } }
    assert_response :not_found

    patch "/admin/products/#{product.id}", params: { product: { name: "Nope" } }
    assert_response :not_found

    delete "/admin/products/#{product.id}"
    assert_response :not_found

    assert_equal 1, Product.count, "nothing should have been written"
  end

  test "a superuser sees the product list" do
    create_product(name: "Listed Tee")
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Product"
    assert_select "body", text: /Listed Tee/
  end

  test "the list shows an empty state with no products" do
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "table", count: 0
  end

  def valid_params(overrides = {})
    {
      product: {
        name: "New Tee", slug: "new-tee", description: "Fresh.",
        image: "3crow.png", base_price: "12.00", active: "1"
      },
      colors: [ "Black", "White" ],
      prices: { "S" => "12.00", "M" => "12.00", "L" => "12.00",
                "XL" => "12.00", "2XL" => "14.00", "3XL" => "14.00" },
      stock: {
        "Black" => { "S" => "5", "M" => "6", "L" => "7", "XL" => "0", "2XL" => "1", "3XL" => "0" },
        "White" => { "S" => "2", "M" => "3", "L" => "4", "XL" => "0", "2XL" => "0", "3XL" => "0" }
      }
    }.deep_merge(overrides)
  end

  test "the new form renders for a superuser" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    assert_response :success
    assert_select "form"
    assert_select "input[name='colors[]']", count: Product::COLORS.size
    assert_select "input[name='prices[S]']"
    assert_select "input[name='stock[Black][S]']"
  end

  test "creating a product builds the whole variant grid" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params
    assert_redirected_to "/admin/products"

    product = Product.first(slug: "new-tee")
    assert product, "the product should exist"
    assert_equal 12, product.variants.count, "two colours by six sizes"
    assert_equal [ "Black", "White" ], product.colors
    assert_equal 1200, product.base_price_cents
  end

  test "prices are applied to every colour of a size" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal 1400, product.variants.find { |v| v.size == "2XL" && v.color == "Black" }.price_cents
    assert_equal 1400, product.variants.find { |v| v.size == "2XL" && v.color == "White" }.price_cents
    assert_equal 1200, product.variants.find { |v| v.size == "S" && v.color == "White" }.price_cents
  end

  test "stock is stored per cell" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal 5, product.stock_for(size: "S", color: "Black")
    assert_equal 2, product.stock_for(size: "S", color: "White")
    assert_equal 0, product.stock_for(size: "XL", color: "Black")
  end

  test "sizes are stored in ladder order" do
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params

    product = Product.first(slug: "new-tee")
    assert_equal Product::SIZES, product.variants_for("Black").map(&:size)
  end

  test "creating without a colour re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(colors: [])
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_select "body", text: /at least one colour/i
  end

  test "an invalid product re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { name: "" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count, "no variants should be left behind"
  end

  test "a bogus image filename is rejected and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { image: "3crow.pgn" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count
    assert_select "body", text: /is not a file in app\/assets\/images/i
  end

  test "the product list still renders when a product's image no longer resolves" do
    product = create_product
    product.set(image: "no-longer-on-disk.png")
    product.save(validate: false)
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "body", text: /Sample Tee/
  end

  test "a duplicate slug re-renders rather than raising" do
    create_product(slug: "taken")
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { slug: "taken" })
    assert_response :unprocessable_entity
    assert_equal 1, Product.count
  end

  test "the slug is derived from the name when left blank" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { name: "Big Loud Shirt", slug: "" })
    assert_redirected_to "/admin/products"
    assert Product.first(slug: "big-loud-shirt"), "expected a slug generated from the name"
  end

  test "a non-numeric size price is rejected and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(prices: { "S" => "abc" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count
  end

  test "a rejected malformed price is redisplayed as typed, not as 0.00" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(prices: { "S" => "abc" })
    assert_response :unprocessable_entity

    assert_select "input[name='prices[S]'][value=?]", "abc"
    assert_select "input[name='prices[S]'][value=?]", "0.00", count: 0
    assert_select "body", text: /size S must be an amount/i
  end

  test "a rejected malformed base price is redisplayed as typed, not as 0.00" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { base_price: "abc" })
    assert_response :unprocessable_entity

    assert_select "input[name='product[base_price]'][value=?]", "abc"
    assert_select "input[name='product[base_price]'][value=?]", "0.00", count: 0
  end

  test "a negative price is rejected rather than silently flipped" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(prices: { "S" => "-12.50" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_nil ProductVariant.first(price_cents: 1250), "a negative price must never be saved as 1250"
  end

  test "a non-numeric base price is rejected and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { base_price: "abc" })
    assert_response :unprocessable_entity
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count
  end

  test "dollar signs and thousands commas are still accepted" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: valid_params(product: { base_price: "$12.00" }, prices: { "2XL" => "1,200.00" })
    assert_redirected_to "/admin/products"

    product = Product.first(slug: "new-tee")
    assert product, "the product should exist"
    assert_equal 1200, product.base_price_cents
    assert_equal 120_000, product.variants.find { |v| v.size == "2XL" && v.color == "Black" }.price_cents
  end

  def create_two_color_product
    sign_in create_account(superuser: true)
    post "/admin/products", params: valid_params
    Product.first(slug: "new-tee")
  end

  test "the edit form is prefilled from the product" do
    product = create_two_color_product

    get "/admin/products/#{product.id}/edit"
    assert_response :success
    assert_select "input[name='product[name]'][value=?]", "New Tee"
    assert_select "input[name='colors[]'][value='Black'][checked]"
    assert_select "input[name='colors[]'][value='White'][checked]"
    assert_select "input[name='colors[]'][value='Red'][checked]", count: 0
    assert_select "input[name='stock[Black][S]'][value=?]", "5"
  end

  test "updating a price applies it to every colour of that size" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(prices: { "S" => "19.50" })
    assert_redirected_to "/admin/products"

    product.refresh
    assert_equal 1950, product.variants.find { |v| v.size == "S" && v.color == "Black" }.price_cents
    assert_equal 1950, product.variants.find { |v| v.size == "S" && v.color == "White" }.price_cents
  end

  test "updating one stock cell leaves the others alone" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(stock: { "Black" => { "M" => "99" } })

    product.refresh
    assert_equal 99, product.stock_for(size: "M", color: "Black")
    assert_equal 5,  product.stock_for(size: "S", color: "Black")
    assert_equal 3,  product.stock_for(size: "M", color: "White")
  end

  test "adding a colour creates its six sizes at zero stock" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}",
          params: valid_params(colors: [ "Black", "White", "Red" ])

    product.refresh
    assert_equal 18, product.variants.count
    assert_equal [ "Black", "White", "Red" ], product.colors
    assert_equal 0, product.stock_for(size: "S", color: "Red")
  end

  test "removing a colour deletes its rows" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(colors: [ "Black" ])

    product.refresh
    assert_equal 6, product.variants.count
    assert_equal [ "Black" ], product.colors
    assert_equal 0, ProductVariant.where(product_id: product.id, color: "White").count
  end

  test "updating to an invalid product writes nothing" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(product: { name: "" })
    assert_response :unprocessable_entity

    product.refresh
    assert_equal "New Tee", product.name
    assert_equal 12, product.variants.count
  end

  test "updating with no colours selected writes nothing" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(colors: [])
    assert_response :unprocessable_entity

    product.refresh
    assert_equal 12, product.variants.count, "the grid should be untouched"
  end

  test "updating with a malformed price is rejected and writes nothing" do
    product = create_two_color_product

    patch "/admin/products/#{product.id}", params: valid_params(prices: { "S" => "abc" })
    assert_response :unprocessable_entity

    product.refresh
    assert_equal 12, product.variants.count
    assert_equal 1200, product.variants.find { |v| v.size == "S" && v.color == "Black" }.price_cents
  end

  test "deleting a product takes its variants with it" do
    product = create_two_color_product

    delete "/admin/products/#{product.id}"
    assert_redirected_to "/admin/products"

    assert_nil Product[product.id]
    assert_equal 0, ProductVariant.where(product_id: product.id).count
  end

  test "editing an unknown product is a 404" do
    sign_in create_account(superuser: true)

    get "/admin/products/999999/edit"
    assert_response :not_found
  end
end
