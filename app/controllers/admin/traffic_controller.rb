module Admin
  class TrafficController < BaseController
    WINDOW = 7

    def index
      since = WINDOW.days.ago

      recent = PageView.where { created_at >= since }

      @total   = recent.count
      @humans  = recent.where(bot: false).count
      @bots    = recent.where(bot: true).count
      @unique_ips = recent.distinct.select_map(:ip).compact.size

      @by_day = recent
        .select { [ Sequel.function(:date, :created_at).as(:day), bot, Sequel.function(:count, Sequel.lit("*")).as(:views) ] }
        .group(Sequel.function(:date, :created_at), :bot)
        .order(Sequel.desc(:day))
        .all

      @top_paths  = top(recent, :path)
      @top_ips    = top(recent, :ip)
      @top_agents = top(recent, :user_agent)
    end

    private

    def top(dataset, column, limit: 8)
      dataset
        .select { [ column, Sequel.function(:count, Sequel.lit("*")).as(:views) ] }
        .exclude(column => nil)
        .group(column)
        .order(Sequel.desc(:views))
        .limit(limit)
        .all
    end
  end
end
