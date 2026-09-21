module Admin
  class ProductsController < BaseController
    def index
      @products = Product.order(:name).all
    end

    def new
      @product = Product.new(base_price_cents: 1200, active: true)
      @selected_colors = [ "Black" ]
      @prices = Product::SIZES.index_with(1200)
      @stock  = {}
      render :new
    end

    def create
      @product = Product.new(product_attributes)
      @selected_colors = selected_colors
      @prices = submitted_prices
      @stock  = submitted_stock

      if @selected_colors.empty?
        @product.errors.add(:colors, "must include at least one colour")
        return render :new, status: :unprocessable_entity
      end

      if @product.base_price_cents.nil? || @prices.value?(nil)
        @product.errors.add(:base, "Prices must be amounts like 12.00")
        return render :new, status: :unprocessable_entity
      end

      unless @product.valid?
        return render :new, status: :unprocessable_entity
      end

      Product.db.transaction do
        @product.save
        rebuild_variants(@product)
      end

      redirect_to admin_products_path, notice: "#{@product.name} created."
    end

    def edit
      @product = find_product!
      @selected_colors = @product.colors
      @prices = Product::SIZES.index_with do |size|
        @product.variants.find { |variant| variant.size == size }&.price_cents || @product.base_price_cents
      end
      @stock = @product.colors.index_with do |color|
        Product::SIZES.index_with { |size| @product.stock_for(size: size, color: color) }
      end
    end

    def update
      @product = find_product!
      @product.set(product_attributes)
      @selected_colors = selected_colors
      @prices = submitted_prices
      @stock  = submitted_stock

      if @selected_colors.empty?
        @product.errors.add(:colors, "must include at least one colour")
        return render :edit, status: :unprocessable_entity
      end

      if @product.base_price_cents.nil? || @prices.value?(nil)
        @product.errors.add(:base, "Prices must be amounts like 12.00")
        return render :edit, status: :unprocessable_entity
      end

      unless @product.valid?
        return render :edit, status: :unprocessable_entity
      end

      Product.db.transaction do
        @product.save
        rebuild_variants(@product)
      end

      redirect_to admin_products_path, notice: "#{@product.name} updated."
    end

    def destroy
      product = find_product!
      name = product.name
      product.destroy

      redirect_to admin_products_path, notice: "#{name} deleted."
    end

    private

    # A 404 rather than a redirect, matching how the admin gate hides itself.
    def find_product!
      Product[params[:id].to_i] or raise ActionController::RoutingError, "Not Found"
    end

    def product_attributes
      attributes = params.require(:product)
      name = attributes[:name].to_s.strip
      slug = attributes[:slug].to_s.strip.presence || name.parameterize

      {
        name: name,
        slug: slug,
        description: attributes[:description].to_s.strip,
        image: attributes[:image].to_s.strip.presence,
        base_price_cents: cents(attributes[:base_price]),
        active: attributes[:active] == "1"
      }
    end

    # Only palette colours are accepted, so a hand-crafted request cannot
    # introduce a colour the shop does not stock.
    def selected_colors
      Array(params[:colors]).map(&:to_s).select { |color| Product::COLORS.key?(color) }
    end

    def submitted_prices
      Product::SIZES.index_with { |size| cents(params.dig(:prices, size)) }
    end

    def submitted_stock
      selected_colors.index_with do |color|
        Product::SIZES.index_with { |size| params.dig(:stock, color, size).to_i.clamp(0, 1_000_000) }
      end
    end

    # Deletes rows for colours no longer selected, then upserts one row per
    # selected colour and size. Callers must wrap this in a transaction.
    def rebuild_variants(product)
      colors = selected_colors
      prices = submitted_prices
      stock  = submitted_stock

      product.variants_dataset.exclude(color: colors).delete

      colors.each do |color|
        Product::SIZES.each_with_index do |size, index|
          variant = ProductVariant.first(product_id: product.id, size: size, color: color) ||
                    ProductVariant.new(product_id: product.id, size: size, color: color)
          variant.set(
            price_cents: prices.fetch(size),
            stock: stock.dig(color, size).to_i,
            position: index
          )
          variant.save
        end
      end

      product.refresh
    end

    # Returns cents, or nil when the value is not a well-formed non-negative
    # amount. Callers must treat nil as a validation failure, never as zero: a
    # silently zeroed price would put a product in the shop for free.
    def cents(value)
      text = value.to_s.strip.delete("$").delete(",")
      return nil unless text.match?(/\A\d+(\.\d{1,2})?\z/)

      (BigDecimal(text) * 100).round
    end
  end
end
