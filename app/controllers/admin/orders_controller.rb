module Admin
  class OrdersController < BaseController
    LIMIT = 100
    # Filter key => [link label, dataset narrowing]. Pending orders never show.
    FILTERS = {
      "needs_action" => [ "Needs action", ->(orders) { orders.where(status: Order::NEEDS_ACTION) } ],
      "pickup"       => [ "Pickup",       ->(orders) { orders.where(fulfillment: "pickup") } ],
      "shipping"     => [ "Shipping",     ->(orders) { orders.where(fulfillment: "shipping") } ],
      "oversold"     => [ "Oversold",     ->(orders) { orders.where(oversold: true) } ],
      "refunded"     => [ "Refunded",     ->(orders) { orders.where(status: "refunded") } ]
    }.freeze

    def index
      @query = params[:q].to_s.strip
      @filter = params[:filter].to_s if FILTERS.key?(params[:filter].to_s)

      orders = Order.placed.order(Sequel.desc(:id))
      orders = FILTERS.fetch(@filter).last.call(orders) if @filter
      if @query.present?
        # escape_like so a typed % or _ is matched literally, not as a wildcard.
        pattern = "%#{orders.escape_like(@query)}%"
        orders = orders.where(Sequel.ilike(:number, pattern) | Sequel.ilike(:email, pattern))
      end

      @total = Order.placed.count
      @matching = orders.count
      @orders = orders.eager(:items).limit(LIMIT).all
    end

    def show
      @order = find_order
    end

    def update
      @order = find_order
      status = params[:status].to_s

      unless Order::ADMIN_STATUSES.include?(status)
        @error = "Choose a status from the list."
        return render :show, status: :unprocessable_entity
      end

      @order.set(status: status, tracking_number: params[:tracking_number].to_s.strip.presence)
      unless @order.valid?
        @error = "Tracking number must be #{Order::MAX_TRACKING} characters or fewer."
        return render :show, status: :unprocessable_entity
      end

      @order.save
      redirect_to admin_order_path(@order.number), notice: "Order updated."
    end

    private

    def find_order
      order = Order.placed.where(number: params[:number].to_s).eager(:items).all.first
      raise ActionController::RoutingError, "Not Found" unless order

      order
    end
  end
end
