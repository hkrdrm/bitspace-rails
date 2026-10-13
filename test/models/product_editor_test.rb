require "test_helper"

class ProductEditorTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  def product_fields(**overrides)
    {
      "name" => "Editor Tee", "slug" => "editor-tee", "description" => "A shirt.",
      "image" => "3crow.png", "price" => "12.00", "active" => "1"
    }.merge(overrides.stringify_keys)
  end

  def option(name, *values)
    { "name" => name, "values" => values.map { |value| value.is_a?(Hash) ? value.stringify_keys : { "name" => value } } }
  end

  def create(options: [], **fields)
    ProductEditor.new(Product.new, { "product" => product_fields(**fields), "options" => options })
  end

  test "a product with no options gets one simple variant" do
    editor = create
    assert editor.save, editor.errors.join(" ")

    product = editor.product
    assert product.simple?
    assert_equal 1, product.variants.size
    assert_equal "", product.variants.first.options_key
    assert_equal "Editor Tee", product.variants.first.label
    assert_equal 1200, product.variants.first.price_cents
  end

  test "options multiply into one variant per combination, in option then value order" do
    editor = create(options: [ option("Colour", "Black", "White"), option("Size", "S", "M", "L") ])
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Black / S", "Black / M", "Black / L", "White / S", "White / M", "White / L" ],
      editor.product.variants.map(&:label)
    assert_equal 6, editor.created_count
    assert editor.variants_changed?
  end

  test "blank padding rows from the form are ignored" do
    editor = ProductEditor.new(Product.new, {
      "product" => product_fields,
      "options" => {
        "0" => { "name" => "Size", "values" => { "0" => { "name" => "S" }, "1" => { "name" => "" }, "2" => { "name" => "  " } } },
        "1" => { "name" => "", "values" => { "0" => { "name" => "" } } }
      }
    })
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Size" ], editor.product.options.map(&:name)
    assert_equal [ "S" ], editor.product.variants.map(&:label)
  end

  test "index-keyed rows are ordered numerically, not as strings" do
    values = (0..10).to_h { |i| [ i.to_s, { "name" => "V#{i}" } ] }
    editor = ProductEditor.new(Product.new, { "product" => product_fields, "options" => { "0" => { "name" => "Pick", "values" => values } } })
    assert editor.save, editor.errors.join(" ")

    assert_equal (0..10).map { |i| "V#{i}" }, editor.product.options.first.option_values.map(&:name)
  end

  test "a value's position field reorders it" do
    editor = create(options: [ option("Size", { name: "L", position: "2" }, { name: "S", position: "1" }) ])
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "S", "L" ], editor.product.options.first.option_values.map(&:name)
  end

  test "the slug is derived from the name when left blank" do
    editor = create(slug: "", name: "Fresh Print")
    assert editor.save, editor.errors.join(" ")
    assert_equal "fresh-print", editor.product.slug
  end

  test "dollar signs and thousands commas are accepted in the price" do
    editor = create(price: "$1,200.50")
    assert editor.save, editor.errors.join(" ")
    assert_equal 120050, editor.product.price_cents
  end

  test "a malformed price is an error, never zero, and writes nothing" do
    editor = create(price: "12.0.0")
    refute editor.save

    assert_includes editor.errors, "Price must be an amount like 12.00."
    assert_equal "12.0.0", editor.price_input, "the form must redisplay what was typed"
    assert_equal 0, Product.count
  end

  test "product validation errors are reported as sentences" do
    build_product(slug: "taken")
    editor = create(slug: "taken")

    refute editor.save
    assert_includes editor.errors, "Slug is already taken."
  end

  test "an option with no values is an error" do
    editor = create(options: [ option("Size") ])
    refute editor.save
    assert_includes editor.errors, "Size needs at least one value."
    assert_equal 0, Product.count
  end

  test "values without an option name are an error" do
    editor = create(options: [ option("", "S") ])
    refute editor.save
    assert_includes editor.errors, "Option 1 needs a name."
  end

  test "two options with the same name, ignoring case, are an error" do
    editor = create(options: [ option("Size", "S"), option("size", "M") ])
    refute editor.save
    assert_includes editor.errors, "There are two options called size."
  end

  test "a value listed twice in one option, ignoring case, is an error" do
    editor = create(options: [ option("Colour", "Black", "black") ])
    refute editor.save
    assert_includes editor.errors, "Colour lists Black more than once."
  end

  test "more than three options is an error" do
    editor = create(options: [ option("A", "1"), option("B", "1"), option("C", "1"), option("D", "1") ])
    refute editor.save
    assert_includes editor.errors, "A product can have at most 3 options."
  end

  test "more than one hundred variants is an error and writes nothing" do
    editor = create(options: [ option("A", *("a".."k").to_a), option("B", *("a".."j").to_a) ])
    refute editor.save

    assert_includes editor.errors, "Those options make 110 variants; the limit is 100."
    assert_equal 0, Product.count
  end

  test "a bad swatch is reported against its value and rolls the whole save back" do
    editor = create(options: [ option("Colour", { name: "Black", swatch_hex: "black" }) ])
    refute editor.save

    assert_includes editor.errors, "Black: Swatch hex must be a colour like #1b2a41."
    assert_equal 0, Product.count
    assert_equal 0, ProductOption.count
    assert editor.product.new?, "the re-rendered form must still post to create"
  end

  test "swatch and photo fields are saved on the value" do
    editor = create(options: [
      option("Colour", { name: "Tie-Dye", swatch_image: "3crow.png", image: "3crow.png" }, { name: "Black", swatch_hex: "#0d1114" })
    ])
    assert editor.save, editor.errors.join(" ")

    tie_dye, black = editor.product.options.first.option_values
    assert_equal [ "3crow.png", "3crow.png" ], [ tie_dye.swatch_image, tie_dye.image ]
    assert_equal "#0d1114", black.swatch_hex
  end

  test "adding a value creates only the new combinations, at zero stock" do
    product = build_product(options: { "Colour" => [ "Black" ], "Size" => [ "S", "M" ] }, stock: 7)
    old_ids = product.variants.map(&:id)

    editor = ProductEditor.new(product, with_value(form_params_for(product), "Colour", "Red"))
    assert editor.save, editor.errors.join(" ")

    product.refresh
    assert_equal [ "Black / S", "Black / M", "Red / S", "Red / M" ], product.variants.map(&:label)
    assert_equal 2, editor.created_count
    assert editor.variants_changed?
    assert_equal [ 7, 7 ], product.variants.select { |v| old_ids.include?(v.id) }.map(&:stock)
    assert_equal [ 0, 0 ], product.variants.reject { |v| old_ids.include?(v.id) }.map(&:stock)
  end

  test "removing a value with no stock deletes its variants" do
    product = build_product(options: { "Colour" => [ "Black", "Red" ], "Size" => [ "S" ] }, stock: 0)

    editor = ProductEditor.new(product, without_value(form_params_for(product), "Colour", "Red"))
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "Black / S" ], product.refresh.variants.map(&:label)
    assert_equal [ "Black" ], product.options.first.option_values.map(&:name)
    assert_equal 2, Product.db[:variant_option_values].count, "one variant, linked to Black and to S"
  end

  test "names are trimmed, and values are matched to existing rows ignoring case" do
    product = build_product(options: { "Colour" => [ "Black" ] })
    variant_id = product.variants.first.id
    params = form_params_for(product)
    params["options"]["0"]["values"]["0"]["name"] = "  BLACK  "

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")

    assert_equal [ "BLACK" ], product.refresh.options.first.option_values.map(&:name)
    assert_equal [ variant_id ], product.variants.map(&:id), "a change of case must not replace the variant"
    refute editor.variants_changed?
  end

  test "reordering options keeps the variants and relabels them" do
    product = build_product(options: { "Colour" => [ "Black" ], "Size" => [ "S" ] })
    ids = product.variants.map(&:id)
    params = form_params_for(product)
    params["options"] = { "0" => params["options"]["1"], "1" => params["options"]["0"] }

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")

    assert_equal ids, product.refresh.variants.map(&:id)
    assert_equal [ "S / Black" ], product.variants.map(&:label)
    refute editor.variants_changed?
  end

  test "replacing an option on a product already at the limit works" do
    product = build_product(options: { "A" => [ "1" ], "B" => [ "1" ], "C" => [ "1" ] }, stock: 0)
    params = form_params_for(product)
    params["options"]["2"]["name"] = "D"

    editor = ProductEditor.new(product, params)
    assert editor.save, editor.errors.join(" ")
    assert_equal [ "A", "B", "D" ], product.refresh.options.map(&:name)
  end

  test "saving the edit form unchanged changes nothing" do
    product = build_product(options: { "Colour" => [ { name: "Black", swatch_hex: "#0d1114" } ], "Size" => [ "S", "M" ] }, stock: 3)
    before = product.variants.map { |v| [ v.id, v.options_key, v.stock, v.position ] }

    editor = ProductEditor.new(product, form_params_for(product))
    assert editor.save, editor.errors.join(" ")

    refute editor.variants_changed?
    assert_equal before, product.refresh.variants.map { |v| [ v.id, v.options_key, v.stock, v.position ] }
    assert_equal "#0d1114", product.options.first.option_values.first.swatch_hex
  end

  test "blank copies another product's options onto a new product" do
    source = build_product(options: { "Size" => [ "S", "M" ] })
    editor = ProductEditor.blank(copy_from: source)

    assert editor.product.new?
    assert_equal [ "Size" ], editor.option_inputs.map { |option| option[:name] }
    assert_equal [ "S", "M" ], editor.option_inputs.first[:values].map { |value| value[:name] }
  end
end
