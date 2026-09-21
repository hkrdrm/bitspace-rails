ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # This app's data layer is Sequel; config/application.rb deliberately does not
    # require active_record/railtie, so ActiveRecord never gets a connection.
    # ActiveRecord::Base is still *defined* (solid_cache, solid_queue, solid_cable,
    # ActionText, ActiveStorage and ActionMailbox all require it), and that alone is
    # enough for rails/test_help to mix ActiveRecord::TestFixtures into every test.
    # Its setup_fixtures hook then asks for a connection pool unconditionally and
    # raises ActiveRecord::ConnectionNotDefined before any test body runs, so the
    # fixture lifecycle has to be neutralized here. Commenting out `fixtures :all`
    # is not sufficient -- the fixture load is not conditional on it.
    private
      def setup_fixtures(config = nil)
      end

      def teardown_fixtures
      end
  end
end
