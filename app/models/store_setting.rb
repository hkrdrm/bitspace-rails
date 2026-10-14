# The shop's one row of settings: flat shipping rate, pickup text, and the
# sales tax switch. stripe_tax_rate_bps records which rate the stored Stripe
# tax rate was created for, because Stripe's tax rates cannot be edited.
class StoreSetting < Sequel::Model
  DEFAULT_SHIPPING_CENTS = 800
  DEFAULT_INSTRUCTIONS = "Pickup in McComb, MS. We'll reach out when it's ready.".freeze
  MAX_SHIPPING_CENTS = 10_000
  MAX_TAX_RATE_BPS = 1_500
  MAX_INSTRUCTIONS = 500

  plugin :boolean_readers

  def self.current
    order(:id).first || create(shipping_cents: DEFAULT_SHIPPING_CENTS, pickup_instructions: DEFAULT_INSTRUCTIONS)
  end

  # The Stripe tax rate checkout should charge, or nil while tax is off.
  def checkout_tax_rate_id
    stripe_tax_rate_id if tax_enabled? && tax_rate_bps
  end

  def before_save
    self.updated_at = Time.current
    super
  end

  def validate
    super
    unless shipping_cents && (0..MAX_SHIPPING_CENTS).cover?(shipping_cents)
      errors.add(:shipping_cents, "must be between $0.00 and $100.00")
    end

    if pickup_instructions.to_s.strip.empty?
      errors.add(:pickup_instructions, "can't be blank")
    elsif pickup_instructions.length > MAX_INSTRUCTIONS
      errors.add(:pickup_instructions, "must be #{MAX_INSTRUCTIONS} characters or fewer")
    end

    if tax_rate_bps.nil?
      errors.add(:tax_rate_bps, "is required while sales tax is on") if tax_enabled?
    elsif !(1..MAX_TAX_RATE_BPS).cover?(tax_rate_bps)
      errors.add(:tax_rate_bps, "must be between 0.01% and 15%")
    end
  end
end
