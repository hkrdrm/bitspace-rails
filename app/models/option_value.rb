# One value of one option, such as "2XL" or "Tie-Dye". The swatch is what the
# product page's selector shows; the image, when set, replaces the product
# photo while this value is selected.
class OptionValue < Sequel::Model
  HEX = /\A#\h{6}\z/

  many_to_one :product_option

  plugin :validation_helpers

  def swatch?
    swatch_hex.present? || swatch_image.present?
  end

  def validate
    super
    validates_presence [ :product_option_id, :name, :position ]
    validates_unique([ :product_option_id, :name ])
    validates_format(HEX, :swatch_hex, allow_nil: true, message: "must be a colour like #1b2a41")

    [ :swatch_image, :image ].each do |column|
      filename = public_send(column)
      next if filename.blank? || Product.asset_exists?(filename)

      errors.add(column, "is not a file in app/assets/images")
    end
  end
end
