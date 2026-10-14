# What /admin/settings submits, parsed into the StoreSetting row. Dollars
# and percents in, cents and basis points out; a malformed number is an
# error, never zero. A new tax rate becomes a new Stripe tax rate, because
# Stripe's cannot be edited, and if Stripe refuses it nothing is saved.
class StoreSettingsForm
  DECIMAL = /\A\d+(\.\d{1,2})?\z/
  LABELS = { shipping_cents: "Shipping rate", pickup_instructions: "Pickup instructions", tax_rate_bps: "Tax rate" }.freeze

  attr_reader :setting, :errors

  def initialize(setting, params = nil, gateway: StripeGateway.current)
    @setting = setting
    @params = params&.to_h&.stringify_keys
    @gateway = gateway
    @errors = []
  end

  def shipping_input
    @params ? @params["shipping"].to_s : ProductEditor.format_money(@setting.shipping_cents)
  end

  def pickup_input
    @params ? @params["pickup_instructions"].to_s : @setting.pickup_instructions
  end

  def tax_enabled?
    @params ? @params["tax_enabled"] == "1" : @setting.tax_enabled?
  end

  def tax_rate_input
    return @params["tax_rate"].to_s if @params

    ProductEditor.format_money(@setting.tax_rate_bps)
  end

  def save
    shipping = hundredths(@params["shipping"])
    rate_text = @params["tax_rate"].to_s.strip
    rate = rate_text.empty? ? nil : hundredths(rate_text)

    @errors << "Shipping rate must be a dollar amount, like 8.00." unless shipping
    @errors << "Tax rate must be a percent, like 7 or 7.25." if rate_text.present? && rate.nil?
    return false if @errors.any?

    @setting.set(shipping_cents: shipping, tax_rate_bps: rate, tax_enabled: tax_enabled?,
                 pickup_instructions: @params["pickup_instructions"].to_s.strip)
    unless @setting.valid?
      @setting.errors.each { |field, messages| messages.each { |message| @errors << "#{LABELS.fetch(field)} #{message}." } }
      return false
    end

    refresh_stripe_tax_rate
    @setting.save
    true
  rescue StripeGateway::Error => e
    @errors << "Stripe did not accept the tax rate (#{e.message}). Nothing was saved."
    false
  end

  private

  def refresh_stripe_tax_rate
    return unless @setting.tax_enabled?
    return if @setting.stripe_tax_rate_id && @setting.stripe_tax_rate_bps == @setting.tax_rate_bps

    @setting.set(stripe_tax_rate_id: @gateway.create_tax_rate(@setting.tax_rate_bps),
                 stripe_tax_rate_bps: @setting.tax_rate_bps)
  end

  def hundredths(text)
    clean = text.to_s.strip.delete("$%,")
    return nil unless clean.match?(DECIMAL)

    (BigDecimal(clean) * 100).round.to_i
  end
end
