# A purchase. Created "pending" when checkout starts and marked "paid" by
# OrderFulfiller once Stripe confirms payment; every later status is the
# owner's to set, in any order. Items keep their own copy of what was bought.
class Order < Sequel::Model
  STATUSES = %w[pending paid printing ready_for_pickup shipped completed cancelled refunded].freeze
  ADMIN_STATUSES = (STATUSES - [ "pending" ]).freeze
  NEEDS_ACTION = %w[paid printing ready_for_pickup].freeze
  FULFILLMENTS = %w[pickup shipping].freeze
  STATUS_LABELS = {
    "pending" => "Confirming payment", "paid" => "Paid", "printing" => "Printing",
    "ready_for_pickup" => "Ready for pickup", "shipped" => "Shipped", "completed" => "Completed",
    "cancelled" => "Cancelled", "refunded" => "Refunded"
  }.freeze
  NUMBER_OFFSET = 1000
  MAX_TRACKING = 100

  one_to_many :items, class: :OrderItem, order: :id
  many_to_one :account

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers

  dataset_module do
    # Orders someone has paid for. Pending ones are in flight or abandoned.
    def placed
      exclude(status: "pending")
    end
  end

  def before_validation
    if new?
      self.status ||= "pending"
      # The public number derives from the id, so the id comes from the
      # sequence before the insert instead of a second write after it.
      values[:id] ||= db.get(Sequel.function(:nextval, "orders_id_seq"))
      self.number ||= "BS-#{id + NUMBER_OFFSET}"
      self.token ||= SecureRandom.urlsafe_base64(24)
    end
    super
  end

  def pending?
    status == "pending"
  end

  def pickup?
    fulfillment == "pickup"
  end

  def shipping?
    fulfillment == "shipping"
  end

  def status_label
    STATUS_LABELS.fetch(status, status.to_s.humanize)
  end

  def item_count
    items.sum(&:quantity)
  end

  def partially_refunded?
    refunded_cents.to_i.positive? && refunded_cents < total_cents
  end

  # Stripe's address hash, stored as JSON, as printable lines.
  def address_lines
    return [] if ship_address.blank?

    address = JSON.parse(ship_address)
    region = [ address["state"], address["postal_code"] ].compact_blank.join(" ")
    [ address["line1"], address["line2"], [ address["city"], region ].compact_blank.join(", "), address["country"] ].compact_blank
  rescue JSON::ParserError
    []
  end

  # From Stripe's charge.refunded: amount_refunded is the running total for
  # the charge, so it replaces rather than adds.
  def record_refund(amount_refunded:, amount:)
    changes = { refunded_cents: amount_refunded }
    changes[:status] = "refunded" if amount_refunded >= amount
    update(changes)
  end

  def validate
    super
    validates_includes STATUSES, :status
    validates_includes FULFILLMENTS, :fulfillment
    validates_presence [ :subtotal_cents, :total_cents ]
    validates_operator(:>=, 0, [ :subtotal_cents, :shipping_cents, :tax_cents, :total_cents, :refunded_cents ], allow_nil: true)
    validates_max_length MAX_TRACKING, :tracking_number, allow_nil: true
  end
end
