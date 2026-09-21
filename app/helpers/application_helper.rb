module ApplicationHelper
  # Money is stored as integer cents everywhere. This is the only place that
  # converts it for display.
  def price(cents)
    number_to_currency((cents || 0) / 100.0)
  end
end
