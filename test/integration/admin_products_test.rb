require "test_helper"

class AdminProductsTest < ActionDispatch::IntegrationTest
  teardown { Product.dataset.delete }

  def shirt(name: "Sample Tee", slug: "sample", stock: 3)
    build_product(name: name, slug: slug, stock: stock, options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S", "M" ] })
  end

  def new_product_params(overrides = {})
    {
      "product" => {
        "name" => "New Tee", "slug" => "new-tee", "description" => "Fresh.",
        "image" => "3crow.png", "price" => "12.00", "active" => "1"
      },
      "options" => {
        "0" => { "name" => "Colour", "values" => { "0" => { "name" => "Black" }, "1" => { "name" => "White" }, "2" => { "name" => "" } } },
        "1" => { "name" => "Size", "values" => { "0" => { "name" => "S" }, "1" => { "name" => "M" }, "2" => { "name" => "L" } } },
        "2" => { "name" => "", "values" => { "0" => { "name" => "" } } }
      }
    }.deep_merge(overrides)
  end

  def no_options
    { "options" => { "0" => { "name" => "", "values" => { "0" => { "name" => "" } } } } }
  end

  test "signed out visitors are redirected away from the product pages" do
    product = shirt

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "signed out visitors are redirected away from create, update and delete" do
    product = shirt

    post "/admin/products", params: new_product_params
    assert_response :redirect
    patch "/admin/products/#{product.id}", params: form_params_for(product).deep_merge("product" => { "name" => "Nope" })
    assert_response :redirect
    delete "/admin/products/#{product.id}"
    assert_response :redirect

    assert_equal 1, Product.count, "nothing should have been written"
    assert_equal "Sample Tee", Product[product.id].name
  end

  test "a non-superuser gets a 404 from every product route" do
    product = shirt
    sign_in create_account(superuser: false)

    [ "/admin/products", "/admin/products/new", "/admin/products/#{product.id}/edit" ].each do |path|
      get path
      assert_response :not_found, "expected #{path} to 404 for a non-superuser"
    end

    post "/admin/products", params: new_product_params
    assert_response :not_found
    patch "/admin/products/#{product.id}", params: form_params_for(product)
    assert_response :not_found
    delete "/admin/products/#{product.id}"
    assert_response :not_found

    assert_equal 1, Product.count
  end

  test "the list summarises options, variants and stock" do
    shirt(name: "Listed Tee")
    build_product(name: "Listed Sticker", options: {}, stock: 9)
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Options"
    assert_select "td", text: /Colour · Size/
    assert_select "td", text: "Simple item"
    assert_select "td", text: "4"
    assert_select "td", text: "12"
  end

  test "the list shows an empty state with no products" do
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "table", count: 0
  end

  test "the list still renders when a product's image no longer resolves" do
    product = shirt
    product.set(image: "no-longer-on-disk.png")
    product.save(validate: false)
    sign_in create_account(superuser: true)

    get "/admin/products"
    assert_response :success
    assert_select "body", text: /Sample Tee/
  end

  test "the new form offers three option blocks, value rows and a simple stock field" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    assert_response :success
    assert_select "input[name='product[price]'][value='12.00']"
    assert_select "fieldset[data-option-block]", 3
    assert_select "input[name='options[0][name]']"
    assert_select "input[name='options[0][values][0][name]']"
    assert_select "input[name='options[0][values][0][swatch_hex]']"
    assert_select "input[name='simple_stock']"
  end

  test "the new form can start from another product's options" do
    source = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/new", params: { copy_from: source.id }
    assert_response :success
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_select "input[name='options[0][values][1][name]'][value='Red']"
    assert_select "input[name='options[1][values][1][name]'][value='M']"
  end

  test "creating a product with options builds its variants and goes to edit for stock" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params
    product = Product.first(slug: "new-tee")
    assert product, "the product should exist"
    assert_redirected_to "/admin/products/#{product.id}/edit"

    assert_equal [ "Colour", "Size" ], product.options.map(&:name)
    assert_equal 6, product.variants.size
    assert_equal [ 0 ], product.variants.map(&:stock).uniq
    assert_equal 1200, product.price_cents
  end

  test "creating a simple product takes its stock and goes back to the list" do
    sign_in create_account(superuser: true)

    # merge, not deep_merge: the options must be replaced wholesale, not merged row by row.
    post "/admin/products", params: new_product_params.merge(no_options).merge("simple_stock" => "12")
    assert_redirected_to "/admin/products"

    product = Product.first(slug: "new-tee")
    assert product.simple?
    assert_equal 12, product.variants.first.stock
  end

  test "an invalid product re-renders and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "name" => "", "slug" => "" })
    assert_response :unprocessable_entity
    assert_select "li", text: "Name is not present."
    assert_equal 0, Product.count
  end

  test "a rejected malformed price is redisplayed as typed, not as 0.00" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "price" => "12.0.0" })
    assert_response :unprocessable_entity
    assert_select "input[name='product[price]'][value='12.0.0']"
    assert_select "li", text: "Price must be an amount like 12.00."
    assert_equal 0, Product.count
  end

  test "an option without values re-renders with the option kept" do
    sign_in create_account(superuser: true)

    params = new_product_params
    params["options"]["0"]["values"] = { "0" => { "name" => "" } }
    post "/admin/products", params: params

    assert_response :unprocessable_entity
    assert_select "li", text: "Colour needs at least one value."
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_equal 0, Product.count
  end

  test "a bogus image filename is rejected and writes nothing" do
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "image" => "nope.png" })
    assert_response :unprocessable_entity
    assert_select "body", text: /is not a file in app\/assets\/images/i
    assert_equal 0, Product.count
  end

  test "a duplicate slug re-renders rather than raising" do
    shirt(slug: "taken")
    sign_in create_account(superuser: true)

    post "/admin/products", params: new_product_params("product" => { "slug" => "taken" })
    assert_response :unprocessable_entity
    assert_select "li", text: "Slug is already taken."
  end

  # Propshaft serves only digested filenames in production, so the preview
  # must be handed asset_path URLs; a plain /assets/3crow.png would 404 there.
  test "the form carries digested asset urls for the image preview" do
    sign_in create_account(superuser: true)

    get "/admin/products/new"
    sources = JSON.parse(css_select("form[data-image-preview-sources-value]").first["data-image-preview-sources-value"])

    assert_match %r{\A/assets/3crow-[0-9a-f]+\.png\z}, sources["3crow.png"]
    refute sources.key?("no-such-image.png")
  end

  test "the edit form is prefilled with the product's options" do
    product = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/#{product.id}/edit"
    assert_response :success
    assert_select "input[name='product[name]'][value='Sample Tee']"
    assert_select "input[name='options[0][name]'][value='Colour']"
    assert_select "input[name='options[0][values][1][name]'][value='Red']"
    assert_select "input[name='options[0][values][1][position]'][value='2']"
  end

  test "renaming a product goes back to the list" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: form_params_for(product).deep_merge("product" => { "name" => "Renamed Tee" })
    assert_redirected_to "/admin/products"
    assert_equal "Renamed Tee", product.refresh.name
  end

  test "an unchanged save goes back to the list and changes nothing" do
    product = shirt
    before = product.variants.map { |v| [ v.id, v.stock ] }
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: form_params_for(product)
    assert_redirected_to "/admin/products"
    assert_equal before, product.refresh.variants.map { |v| [ v.id, v.stock ] }
  end

  test "adding a value comes back to edit so the new stock can be filled in" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: with_value(form_params_for(product), "Size", "L")
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal 6, product.refresh.variants.size
  end

  test "editing an unknown product is a 404" do
    sign_in create_account(superuser: true)

    get "/admin/products/999999/edit"
    assert_response :not_found
  end

  test "deleting a product takes its options and variants with it" do
    product = shirt
    sign_in create_account(superuser: true)

    delete "/admin/products/#{product.id}"
    assert_redirected_to "/admin/products"
    assert_nil Product[product.id]
    assert_equal 0, ProductVariant.where(product_id: product.id).count
    assert_equal 0, ProductOption.where(product_id: product.id).count
  end

  test "the edit form has a stock, price and SKU field for every variant" do
    product = shirt
    sign_in create_account(superuser: true)

    get "/admin/products/#{product.id}/edit"
    product.variants.each do |variant|
      assert_select "input[name='variants[#{variant.id}][stock]'][value='3'][aria-label='Stock for #{variant.label}']"
      assert_select "input[name='variants[#{variant.id}][price_override]'][placeholder='12.00']"
      assert_select "input[name='variants[#{variant.id}][sku]']"
    end
    assert_select "td", text: "Red / M"
  end

  test "updating one stock cell leaves the others alone" do
    product = shirt
    target = variant_named(product, "Red / S")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["stock"] = "11"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_redirected_to "/admin/products"

    product.refresh.variants.each do |variant|
      assert_equal(variant.id == target.id ? 11 : 3, variant.stock, variant.label)
    end
  end

  test "a price override is saved for one variant" do
    product = shirt
    target = variant_named(product, "Black / M")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["price_override"] = "14.00"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_equal 1400, target.refresh.price_override_cents
    assert_equal [ 1200, 1400 ], product.refresh.price_range
  end

  test "a malformed override re-renders as typed and writes nothing" do
    product = shirt
    target = variant_named(product, "Black / M")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["price_override"] = "lots"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_response :unprocessable_entity
    assert_select "li", text: "Price for Black / M must be an amount like 12.00, or blank to use the product price."
    assert_select "input[name='variants[#{target.id}][price_override]'][value='lots']"
    assert_nil target.refresh.price_override_cents
  end

  test "a SKU used by another product re-renders rather than raising" do
    other = shirt(name: "Other Tee", slug: "other")
    variant_named(other, "Black / S").update(sku: "TAKEN")
    product = shirt
    target = variant_named(product, "Black / S")
    params = form_params_for(product)
    params["variants"][target.id.to_s]["sku"] = "TAKEN"
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: params
    assert_response :unprocessable_entity
    assert_select "li", text: "Black / S: Sku is already taken."
  end

  test "removing a value with stock asks for confirmation and deletes nothing" do
    product = shirt
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: without_value(form_params_for(product), "Colour", "Red")
    assert_response :unprocessable_entity
    assert_select "[data-pending-loss] li", text: /Red \/ S — 3 in stock/
    assert_select "[data-pending-loss] li", text: /Red \/ M — 3 in stock/
    assert_select "input[type='checkbox'][name='confirm_loss']"
    product.variants.select { |variant| variant.label.start_with?("Red") }.each do |variant|
      assert_select "input[type='hidden'][name='confirmed_loss[]'][value='#{variant.id}']"
    end
    assert_equal 4, product.refresh.variants.size
  end

  test "confirming the loss deletes the variants" do
    product = shirt
    sign_in create_account(superuser: true)

    red_ids = product.variants.select { |variant| variant.label.start_with?("Red") }.map { |variant| variant.id.to_s }
    params = without_value(form_params_for(product), "Colour", "Red").merge("confirm_loss" => "1", "confirmed_loss" => red_ids)
    patch "/admin/products/#{product.id}", params: params
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal [ "Black / S", "Black / M" ], product.refresh.variants.map(&:label)
  end

  test "removing a value with no stock needs no confirmation" do
    product = shirt(stock: 0)
    sign_in create_account(superuser: true)

    patch "/admin/products/#{product.id}", params: without_value(form_params_for(product), "Colour", "Red")
    assert_redirected_to "/admin/products/#{product.id}/edit"
    assert_equal 2, product.refresh.variants.size
  end

  test "a filter box appears only when there are more than thirty variants" do
    small = shirt
    big = build_product(name: "Big Tee", options: { "Colour" => %w[A B C D E F], "Size" => %w[S M L XL 2XL 3XL] })
    sign_in create_account(superuser: true)

    get "/admin/products/#{small.id}/edit"
    assert_select "input[data-variant-filter-target='query']", count: 0

    get "/admin/products/#{big.id}/edit"
    assert_select "input[data-variant-filter-target='query']", count: 1
    assert_select "tr[data-variant-filter-target='row']", 36
  end

  test "a simple product's edit form has one variant row and no label column" do
    sticker = build_product(name: "Sticker", options: {}, stock: 8)
    sign_in create_account(superuser: true)

    get "/admin/products/#{sticker.id}/edit"
    assert_select "input[name='variants[#{sticker.variants.first.id}][stock]'][value='8']"
    assert_select "th", text: "Variant", count: 0
  end

  test "the edit page loads every variant's values in one query, not one per variant" do
    product = shirt
    sign_in create_account(superuser: true)

    log = StringIO.new
    logger = Logger.new(log)
    Product.db.loggers << logger
    begin
      get "/admin/products/#{product.id}/edit"
    ensure
      Product.db.loggers.delete(logger)
    end

    assert_response :success
    lookups = log.string.lines.count { |line| line.include?("variant_option_values") }
    assert_operator lookups, :<=, 1, "expected one eager query for the variants' values, got #{lookups}"
  end
end
