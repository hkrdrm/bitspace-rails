# Stands in for StripeGateway in every test. It records what the app asked
# Stripe for, returns sessions with predictable shapes, and verifies webhook
# signatures with the real Stripe code and a known secret.
class FakeStripeGateway
  WEBHOOK_SECRET = "whsec_test_secret"

  attr_reader :sessions_created, :tax_rates_created
  attr_accessor :fail_with

  def initialize
    @sessions_created = []
    @tax_rates_created = []
    @sessions = {}
    @tax_rates = {}
    @fail_with = nil
  end

  def create_checkout_session(params)
    fail_if_asked
    @sessions_created << params
    id = "cs_test_#{@sessions_created.size}_#{SecureRandom.hex(4)}"
    Stripe::Checkout::Session.construct_from(id: id, url: "https://checkout.stripe.test/#{id}")
  end

  def retrieve_session(id)
    fail_if_asked
    @sessions.fetch(id) { raise StripeGateway::Error, "No such checkout.session: '#{id}'" }
  end

  # Makes retrieve_session(id) return a session with these fields.
  def stub_session(id, **fields)
    @sessions[id] = Stripe::Checkout::Session.construct_from({ id: id }.merge(fields))
  end

  def create_tax_rate(bps)
    fail_if_asked
    @tax_rates_created << bps
    id = "txr_test_#{@tax_rates_created.size}"
    @tax_rates[id] = bps
    id
  end

  def tax_rate_usable?(id, bps)
    fail_if_asked
    @tax_rates[id] == bps
  end

  # As if the rate were archived, or the keys switched to the other mode.
  def forget_tax_rate(id)
    @tax_rates.delete(id)
  end

  def construct_event(payload, signature)
    StripeGateway.new(api_key: nil, webhook_secret: WEBHOOK_SECRET).construct_event(payload, signature)
  end

  private

  def fail_if_asked
    raise StripeGateway::Error, fail_with if fail_with
  end
end
