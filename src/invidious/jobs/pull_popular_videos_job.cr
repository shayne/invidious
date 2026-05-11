class Invidious::Jobs::PullPopularVideosJob < Invidious::Jobs::BaseJob
  POPULAR_VIDEOS = Atomic.new(Invidious::Popular.empty_cache)
  private getter db : DB::Database

  def initialize(@db)
  end

  def begin
    loop do
      cache = Invidious::Popular.empty_cache

      Invidious::Popular::RANGES.each do |range|
        candidates = Invidious::Database::ChannelVideos.select_popular_candidates(range)
        ranked = Invidious::Popular.rank(candidates)
        cache[range] = ranked.first(MAX_ITEMS_PER_PAGE).map(&.video)
      end

      POPULAR_VIDEOS.set(cache)

      sleep 1.minute
      Fiber.yield
    end
  end
end
