module Admin
  class OverviewController < BaseController
    ACTIVITY_LIMIT = 8

    def index
      week = 7.days.ago

      @accounts     = Account.count
      @verified     = Account.where(status: AccountsController::FILTERS.fetch("verified")).count
      @new_accounts = Account.where { created_at >= week }.count
      @products_live = Product.where(active: true).count

      paid = Order.placed.where { paid_at >= week }
      @orders_week  = paid.count
      @revenue_week = paid.get(Sequel.function(:coalesce, Sequel.function(:sum, Sequel[:total_cents] - Sequel[:refunded_cents]), 0)).to_i

      views = PageView.where { created_at >= week }
      @views  = views.count
      @humans = views.where(bot: false).count
      @bots   = views.where(bot: true).count

      @activity = recent_activity
    end

    private

    # New sign-ups, product changes and paid orders, newest first.
    def recent_activity
      signups = Account.exclude(created_at: nil).order(Sequel.desc(:created_at)).limit(ACTIVITY_LIMIT).all.map do |account|
        { at: account.created_at, text: "New account: #{account.email}" }
      end

      products = Product.order(Sequel.desc(:updated_at)).limit(ACTIVITY_LIMIT).all.map do |product|
        verb = product.updated_at - product.created_at < 1 ? "added" : "updated"
        { at: product.updated_at, text: "Product #{verb}: #{product.name}" }
      end

      orders = Order.placed.exclude(paid_at: nil).order(Sequel.desc(:paid_at)).limit(ACTIVITY_LIMIT).all.map do |order|
        total = ActiveSupport::NumberHelper.number_to_currency(order.total_cents / 100.0)
        { at: order.paid_at, text: "Order #{order.number} paid — #{total}" }
      end

      (signups + products + orders).sort_by { |event| -event[:at].to_f }.first(ACTIVITY_LIMIT)
    end
  end
end
