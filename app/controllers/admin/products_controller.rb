module Admin
  class ProductsController < BaseController
    def index
      @products = Product.order(:name).eager(:variants, options: :option_values).all
    end

    def new
      source = Product[params[:copy_from].to_i] if params[:copy_from].present?
      @editor = ProductEditor.blank(copy_from: source)
      @copy_sources = copy_sources
    end

    def create
      @editor = ProductEditor.new(Product.new, editor_params)

      unless @editor.save
        @copy_sources = copy_sources
        return render :new, status: :unprocessable_entity
      end

      product = @editor.product
      if product.simple?
        redirect_to admin_products_path, notice: "#{product.name} created."
      else
        redirect_to edit_admin_product_path(product.id),
          notice: "#{product.name} created with #{helpers.pluralize(product.variants.size, 'variant')}. Set stock below."
      end
    end

    def edit
      @editor = ProductEditor.from_product(find_product!)
    end

    def update
      @editor = ProductEditor.new(find_product!, editor_params)
      return render :edit, status: :unprocessable_entity unless @editor.save

      product = @editor.product
      if @editor.variants_changed?
        redirect_to edit_admin_product_path(product.id), notice: "#{product.name} saved. Its variants changed, so check stock below."
      else
        redirect_to admin_products_path, notice: "#{product.name} updated."
      end
    end

    def destroy
      product = find_product!
      name = product.name
      product.destroy

      redirect_to admin_products_path, notice: "#{name} deleted."
    end

    private

    # A 404 rather than a redirect, matching how the admin gate hides itself.
    # Options, values and each variant's values are loaded up front: the form
    # labels every variant, and lazy loading would cost a round trip per row.
    def find_product!
      Product.where(id: params[:id].to_i)
        .eager(options: :option_values, variants: :option_values)
        .all.first or raise ActionController::RoutingError, "Not Found"
    end

    def copy_sources
      Product.order(:name).select_map([ :id, :name ])
    end

    # ProductEditor reads every key it uses by name and never mass-assigns, so
    # handing it the raw hash is safe. Only the keys the form sends pass.
    def editor_params
      params.to_unsafe_h.slice("product", "options", "variants", "confirm_loss", "confirmed_loss", "simple_stock")
    end
  end
end
