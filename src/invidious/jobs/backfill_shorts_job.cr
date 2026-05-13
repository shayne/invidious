class Invidious::Jobs::BackfillShortsJob < Invidious::Jobs::BaseJob
  CHANNEL_BATCH_SIZE = 10
  PAGE_LIMIT         = 2
  CHANNEL_SLEEP      = 2.seconds
  IDLE_SLEEP         = 1.hour

  def begin
    loop do
      channel_ids = Invidious::Database::ChannelVideos.select_unclassified_shorts_channels(CHANNEL_BATCH_SIZE)

      channel_ids.each do |ucid|
        backfill_channel(ucid)
        sleep CHANNEL_SLEEP
      end

      sleep IDLE_SLEEP
      Fiber.yield
    end
  end

  private def backfill_channel(ucid : String) : Nil
    channel = get_about_info(ucid, CONFIG.default_user_preferences.locale)

    short_ids = collect_tab_video_ids(channel, shorts: true)
    Invidious::Database::ChannelVideos.mark_shorts(short_ids)

    non_short_ids = collect_tab_video_ids(channel, shorts: false)
    Invidious::Database::ChannelVideos.mark_non_shorts(non_short_ids)
  rescue ex
    LOGGER.error("BackfillShortsJob: #{ucid} : #{ex.message}")
  end

  private def collect_tab_video_ids(channel : AboutChannel, *, shorts : Bool) : Array(String)
    ids = [] of String
    continuation = nil

    PAGE_LIMIT.times do
      items, continuation =
        if shorts
          Channel::Tabs.get_shorts(channel.as(AboutChannel), continuation: continuation)
        else
          Channel::Tabs.get_videos(channel, continuation: continuation)
        end

      items.select(SearchVideo).each do |video|
        ids << video.id
      end

      break if continuation.nil?
    end

    ids.uniq!
    ids
  end
end
