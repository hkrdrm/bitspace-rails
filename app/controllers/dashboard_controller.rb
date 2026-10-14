class DashboardController < ApplicationController
  before_action :authenticate

  RECENT_ORDERS = 3

  def index
    @recent_orders = customer_orders.limit(RECENT_ORDERS).all
  end

  def account
  end

  def orders
    @orders = customer_orders.all
  end

  private

  def customer_orders
    Order.placed.where(account_id: current_account.id).order(Sequel.desc(:id))
  end
end
