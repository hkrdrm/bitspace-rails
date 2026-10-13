module ApplicationHelper
  # Money is stored as integer cents everywhere. This is the only place that
  # converts it for display.
  def price(cents)
    number_to_currency((cents || 0) / 100.0)
  end

  # The served URL for a filename under app/assets/images, or nil when no such
  # file exists. Every render site guards this way rather than calling
  # image_tag directly: Propshaft raises on a missing asset, and a file can
  # disappear after a product was saved.
  def asset_url_if_exists(filename)
    return nil if filename.blank? || !Product.asset_exists?(filename)

    asset_path(filename)
  end

  # Renders a product's image, or nil (the caller's empty placeholder box)
  # when the filename does not resolve.
  def product_image_tag(product, **options)
    return nil unless asset_url_if_exists(product.image)

    image_tag(product.image, **options)
  end

  IMAGE_EXTENSIONS = /\.(png|jpe?g|gif|webp|svg)\z/i

  # Every image the admin may name, mapped to its served URL, for the filename
  # field's live preview. The URL has to come from asset_path rather than being
  # assembled in JavaScript: in production Propshaft precompiles only digested
  # filenames and does not mount the middleware that resolves plain ones, so a
  # guessed "/assets/<name>" would 404 for every image and the preview would
  # silently never appear.
  def product_image_sources
    Rails.application.assets.load_path.assets
      .map { |asset| asset.logical_path.to_s }
      .select { |path| path.match?(IMAGE_EXTENSIONS) }
      .sort
      .to_h { |path| [ path, asset_path(path) ] }
  end
end
