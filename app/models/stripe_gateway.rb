# The only code that talks to Stripe. Everything else asks
# StripeGateway.current, which the test suite replaces with
# FakeStripeGateway so no test reaches the network.
class StripeGateway
  class Error < StandardError; end
  class InvalidSignature < StandardError; end

  class << self
    attr_writer :current

    def current
      @current ||= new
    end
  end

  def initialize(api_key: ENV["STRIPE_SECRET_KEY"], webhook_secret: ENV["STRIPE_WEBHOOK_SECRET"])
    @api_key = api_key
    @webhook_secret = webhook_secret
  end

  # Returns a Stripe::Checkout::Session; callers use #id and #url.
  def create_checkout_session(params)
    call { Stripe::Checkout::Session.create(params, request_options) }
  end

  def retrieve_session(id)
    call { Stripe::Checkout::Session.retrieve(id, request_options) }
  end

  # Stripe tax rates cannot be edited, so a new rate is a new object.
  # Returns its id.
  def create_tax_rate(bps)
    call do
      Stripe::TaxRate.create({
        display_name: "Sales tax", description: "Mississippi sales tax",
        jurisdiction: "MS", country: "US", state: "MS",
        percentage: bps / 100.0, inclusive: false, tax_type: "sales_tax"
      }, request_options).id
    end
  end

  # Checks the Stripe-Signature header and returns the Stripe::Event.
  def construct_event(payload, signature)
    raise InvalidSignature, "no webhook secret is configured" if @webhook_secret.blank?

    Stripe::Webhook.construct_event(payload, signature.to_s, @webhook_secret)
  rescue Stripe::SignatureVerificationError, JSON::ParserError => e
    raise InvalidSignature, e.message
  end

  private

  # Left out when unset: the gem raises a TypeError on a nil key rather than
  # its own "no API key" error.
  def request_options
    @api_key.present? ? { api_key: @api_key } : {}
  end

  def call
    yield
  rescue Stripe::StripeError => e
    raise Error, e.message
  end
end
