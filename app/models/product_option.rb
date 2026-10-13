# One option of one product, such as Size or Colour. Options belong to a single
# product, so changing one never touches another product.
class ProductOption < Sequel::Model
  many_to_one :product
  one_to_many :option_values, class: :OptionValue, order: :position

  plugin :validation_helpers

  def validate
    super
    validates_presence [ :product_id, :name, :position ]
    validates_unique([ :product_id, :name ])

    if new? && product_id && ProductOption.where(product_id: product_id).count >= Product::MAX_OPTIONS
      errors.add(:product, "already has #{Product::MAX_OPTIONS} options")
    end
  end
end
