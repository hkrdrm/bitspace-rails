module Admin
  class OverviewController < BaseController
    ACTIVITY_LIMIT = 8

    def index
      week = 7.days.ago

      @accounts     = Account.count
      @verified     = Account.where(status: AccountsController::FILTERS.fetch("verified")).count
      @new_accounts = Account.where { created_at >= week }.count
      @products_live = Product.where(active: true).count

      views = PageView.where { created_at >= week }
      @views  = views.count
      @humans = views.where(bot: false).count
      @bots   = views.where(bot: true).count

      @activity = recent_activity
    end

    private

    # New sign-ups and product changes, newest first. Orders join this list
    # once they exist.
    def recent_activity
      signups = Account.exclude(created_at: nil).order(Sequel.desc(:created_at)).limit(ACTIVITY_LIMIT).all.map do |account|
        { at: account.created_at, text: "New account: #{account.email}" }
      end

      products = Product.order(Sequel.desc(:updated_at)).limit(ACTIVITY_LIMIT).all.map do |product|
        verb = product.updated_at - product.created_at < 1 ? "added" : "updated"
        { at: product.updated_at, text: "Product #{verb}: #{product.name}" }
      end

      (signups + products).sort_by { |event| -event[:at].to_f }.first(ACTIVITY_LIMIT)
    end
  end
end
