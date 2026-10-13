# Saves a product together with its options and the variants derived from
# them. Sequel has no nested attributes, and the set of variants is computed
# from the options rather than submitted, so this is the one place that turns
# the admin form into rows.
#
# Every write happens inside one transaction: a save either applies in full or
# leaves the database as it was.
class ProductEditor
  MONEY = /\A\d+(\.\d{1,2})?\z/
  WHOLE = /\A\d+\z/
  MAX_STOCK = 1_000_000

  # A variant this save would delete while it still holds stock.
  Loss = Data.define(:label, :stock)

  attr_reader :product, :errors, :pending_loss, :option_inputs, :variant_inputs,
              :price_input, :simple_stock_input, :created_count

  # The form state for an existing product, as the edit page first shows it.
  def self.from_product(product)
    new(product, {
      "options" => product.options.map do |option|
        {
          "name" => option.name,
          "values" => option.option_values.map.with_index(1) do |value, position|
            {
              "name" => value.name, "position" => position.to_s, "swatch_hex" => value.swatch_hex,
              "swatch_image" => value.swatch_image, "image" => value.image
            }
          end
        }
      end,
      "variants" => product.variants.to_h do |variant|
        [ variant.id.to_s, {
          "stock" => variant.stock.to_s,
          "price_override" => format_money(variant.price_override_cents),
          "sku" => variant.sku.to_s
        } ]
      end
    })
  end

  # A new, unsaved product, optionally starting from another product's options.
  def self.blank(copy_from: nil)
    editor = new(Product.new(price_cents: 1200, active: true), {})
    editor.copy_options_from(copy_from) if copy_from
    editor
  end

  # Integer cents as a money field shows them: 1200 => "12.00", nil => "".
  def self.format_money(cents)
    return "" if cents.nil?

    format("%d.%02d", cents / 100, cents % 100)
  end

  def initialize(product, params)
    @product = product
    @params = params.to_h.deep_stringify_keys
    @errors = []
    @pending_loss = []
    @created_count = 0
    @variants_changed = false
    @price_input = @params.dig("product", "price")&.to_s || self.class.format_money(product.price_cents)
    @simple_stock_input = @params["simple_stock"].to_s.strip
    @option_inputs = parse_options(@params["options"])
    @variant_inputs = (@params["variants"] || {}).to_h do |id, fields|
      [ id.to_s, fields.to_h.transform_values(&:to_s) ]
    end
  end

  def copy_options_from(source)
    @option_inputs = self.class.from_product(source).option_inputs
  end

  def variants_changed?
    @variants_changed
  end

  def save
    @was_new = product.new?
    assign_product_fields
    validate_options
    validate_simple_stock
    validate_variant_count
    validate_product
    updates = parse_variant_updates
    return false if errors.any?

    combos = combinations
    doomed = doomed_variants(combos)
    return false if unconfirmed_loss?(doomed)

    Product.db.transaction do
      product.save
      ProductVariant.where(id: doomed.map(&:id)).delete if doomed.any?
      value_ids = sync_options
      sync_variants(combos, value_ids, doomed)
      apply_variant_updates(updates, doomed)
    end

    @variants_changed = doomed.any? || created_count.positive?
    product.refresh
    true
  rescue Sequel::ValidationFailed => e
    restore_after_rollback
    errors.concat(messages_for(e.model))
    false
  rescue Sequel::UniqueConstraintViolation
    restore_after_rollback
    errors << "Something else saved a clashing slug or SKU at the same moment. Try again."
    false
  end

  private

  # Options arrive as index-keyed hashes from the form ("0" => {...}) or as
  # arrays from code. Both become ordered arrays. Blank rows, which are the
  # spares the form pads with, are dropped here so nothing downstream sees them.
  def parse_options(raw)
    ordered(raw).filter_map do |option|
      name = option["name"].to_s.strip
      values = ordered(option["values"]).each_with_index.filter_map do |value, index|
        value_name = value["name"].to_s.strip
        next if value_name.empty?

        position = value["position"].to_s.strip
        {
          name: value_name,
          position: position.match?(WHOLE) ? position.to_i : index + 1,
          swatch_hex: value["swatch_hex"].to_s.strip.presence,
          swatch_image: value["swatch_image"].to_s.strip.presence,
          image: value["image"].to_s.strip.presence,
          index: index
        }
      end
      next if name.empty? && values.empty?

      { name: name, values: values.sort_by { |value| [ value[:position], value[:index] ] } }
    end
  end

  def ordered(raw)
    rows = raw.is_a?(Hash) ? raw.sort_by { |key, _| key.to_i }.map(&:last) : Array(raw)
    rows.select { |row| row.is_a?(Hash) }
  end

  def assign_product_fields
    fields = @params["product"] || {}
    name = fields["name"].to_s.strip
    @product_fields = {
      name: name,
      slug: fields["slug"].to_s.strip.presence || name.parameterize,
      description: fields["description"].to_s.strip,
      image: fields["image"].to_s.strip.presence,
      price_cents: cents(fields["price"]),
      active: fields["active"] == "1"
    }
    product.set(@product_fields)
  end

  def validate_options
    if option_inputs.size > Product::MAX_OPTIONS
      errors << "A product can have at most #{Product::MAX_OPTIONS} options."
    end

    seen = []
    option_inputs.each.with_index(1) do |option, number|
      title = option[:name].presence || "Option #{number}"
      errors << "Option #{number} needs a name." if option[:name].empty?
      errors << "#{title} needs at least one value." if option[:values].empty?
      if option[:name].present? && seen.include?(option[:name].downcase)
        errors << "There are two options called #{option[:name]}."
      end
      seen << option[:name].downcase

      option[:values].group_by { |value| value[:name].downcase }.each_value do |same|
        errors << "#{title} lists #{same.first[:name]} more than once." if same.size > 1
      end
    end
  end

  # Counted before the combinations are built, so a hostile form cannot make
  # the server enumerate millions of them.
  def validate_variant_count
    count = option_inputs.map { |option| option[:values].size }.inject(1, :*)
    return if count <= Product::MAX_VARIANTS

    errors << "Those options make #{count} variants; the limit is #{Product::MAX_VARIANTS}."
  end

  def validate_product
    errors << "Price must be an amount like 12.00." if product.price_cents.nil?
    return if product.valid?

    product.errors.each do |attribute, messages|
      next if attribute == :price_cents && product.price_cents.nil?

      messages.each { |message| errors << "#{attribute.to_s.humanize} #{message}." }
    end
  end

  def validate_simple_stock
    return if simple_stock_input.empty? || whole_stock?(simple_stock_input)

    errors << "Stock must be a whole number from 0 to #{MAX_STOCK.to_fs(:delimited)}."
  end

  def whole_stock?(text)
    text.match?(WHOLE) && text.to_i <= MAX_STOCK
  end

  # Per-variant fields from the variants table, keyed by variant id. Ids that
  # do not belong to this product are ignored, so a crafted form cannot touch
  # another product's stock. A field missing from the submission is left alone.
  def parse_variant_updates
    variant_inputs.each_with_object({}) do |(id, fields), updates|
      label = existing_labels[id.to_i] or next
      update = {}

      if fields.key?("stock")
        stock = fields["stock"].strip
        if stock.empty?
          update[:stock] = 0
        elsif whole_stock?(stock)
          update[:stock] = stock.to_i
        else
          errors << "Stock for #{label} must be a whole number from 0 to #{MAX_STOCK.to_fs(:delimited)}."
        end
      end

      if fields.key?("price_override")
        text = fields["price_override"].strip
        if text.empty?
          update[:price_override_cents] = nil
        elsif (amount = cents(text))
          update[:price_override_cents] = amount
        else
          errors << "Price for #{label} must be an amount like 12.00, or blank to use the product price."
        end
      end

      update[:sku] = fields["sku"].strip.presence if fields.key?("sku")
      updates[id.to_i] = update
    end
  end

  # Records every variant this save would delete while it holds stock, and
  # refuses unless the admin ticked the confirmation box.
  def unconfirmed_loss?(doomed)
    @pending_loss = doomed.select { |variant| variant.stock.positive? }
                          .map { |variant| Loss.new(label: existing_labels.fetch(variant.id), stock: variant.stock) }
    return false if pending_loss.empty? || @params["confirm_loss"] == "1"

    errors << "This change deletes variants that still have stock. Tick the box below to confirm."
    true
  end

  def apply_variant_updates(updates, doomed)
    doomed_ids = doomed.map(&:id)

    existing_variants.each do |variant|
      update = updates[variant.id]
      next if update.blank? || doomed_ids.include?(variant.id)

      variant.update(update)
    end
  end

  # A brand-new simple variant takes the stock typed on the new-product form.
  # Every other new variant starts at zero, because the admin had nowhere to
  # type its stock yet.
  def initial_stock(pairs)
    pairs.empty? && whole_stock?(simple_stock_input) ? simple_stock_input.to_i : 0
  end

  # Every combination of one value per option, in option order and then value
  # order, as [option name, value name] pairs. A product with no options has
  # exactly one combination: the empty one.
  def combinations
    axes = option_inputs.map { |option| option[:values].map { |value| [ option[:name], value[:name] ] } }
    return [ [] ] if axes.empty?

    axes.first.product(*axes.drop(1))
  end

  # The variants this save removes: those whose combination is no longer
  # wanted. Matched by name, ignoring case, because names are what the form
  # submits; ids for new values do not exist yet.
  def doomed_variants(combos)
    wanted = combos.map { |pairs| signature(pairs) }.to_set
    existing_variants.reject { |variant| wanted.include?(signature(existing_pairs(variant))) }
  end

  def signature(pairs)
    pairs.map { |option, value| [ option.downcase, value.downcase ] }.sort
  end

  # Snapshots taken before any write, so they describe the product as it was.
  def existing_variants
    @existing_variants ||= if product.new?
      []
    else
      ProductVariant.where(product_id: product.id).eager(:option_values).order(:position).all
    end
  end

  def existing_options
    @existing_options ||= if product.new?
      {}
    else
      ProductOption.where(product_id: product.id).all.to_h { |option| [ option.id, option ] }
    end
  end

  # A stored variant's [option name, value name] pairs, in option order.
  def existing_pairs(variant)
    variant.option_values
      .map { |value| [ existing_options.fetch(value.product_option_id), value ] }
      .sort_by { |option, _| option.position }
      .map { |option, value| [ option.name, value.name ] }
  end

  def existing_labels
    @existing_labels ||= existing_variants.to_h do |variant|
      pairs = existing_pairs(variant)
      [ variant.id, pairs.empty? ? product.name : pairs.map(&:last).join(" / ") ]
    end
  end

  # Upserts options and values by name, ignoring case, and deletes the ones no
  # longer listed. Removed rows go first, so replacing an option on a product
  # already at the option limit does not trip the limit. Returns a map from
  # [option name, value name], downcased, to value id.
  def sync_options
    current = existing_options.values.to_h { |option| [ option.name.downcase, option ] }
    wanted = option_inputs.map { |input| input[:name].downcase }
    stale = current.reject { |name, _| wanted.include?(name) }
    ProductOption.where(id: stale.values.map(&:id)).delete if stale.any?

    option_inputs.each_with_index.with_object({}) do |(input, position), value_ids|
      option = current[input[:name].downcase] || ProductOption.new(product_id: product.id)
      option.set(name: input[:name], position: position)
      option.save

      sync_values(option, input[:values]).each do |value|
        value_ids[[ input[:name].downcase, value.name.downcase ]] = value.id
      end
    end
  end

  def sync_values(option, inputs)
    current = OptionValue.where(product_option_id: option.id).all.to_h { |value| [ value.name.downcase, value ] }
    wanted = inputs.map { |input| input[:name].downcase }
    stale = current.reject { |name, _| wanted.include?(name) }
    OptionValue.where(id: stale.values.map(&:id)).delete if stale.any?

    inputs.each_with_index.map do |input, position|
      value = current[input[:name].downcase] || OptionValue.new(product_option_id: option.id)
      value.set(
        name: input[:name], position: position,
        swatch_hex: input[:swatch_hex], swatch_image: input[:swatch_image], image: input[:image]
      )
      value.save
      value
    end
  end

  # Creates a variant for each new combination and renumbers the survivors.
  def sync_variants(combos, value_ids, doomed)
    survivors = (existing_variants - doomed).to_h { |variant| [ variant.options_key, variant ] }

    combos.each_with_index do |pairs, position|
      ids = pairs.map { |option, value| value_ids.fetch([ option.downcase, value.downcase ]) }
      key = ProductVariant.key_for(ids)

      if (variant = survivors[key])
        variant.update(position: position) unless variant.position == position
      else
        variant = ProductVariant.create(product_id: product.id, options_key: key, position: position, stock: initial_stock(pairs))
        Product.db[:variant_option_values].import(
          [ :product_variant_id, :option_value_id ], ids.map { |id| [ variant.id, id ] }
        )
        @created_count += 1
      end
    end
  end

  # The transaction rolled back, but a new product object still believes it
  # was saved, because it holds an id. Swap in an unsaved copy so the
  # re-rendered form posts to create again.
  def restore_after_rollback
    @created_count = 0
    @product = Product.new(@product_fields) if @was_new
  end

  def messages_for(model)
    subject = if model.is_a?(Product)
      nil
    elsif model.is_a?(ProductVariant)
      existing_labels.fetch(model.id, "A variant")
    else
      model.name.presence || "A value"
    end

    model.errors.flat_map do |attribute, messages|
      messages.map { |message| [ subject, "#{attribute.to_s.humanize} #{message}." ].compact.join(": ") }
    end
  end

  # Cents, or nil when the text is not a well-formed non-negative amount.
  # Callers treat nil as an error, never as zero: a silently zeroed price
  # would put a product in the shop for free.
  def cents(value)
    text = value.to_s.strip.delete("$").delete(",")
    return nil unless text.match?(MONEY)

    (BigDecimal(text) * 100).round
  end
end
