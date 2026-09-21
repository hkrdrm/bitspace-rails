class Product < Sequel::Model
  SIZES = %w[S M L XL 2XL 3XL].freeze

  # The shop's stocked blanks. Hash order is display order.
  COLORS = {
    "Black"        => "#0d1114",
    "White"        => "#f7f7f5",
    "Heather Grey" => "#b5b8ba",
    "Navy"         => "#1b2a41",
    "Sand"         => "#d8cbb4",
    "Red"          => "#b3261e"
  }.freeze

  # Shown for a colour that has left the palette but still has rows.
  NEUTRAL_SWATCH = "#9ca3af"

  one_to_many :variants, class: :ProductVariant, order: [ :position, :color ]

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  dataset_module do
    def published
      where(active: true).order(:name)
    end
  end

  # Which colours this design comes in. Derived from the variants so there is
  # one source of truth rather than a list that can drift from the rows.
  def colors
    variants.map(&:color).uniq.sort_by { |color| COLORS.keys.index(color) || COLORS.size }
  end

  def variants_for(color)
    variants.select { |variant| variant.color == color }
  end

  def price_range
    prices = variants.map(&:price_cents)
    return [ base_price_cents, base_price_cents ] if prices.empty?

    [ prices.min, prices.max ]
  end

  def stock_for(size:, color:)
    variants.find { |variant| variant.size == size && variant.color == color }&.stock || 0
  end

  def in_stock?
    variants.any? { |variant| variant.stock.positive? }
  end

  def total_stock
    variants.sum(&:stock)
  end

  def swatch_for(color)
    COLORS.fetch(color, NEUTRAL_SWATCH)
  end

  def validate
    super
    validates_presence [ :name, :slug, :base_price_cents ]
    validates_format(/\A[a-z0-9-]+\z/, :slug, message: "must be lowercase letters, numbers and dashes")
    validates_unique(:slug)
    validates_operator(:>=, 0, :base_price_cents, allow_nil: true)
  end
end
