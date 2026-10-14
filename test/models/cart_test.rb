require "test_helper"

class CartTest < ActiveSupport::TestCase
  teardown { Product.dataset.delete }

  setup do
    @session = {}
    @cart = Cart.new(@session)
    @tee = build_product(name: "Cart Tee", price: "20.00", options: { "Size" => %w[S M] }, stock: 3)
    @small = variant_named(@tee, "S")
    @sticker = build_product(name: "Sticker", price: "4.00")
  end

  test "adding puts the variant in the session and counts it" do
    result = @cart.add(@small.id, 2)

    assert result.ok
    assert_equal "Added to your cart.", result.message
    assert_equal({ @small.id.to_s => 2 }, @session[:cart])
    assert_equal 2, @cart.count
  end

  test "adding more than the stock caps the quantity and says so" do
    @cart.add(@small.id, 2)
    result = @cart.add(@small.id, 5)

    assert result.ok
    assert_equal "Only 3 of Cart Tee — S available, so your cart has 3.", result.message
    assert_equal 3, @cart.count
  end

  test "unknown, unpublished and sold out variants are refused" do
    refute @cart.add(999_999_999, 1).ok
    refute @cart.add("abc", 1).ok

    @small.this.update(stock: 0)
    sold_out = @cart.add(@small.id, 1)
    refute sold_out.ok
    assert_equal "Cart Tee — S is sold out.", sold_out.message

    @sticker.update(active: false)
    refute @cart.add(@sticker.variants.first.id, 1).ok
    assert @cart.empty?
  end

  test "a quantity that is not a positive whole number is refused" do
    [ 0, -1, "1.5", "two", nil ].each do |quantity|
      refute @cart.add(@small.id, quantity).ok, "expected #{quantity.inspect} to be refused"
    end
    assert @cart.empty?
  end

  test "update changes the quantity, caps it at stock, and zero removes the line" do
    @cart.add(@small.id, 1)

    assert @cart.update(@small.id, 2).ok
    assert_equal 2, @cart.count

    capped = @cart.update(@small.id, 10)
    assert_equal 3, @cart.count
    assert_match(/Only 3/, capped.message)

    @cart.update(@small.id, 0)
    assert @cart.empty?
  end

  test "update refuses junk and items that are not in the cart" do
    refute @cart.update(@small.id, 1).ok
    @cart.add(@small.id, 1)
    refute @cart.update(@small.id, "lots").ok
    assert_equal 1, @cart.count
  end

  test "remove takes the line out" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)
    @cart.remove(@small.id)

    assert_equal [ @sticker.variants.first.id ], @cart.lines.map { |line| line.variant.id }
  end

  test "junk in the session is dropped instead of raising" do
    @session[:cart] = { "abc" => 1, @small.id.to_s => "2", "0" => 1, @sticker.variants.first.id.to_s => -4, "7" => nil }
    assert_equal 2, @cart.count
    assert_equal [ @small.id ], @cart.lines.map { |line| line.variant.id }

    @session[:cart] = "not a hash"
    assert_equal 0, @cart.count
    assert_equal [], @cart.lines
  end

  test "lines drop variants that were deleted" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)
    Product.where(id: @tee.id).delete

    assert_equal [ "Sticker" ], @cart.lines.map(&:name)
    assert_equal({ @sticker.variants.first.id.to_s => 1 }, @session[:cart])
  end

  test "a line that sold out or was unpublished stays, but is unavailable and not in the subtotal" do
    @cart.add(@small.id, 2)
    @cart.add(@sticker.variants.first.id, 1)
    @small.this.update(stock: 0)

    lines = @cart.lines
    refute lines.find { |line| line.variant.id == @small.id }.available?
    assert_equal 400, @cart.subtotal_cents
    assert_equal [ "Sticker" ], @cart.available_lines.map(&:name)
  end

  test "line names include the variant label except for simple products" do
    @cart.add(@small.id, 1)
    @cart.add(@sticker.variants.first.id, 1)

    assert_equal [ "Cart Tee — S", "Sticker" ], @cart.lines.map(&:name)
  end

  test "reconcile caps lines to the stock left and explains" do
    @cart.add(@small.id, 3)
    @small.this.update(stock: 1)

    messages = @cart.reconcile(@cart.lines)
    assert_equal [ "Only 1 of Cart Tee — S left, so your cart now has 1." ], messages
    assert_equal 1, @cart.count
  end

  test "clear empties the cart" do
    @cart.add(@small.id, 1)
    @cart.clear
    assert @cart.empty?
  end
end
