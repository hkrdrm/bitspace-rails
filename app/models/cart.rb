# The visitor's cart, kept in the Rails session as { "variant id" => quantity }
# so guests and signed-in customers work the same way and nothing is written
# to the database until checkout. Entries that are not a positive whole
# quantity of a numeric id, and variants that no longer exist, are dropped
# when the cart is read.
class Cart
  MAX_QUANTITY = 99
  ID = /\A[1-9]\d{0,17}\z/

  Line = Data.define(:variant, :quantity) do
    def product
      variant.product
    end

    # Sold out or unpublished since it was added: still listed, never bought.
    def available?
      product.active? && variant.stock.positive?
    end

    def name
      product.simple? ? product.name : "#{product.name} — #{variant.label}"
    end

    def unit_price_cents
      variant.price_cents
    end

    def total_cents
      unit_price_cents * quantity
    end
  end

  Result = Data.define(:ok, :message)

  def initialize(session)
    @session = session
  end

  def count
    entries.values.sum
  end

  def empty?
    entries.empty?
  end

  def lines
    current = entries
    variants = load_variants(current.keys).index_by { |variant| variant.id.to_s }
    kept = current.select { |id, _| variants.key?(id) }
    write(kept)
    kept.map { |id, quantity| Line.new(variant: variants.fetch(id), quantity: quantity) }
  end

  def available_lines
    lines.select(&:available?)
  end

  def subtotal_cents(lines = available_lines)
    lines.select(&:available?).sum(&:total_cents)
  end

  def add(variant_id, quantity)
    variant = load_variants([ variant_id ]).first
    return Result.new(ok: false, message: "That item is no longer available.") unless variant&.product&.active?
    return Result.new(ok: false, message: "#{describe(variant)} is sold out.") if variant.sold_out?

    wanted = whole(quantity)
    return Result.new(ok: false, message: "Choose a quantity of at least 1.") unless wanted&.positive?

    current = entries
    total = current[variant.id.to_s].to_i + wanted
    allowed = [ total, variant.stock, MAX_QUANTITY ].min
    write(current.merge(variant.id.to_s => allowed))
    return Result.new(ok: true, message: "Added to your cart.") if allowed == total

    Result.new(ok: true, message: "Only #{allowed} of #{describe(variant)} available, so your cart has #{allowed}.")
  end

  def update(variant_id, quantity)
    key = variant_id.to_s
    current = entries
    return Result.new(ok: false, message: "That item is not in your cart.") unless current.key?(key)

    wanted = whole(quantity)
    return Result.new(ok: false, message: "Quantity must be a whole number.") if wanted.nil? || wanted.negative?
    return remove(key) if wanted.zero?

    variant = load_variants([ key ]).first
    return remove(key) unless variant

    allowed = [ wanted, MAX_QUANTITY ].min
    # A sold-out line keeps whatever was asked; it is excluded at checkout.
    allowed = [ allowed, variant.stock ].min if variant.stock.positive?
    write(current.merge(key => allowed))
    return Result.new(ok: true, message: "Cart updated.") if allowed == wanted

    Result.new(ok: true, message: "Only #{allowed} of #{describe(variant)} available, so your cart has #{allowed}.")
  end

  def remove(variant_id)
    write(entries.except(variant_id.to_s))
    Result.new(ok: true, message: "Removed from your cart.")
  end

  # Caps each line at the stock left right now. Returns one sentence per line
  # it changed, for the buyer.
  def reconcile(lines)
    current = entries
    messages = lines.filter_map do |line|
      next if line.quantity <= line.variant.stock

      current[line.variant.id.to_s] = line.variant.stock
      "Only #{line.variant.stock} of #{line.name} left, so your cart now has #{line.variant.stock}."
    end
    write(current)
    messages
  end

  def clear
    @session.delete(:cart)
  end

  private

  def entries
    raw = @session[:cart]
    return {} unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(id, quantity), clean|
      key = id.to_s
      count = whole(quantity)
      clean[key] = [ count, MAX_QUANTITY ].min if key.match?(ID) && count&.positive?
    end
  end

  def write(entries)
    @session[:cart] = entries
  end

  def load_variants(ids)
    numeric = ids.map(&:to_s).grep(ID).map(&:to_i)
    return [] if numeric.empty?

    ProductVariant.where(id: numeric).eager(:option_values, product: :options).all
  end

  def whole(value)
    Integer(value.to_s.strip, 10, exception: false)
  end

  def describe(variant)
    Line.new(variant: variant, quantity: 1).name
  end
end
