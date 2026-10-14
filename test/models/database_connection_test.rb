require "test_helper"

# The remote Postgres closes connections that sit idle for a few minutes. A
# pooled connection the server had closed used to fail the next request with
# Sequel::DatabaseDisconnectError (seen as a 500 on the first add to cart
# after a quiet spell).
class DatabaseConnectionTest < ActiveSupport::TestCase
  test "idle connections are checked before reuse" do
    assert_equal SequelConnectionCheck::IDLE_SECONDS, Sequel::Model.db.pool.connection_validation_timeout
  end

  test "a pooled connection the server closed is replaced instead of failing the next query" do
    db = Sequel::Model.db
    pid = db.get(Sequel.function(:pg_backend_pid))
    killer = Sequel.connect(db.opts.merge(max_connections: 1))
    begin
      killer.get(Sequel.function(:pg_terminate_backend, pid))
    ensure
      killer.disconnect
    end

    # Check on every checkout, so the test needn't wait out the idle window.
    timeout = db.pool.connection_validation_timeout
    db.pool.connection_validation_timeout = -1
    begin
      assert_equal 1, db.get(1)
    ensure
      db.pool.connection_validation_timeout = timeout
    end
  end
end
