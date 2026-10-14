# One line of an order: a copy of the product, variant label and price at the
# moment of checkout. variant_id goes NULL if the variant is deleted later.
class OrderItem < Sequel::Model
  many_to_one :order
  many_to_one :variant, class: :ProductVariant

  plugin :validation_helpers

  def total_cents
    unit_price_cents * quantity
  end

  def validate
    super
    validates_presence [ :order_id, :product_name, :variant_label, :unit_price_cents, :quantity ]
    validates_operator(:>, 0, :quantity, allow_nil: true)
    validates_operator(:>=, 0, :unit_price_cents, allow_nil: true)
  end
end
