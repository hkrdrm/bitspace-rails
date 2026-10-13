# One combination of option values: the thing that has stock and that a future
# order line will point at. A simple product has one variant with no values.
class ProductVariant < Sequel::Model
  many_to_one :product
  many_to_many :option_values, join_table: :variant_option_values,
               left_key: :product_variant_id, right_key: :option_value_id

  plugin :validation_helpers

  # A combination's identity: its option value ids, sorted and joined. The
  # unique index on [product_id, options_key] is what makes a duplicate
  # combination impossible, which the join table alone cannot enforce.
  def self.key_for(option_value_ids)
    option_value_ids.sort.join("-")
  end

  # What this variant sells for. The only price reader views and future order
  # lines should use.
  def price_cents
    price_override_cents || product.price_cents
  end

  def sold_out?
    stock.zero?
  end

  def value_for(option)
    option_values.find { |value| value.product_option_id == option.id }
  end

  def label
    return product.name if product.simple?

    product.options.filter_map { |option| value_for(option)&.name }.join(" / ")
  end

  def validate
    super
    validates_presence [ :product_id, :stock, :position ]
    # Not validates_presence: a simple variant's key is "", which counts as blank.
    errors.add(:options_key, "is missing") if options_key.nil?
    validates_operator(:>=, 0, :stock, allow_nil: true)
    validates_operator(:>=, 0, :price_override_cents, allow_nil: true)
    validates_unique([ :product_id, :options_key ])
    validates_unique(:sku)
  end
end
