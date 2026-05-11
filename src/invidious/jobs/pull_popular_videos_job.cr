class Invidious::Jobs::PullPopularVideosJob < Invidious::Jobs::BaseJob
  POPULAR_VIDEOS = Atomic.new(Invidious::Popular.empty_cache)
  MAX_RANGE      = Invidious::Popular::Range::Month
  private getter db : DB::Database

  def initialize(@db)
  end

  def begin
    loop do
      cache = Invidious::Popular.empty_cache
      now = Time.utc
      candidates = Invidious::Database::ChannelVideos.select_popular_candidates(MAX_RANGE)

      Invidious::Popular::RANGES.each do |range|
        filtered = Invidious::Popular.filter_candidates(candidates, range, now: now)
        ranked = Invidious::Popular.rank(filtered, now)
        cache[range] = ranked.first(MAX_ITEMS_PER_PAGE).map(&.video)
      end

      POPULAR_VIDEOS.set(cache)

      sleep 1.minute
      Fiber.yield
    end
  end
end
