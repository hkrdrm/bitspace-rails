require "test_helper"

class StripeGatewayTest < ActiveSupport::TestCase
  SECRET = "whsec_gateway_test"

  def gateway
    StripeGateway.new(api_key: nil, webhook_secret: SECRET)
  end

  def event_payload(type)
    { id: "evt_1", object: "event", type: type, data: { object: { id: "cs_1", object: "checkout.session" } } }.to_json
  end

  test "a correctly signed payload becomes a Stripe event" do
    payload = event_payload("checkout.session.completed")
    event = gateway.construct_event(payload, stripe_signature(payload, secret: SECRET))

    assert_equal "checkout.session.completed", event.type
    assert_equal "cs_1", event.data.object.id
  end

  test "a wrong or missing signature is rejected" do
    payload = event_payload("checkout.session.completed")

    assert_raises(StripeGateway::InvalidSignature) { gateway.construct_event(payload, stripe_signature(payload, secret: "whsec_other")) }
    assert_raises(StripeGateway::InvalidSignature) { gateway.construct_event(payload, nil) }
  end

  test "without a webhook secret every event is rejected" do
    payload = event_payload("checkout.session.completed")
    unconfigured = StripeGateway.new(api_key: nil, webhook_secret: nil)

    assert_raises(StripeGateway::InvalidSignature) { unconfigured.construct_event(payload, stripe_signature(payload, secret: SECRET)) }
  end

  test "Stripe errors come back as StripeGateway::Error" do
    error = assert_raises(StripeGateway::Error) { gateway.create_tax_rate(700) }
    assert_match(/API key/i, error.message)
  end

  test "tests never reach the real gateway" do
    assert_kind_of FakeStripeGateway, StripeGateway.current
  end

  test "the fake records sessions and returns a Stripe-hosted url" do
    session = StripeGateway.current.create_checkout_session(mode: "payment")

    assert_equal [ { mode: "payment" } ], StripeGateway.current.sessions_created
    assert_match %r{\Ahttps://checkout\.stripe\.test/cs_test_}, session.url
  end
end
