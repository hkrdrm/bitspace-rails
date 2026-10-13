module ShopHelper
  # "$12.00" when every variant costs the same, "From $12.00" when they differ.
  def price_label(product)
    low, high = product.price_range
    low == high ? price(low) : "From #{price(low)}"
  end

  # What the product page's picker needs, computed here so the JavaScript
  # never formats money or reads availability from the markup.
  def variant_picker_variants(product)
    product.variants.map do |variant|
      { id: variant.id, values: variant.option_values.map(&:id), price: price(variant.price_cents), stock: variant.stock }
    end
  end

  # Value id => photo URL, for the values that have their own photo.
  def variant_picker_images(product)
    product.options.flat_map(&:option_values).each_with_object({}) do |value, images|
      url = asset_url_if_exists(value.image)
      images[value.id] = url if url
    end
  end
end
