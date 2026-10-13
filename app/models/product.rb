class Product < Sequel::Model
  MAX_OPTIONS  = 3
  MAX_VARIANTS = 100

  one_to_many :options,  class: :ProductOption,  order: :position
  one_to_many :variants, class: :ProductVariant, order: :position

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  dataset_module do
    def published
      where(active: true).order(:name)
    end
  end

  # Whether a filename resolves to an image Propshaft can serve. Images are
  # filenames under app/assets/images until uploads exist.
  def self.asset_exists?(filename)
    Rails.application.assets.load_path.find(filename).present?
  end

  # A product with no options is a single item: a sticker, a print. It still
  # has exactly one variant, which holds its stock.
  def simple?
    options.empty?
  end

  def price_range
    prices = variants.map(&:price_cents)
    return [ price_cents, price_cents ] if prices.empty?

    [ prices.min, prices.max ]
  end

  def in_stock?
    variants.any? { |variant| variant.stock.positive? }
  end

  def total_stock
    variants.sum(&:stock)
  end

  # The option the catalog shows as swatches: the first whose values carry one.
  def swatch_option
    options.find { |option| option.option_values.any?(&:swatch?) }
  end

  def validate
    super
    validates_presence [ :name, :slug, :price_cents ]
    validates_format(/\A[a-z0-9-]+\z/, :slug, message: "must be lowercase letters, numbers and dashes")
    validates_unique(:slug)
    validates_operator(:>=, 0, :price_cents, allow_nil: true)

    if image.present? && !Product.asset_exists?(image)
      errors.add(:image, "is not a file in app/assets/images")
    end
  end
end
