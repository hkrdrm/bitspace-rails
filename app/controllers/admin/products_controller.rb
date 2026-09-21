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
    end

    def update
    end

    def destroy
    end

    private

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

    def cents(value)
      digits = value.to_s.gsub(/[^0-9.]/, "")
      return 0 if digits.blank?

      (BigDecimal(digits) * 100).round
    rescue ArgumentError
      0
    end
  end
end
