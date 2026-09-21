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
end
