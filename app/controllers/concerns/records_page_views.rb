module RecordsPageViews
  extend ActiveSupport::Concern

  BOT_PATTERN = /
    bot|crawl|spider|slurp|bingpreview|facebookexternalhit|
    headless|curl|wget|python-requests|scrapy|monitor
  /xi

  # The health check fires constantly and would swamp the table.
  SKIP_PATHS = [ "/up" ].freeze

  included do
    after_action :record_page_view
  end

  private

  def record_page_view
    return unless request.get?
    return unless request.format.html?
    return if SKIP_PATHS.include?(request.path)

    PageView.create(
      path: request.path,
      ip: request.remote_ip,
      user_agent: request.user_agent,
      bot: bot_user_agent?(request.user_agent),
      account_id: current_account&.id,
      created_at: Time.current
    )
  rescue StandardError => e
    # Analytics must never take a page down with it.
    Rails.logger.warn("page view not recorded: #{e.class}: #{e.message}")
  end

  def bot_user_agent?(user_agent)
    return false if user_agent.blank?

    BOT_PATTERN.match?(user_agent)
  end
end
