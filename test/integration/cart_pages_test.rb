require "test_helper"

class CartPagesTest < ActionDispatch::IntegrationTest
  teardown do
    Product.dataset.delete
    StoreSetting.dataset.delete
  end

  setup do
    @tee = build_product(name: "Cart Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    @sticker = build_product(name: "Cart Sticker", price: "4.00")
  end

  def add(variant, quantity = 1, headers: {})
    post "/cart/items", params: { variant_id: variant.id, quantity: quantity }, headers: headers
  end

  test "an empty cart says so and offers no checkout" do
    get "/cart"
    assert_response :success
    assert_select "body", text: /Your cart is empty/
    assert_select "form[action='/checkout']", count: 0
  end

  test "adding an item goes to the cart, which lists it with the subtotal" do
    add(@small, 2)
    assert_redirected_to "/cart"
    follow_redirect!

    assert_select "[data-flash=notice]", text: "Added to your cart."
    assert_select "[data-cart-line='#{@small.id}']", text: /Cart Tee — S/
    assert_select "[data-subtotal]", text: "$40.00"
  end

  test "a simple product's line is just its name" do
    add(@sticker.variants.first)
    follow_redirect!

    assert_select "[data-cart-line] p.font-bold", text: "Cart Sticker"
  end

  test "the nav shows how many items are in the cart" do
    add(@small, 2)
    add(@sticker.variants.first)

    get "/"
    assert_select "nav a[href='/cart']", text: "Cart (3)"
  end

  test "adding a sold out item goes back to the product with a message" do
    @small.this.update(stock: 0)
    referer = "http://www.example.com/shop/#{@tee.slug}"

    add(@small, 1, headers: { "HTTP_REFERER" => referer })
    assert_redirected_to referer
    follow_redirect!
    assert_select "[data-flash=alert]", text: "Cart Tee — S is sold out."
  end

  test "updating a quantity changes the subtotal and zero empties the cart" do
    add(@small)

    patch "/cart/items/#{@small.id}", params: { quantity: 3 }
    follow_redirect!
    assert_select "[data-subtotal]", text: "$60.00"

    patch "/cart/items/#{@small.id}", params: { quantity: 0 }
    follow_redirect!
    assert_select "body", text: /Your cart is empty/
  end

  test "remove takes a line out" do
    add(@small)
    add(@sticker.variants.first)

    delete "/cart/items/#{@small.id}"
    follow_redirect!
    assert_select "[data-cart-line]", count: 1
    assert_select "[data-cart-line='#{@sticker.variants.first.id}']"
  end

  test "a line that sold out after it was added stays with a note and leaves the subtotal" do
    add(@small)
    add(@sticker.variants.first)
    @small.this.update(stock: 0)

    get "/cart"
    assert_select "[data-cart-line='#{@small.id}'][data-unavailable]", text: /No longer available/
    assert_select "[data-subtotal]", text: "$4.00"
  end

  test "delivery offers pickup with instructions and the flat shipping rate" do
    StoreSetting.current.update(shipping_cents: 650, pickup_instructions: "Come by the shop on Main.")
    add(@small)

    get "/cart"
    assert_select "form[action='/checkout'][data-turbo='false']" do
      assert_select "input[type=radio][name=fulfillment][value=pickup]"
      assert_select "input[type=radio][name=fulfillment][value=shipping]"
    end
    assert_select "body", text: /Come by the shop on Main\./
    assert_select "body", text: /Ship it — \$6\.50 flat/
  end

  test "the tax note appears only while tax is on" do
    add(@small)

    get "/cart"
    assert_select "[data-tax-note]", count: 0

    StoreSetting.current.update(tax_enabled: true, tax_rate_bps: 700, stripe_tax_rate_id: "txr_1", stripe_tax_rate_bps: 700)
    get "/cart"
    assert_select "[data-tax-note]", text: "Mississippi sales tax is added at checkout for MS addresses and pickups."
  end

  test "a simple product page has an add to cart form for its one variant" do
    get "/shop/#{@sticker.slug}"

    assert_select "form[action='/cart/items']" do
      assert_select "input[type=hidden][name=variant_id][value='#{@sticker.variants.first.id}']"
      assert_select "button", text: "Add to cart"
    end
    refute_selector_text "p", /Ordering online is not open yet/
  end

  test "a product page with options offers only the variants in stock" do
    variant_named(@tee, "M").this.update(stock: 0)

    get "/shop/#{@tee.slug}"
    values = css_select("form[action='/cart/items'] select[name=variant_id] option").map { |option| option["value"] }
    assert_equal [ "", @small.id.to_s ], values
  end

  test "a sold out product has no add to cart form" do
    @sticker.variants.first.this.update(stock: 0)

    get "/shop/#{@sticker.slug}"
    assert_select "form[action='/cart/items']", count: 0
  end
end
