class ProductVariant < Sequel::Model
  many_to_one :product

  plugin :validation_helpers
  plugin :boolean_readers

  def validate
    super
    validates_presence [ :product_id, :size, :color, :price_cents, :stock, :position ]
    validates_includes Product::SIZES, :size
    validates_includes Product::COLORS.keys, :color
    validates_operator(:>=, 0, :price_cents, allow_nil: true)
    validates_operator(:>=, 0, :stock, allow_nil: true)
    validates_unique([ :product_id, :size, :color ])
  end
end
