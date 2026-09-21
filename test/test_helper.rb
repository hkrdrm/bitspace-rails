ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Sequel gives us no transactional tests, and parallel workers share one
    # database here, so tests run serially and clean up after themselves.
    # Rails' parallel testing provisions a database per worker for ActiveRecord
    # only, so Sequel workers would all hammer the same database and collide.
    parallelize(workers: 1)

    # This app's data layer is Sequel; config/application.rb deliberately does not
    # require active_record/railtie, so ActiveRecord never gets a connection.
    # ActiveRecord::Base is still *defined* (solid_cache, solid_queue, solid_cable,
    # ActionText, ActiveStorage and ActionMailbox all require it), and that alone is
    # enough for rails/test_help to mix ActiveRecord::TestFixtures into every test.
    # Its setup_fixtures hook then asks for a connection pool unconditionally and
    # raises ActiveRecord::ConnectionNotDefined before any test body runs, so the
    # fixture lifecycle has to be neutralized here. Commenting out `fixtures :all`
    # is not sufficient -- the fixture load is not conditional on it.
    private def setup_fixtures(config = nil)
    end

    private def teardown_fixtures
    end

    # Every account created by a test uses an @example.test address so teardown
    # can find and remove it. Rodauth's after_login hook writes a remember key,
    # and those rows reference accounts, so they go first.
    ACCOUNT_KEY_TABLES = %i[
      account_remember_keys
      account_verification_keys
      account_password_reset_keys
      account_login_change_keys
    ].freeze

    teardown do
      ids = Account.where(Sequel.like(:email, "%@example.test")).select_map(:id)
      unless ids.empty?
        ACCOUNT_KEY_TABLES.each do |table|
          Account.db[table].where(id: ids).delete if Account.db.table_exists?(table)
        end
        Account.where(id: ids).delete
      end
    end

    def create_account(email: nil, password: "password123", status: 2, superuser: false)
      Account.create(
        email: email || "test-#{SecureRandom.hex(6)}@example.test",
        password_hash: RodauthApp.rodauth.allocate.password_hash(password),
        status: status,
        superuser: superuser
      )
    end
  end
end

class ActionDispatch::IntegrationTest
  def sign_in(account, password: "password123")
    post "/login", params: { email: account.email, password: password }
  end
end
