module ApplicationHelper
  # Money is stored as integer cents everywhere. This is the only place that
  # converts it for display.
  def price(cents)
    number_to_currency((cents || 0) / 100.0)
  end

  # Renders a product's image, or nil (the caller's existing empty placeholder
  # box) when the filename does not resolve. Product#validate rejects a bad
  # filename at save time, but a file can still disappear from disk later, so
  # every render site must guard rather than call image_tag directly.
  def product_image_tag(product, **options)
    return nil unless product.image.present?
    return nil unless Rails.application.assets.load_path.find(product.image)

    image_tag(product.image, **options)
  end
end
