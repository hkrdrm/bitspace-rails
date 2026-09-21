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

  def validate
    super
    validates_presence [ :name, :slug, :base_price_cents ]
    validates_format(/\A[a-z0-9-]+\z/, :slug, message: "must be lowercase letters, numbers and dashes")
    validates_unique(:slug)
    validates_operator(:>=, 0, :base_price_cents, allow_nil: true)
  end
end
