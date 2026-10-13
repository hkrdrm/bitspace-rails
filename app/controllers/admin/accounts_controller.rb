module Admin
  class AccountsController < BaseController
    # Filter name => accounts.status value. Matches Account's enum.
    FILTERS = { "verified" => 2, "unverified" => 1, "closed" => 3 }.freeze
    LIMIT = 100

    def index
      @query = params[:q].to_s.strip
      @status = params[:status].to_s if FILTERS.key?(params[:status].to_s)

      accounts = Account.order(Sequel.desc(:id))
      accounts = accounts.where(status: FILTERS.fetch(@status)) if @status
      if @query.present?
        # escape_like so a typed % or _ is matched literally, not as a wildcard.
        accounts = accounts.where(Sequel.ilike(:email, "%#{accounts.escape_like(@query)}%"))
      end

      @total    = Account.count
      @verified = Account.where(status: FILTERS.fetch("verified")).count
      @matching = accounts.count
      @accounts = accounts.limit(LIMIT).all
    end
  end
end
