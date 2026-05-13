require "../spec_helper"
require "../../src/invidious/shorts"

{% unless @top_level.has_constant?(:HOST_URL) %}
  HOST_URL = "http://localhost:3000"
{% end %}

{% unless @top_level.has_constant?(:LOGGER) %}
  LOGGER = Invidious::LogHandler.new(File.open(File::NULL, "w"), LogLevel::Off)
{% end %}

private def shorts_search_video(id : String, is_short : Bool?) : SearchVideo
  SearchVideo.new({
    title:              "Video #{id}",
    id:                 id,
    author:             "Author",
    ucid:               "UC#{id}",
    published:          Time.utc(2026, 5, 12, 12, 0, 0),
    views:              100_i64,
    description_html:   "",
    length_seconds:     60,
    premiere_timestamp: nil,
    author_verified:    false,
    author_thumbnail:   nil,
    badges:             VideoBadges::None,
    is_short:           is_short,
  })
end

private def shorts_channel_video(id : String, is_short : Bool?) : ChannelVideo
  ChannelVideo.new({
    id:                 id,
    title:              "Video #{id}",
    published:          Time.utc(2026, 5, 12, 12, 0, 0),
    updated:            Time.utc(2026, 5, 12, 12, 0, 0),
    ucid:               "UC#{id}",
    author:             "Author",
    length_seconds:     60,
    live_now:           false,
    premiere_timestamp: nil,
    views:              100_i64,
    is_short:           is_short,
  })
end

private def shorts_search_channel(id : String) : SearchChannel
  SearchChannel.new({
    author:           "Channel #{id}",
    ucid:             "UC#{id}",
    author_thumbnail: "",
    subscriber_count: 100,
    video_count:      10,
    channel_handle:   nil,
    description_html: "",
    auto_generated:   false,
    author_verified:  false,
  })
end

Spectator.describe Invidious::Shorts do
  describe ".visible?" do
    it "keeps false and unknown videos visible" do
      expect(described_class.visible?(false)).to be_true
      expect(described_class.visible?(nil)).to be_true
    end

    it "hides only confirmed Shorts" do
      expect(described_class.visible?(true)).to be_false
    end
  end

  describe ".filter_channel_videos" do
    it "filters only confirmed Shorts when enabled" do
      videos = [
        shorts_channel_video("short", true),
        shorts_channel_video("normal", false),
        shorts_channel_video("unknown", nil),
      ]

      filtered = described_class.filter_channel_videos(videos, hide_shorts: true)

      expect(filtered.map(&.id)).to eq(["normal", "unknown"])
    end

    it "returns every video when disabled" do
      videos = [
        shorts_channel_video("short", true),
        shorts_channel_video("normal", false),
      ]

      filtered = described_class.filter_channel_videos(videos, hide_shorts: false)

      expect(filtered.map(&.id)).to eq(["short", "normal"])
    end
  end

  describe ".mark_from_shorts_tab" do
    it "marks only SearchVideo items as confirmed Shorts" do
      items = [shorts_search_video("short", nil)] of SearchItem

      marked = described_class.mark_from_shorts_tab(items)

      expect(marked.first.as(SearchVideo).is_short).to eq(true)
    end
  end

  describe ".mark_from_videos_tab" do
    it "marks unknown SearchVideo items as confirmed non-Shorts" do
      items = [shorts_search_video("normal", nil)] of SearchItem

      marked = described_class.mark_from_videos_tab(items)

      expect(marked.first.as(SearchVideo).is_short).to eq(false)
    end

    it "does not downgrade a confirmed Short to non-Short" do
      items = [shorts_search_video("short", true)] of SearchItem

      marked = described_class.mark_from_videos_tab(items)

      expect(marked.first.as(SearchVideo).is_short).to eq(true)
    end
  end
end

Spectator.describe Invidious::Shorts do
  describe ".filter_search_items" do
    it "filters confirmed Shorts and preserves unknown SearchVideos and non-video items" do
      items = [
        shorts_search_video("short", true),
        shorts_search_channel("channel"),
        shorts_search_video("unknown", nil),
        shorts_search_video("normal", false),
      ] of SearchItem

      filtered = described_class.filter_search_items(items, hide_shorts: true)

      labels = filtered.map do |item|
        case item
        when SearchVideo
          item.id
        when SearchChannel
          item.ucid
        else
          item.class.to_s
        end
      end

      expect(labels).to eq(["UCchannel", "unknown", "normal"])
    end
  end
end

Spectator.describe SearchVideo do
  it "defaults isShort to unknown when constructor omits is_short" do
    video = SearchVideo.new({
      title:              "Video legacy",
      id:                 "legacy",
      author:             "Author",
      ucid:               "UClegacy",
      published:          Time.utc(2026, 5, 12, 12, 0, 0),
      views:              100_i64,
      description_html:   "",
      length_seconds:     60,
      premiere_timestamp: nil,
      author_verified:    false,
      author_thumbnail:   nil,
      badges:             VideoBadges::None,
    })

    expect(video.is_short).to be_nil
  end

  it "serializes isShort as true, false, and null" do
    expect(JSON.parse(shorts_search_video("short", true).to_json("en-US", nil))["isShort"].as_bool).to be_true
    expect(JSON.parse(shorts_search_video("normal", false).to_json("en-US", nil))["isShort"].as_bool).to be_false
    expect(JSON.parse(shorts_search_video("unknown", nil).to_json("en-US", nil))["isShort"].raw).to be_nil
  end
end

Spectator.describe ChannelVideo do
  it "defaults isShort to unknown when constructor omits is_short" do
    video = ChannelVideo.new({
      id:                 "legacy",
      title:              "Video legacy",
      published:          Time.utc(2026, 5, 12, 12, 0, 0),
      updated:            Time.utc(2026, 5, 12, 12, 0, 0),
      ucid:               "UClegacy",
      author:             "Author",
      length_seconds:     60,
      live_now:           false,
      premiere_timestamp: nil,
      views:              100_i64,
    })

    expect(video.is_short).to be_nil
  end

  it "serializes a dedicated nullable isShort field without changing type" do
    json = JSON.parse(shorts_channel_video("short", true).to_json("en-US"))

    expect(json["type"].as_s).to eq("shortVideo")
    expect(json["isShort"].as_bool).to be_true
  end

  it "keeps isShort in the database tuple for the channel_videos schema" do
    video = shorts_channel_video("short", true)

    expect(ChannelVideo.type_array).to eq([
      "id",
      "title",
      "published",
      "updated",
      "ucid",
      "author",
      "length_seconds",
      "live_now",
      "premiere_timestamp",
      "views",
      "is_short",
    ])
    expect(video.to_tuple.size).to eq(11)
    expect(video.to_tuple).to eq({
      video.id,
      video.title,
      video.published,
      video.updated,
      video.ucid,
      video.author,
      video.length_seconds,
      video.live_now,
      video.premiere_timestamp,
      video.views,
      video.is_short,
    })
  end
end
