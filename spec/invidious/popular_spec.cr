require "../spec_helper"
require "../../src/invidious/popular"

private def popular_video(
  id : String,
  ucid : String,
  published : Time,
  views : Int64,
  length_seconds : Int32 = 754,
) : ChannelVideo
  ChannelVideo.new({
    id:                 id,
    title:              "Video #{id}",
    published:          published,
    updated:            published,
    ucid:               ucid,
    author:             "Channel #{ucid}",
    length_seconds:     length_seconds,
    live_now:           false,
    premiere_timestamp: nil,
    views:              views,
  })
end

Spectator.describe Invidious::Popular do
  describe Invidious::Popular::Range do
    it "exposes range metadata in display order" do
      ranges = Invidious::Popular::RANGES

      expect(ranges.map(&.key)).to eq({"day", "week", "twoweeks", "month"})
      expect(ranges.map(&.label_key)).to eq({
        "popular_range_day",
        "popular_range_week",
        "popular_range_twoweeks",
        "popular_range_month",
      })
      expect(ranges.map(&.days)).to eq({2, 7, 14, 30})
      expect(Invidious::Popular::Range::Month.span).to eq(30.days)
    end
  end

  describe ".parse_range" do
    it "defaults nil and invalid values to day" do
      expect(described_class.parse_range(nil)).to eq(Invidious::Popular::Range::Day)
      expect(described_class.parse_range("invalid")).to eq(Invidious::Popular::Range::Day)
    end

    it "parses supported range keys" do
      expect(described_class.parse_range("day")).to eq(Invidious::Popular::Range::Day)
      expect(described_class.parse_range("week")).to eq(Invidious::Popular::Range::Week)
      expect(described_class.parse_range("twoweeks")).to eq(Invidious::Popular::Range::TwoWeeks)
      expect(described_class.parse_range("two_weeks")).to eq(Invidious::Popular::Range::TwoWeeks)
      expect(described_class.parse_range("2-weeks")).to eq(Invidious::Popular::Range::TwoWeeks)
      expect(described_class.parse_range("month")).to eq(Invidious::Popular::Range::Month)
    end
  end

  describe ".rank" do
    it "lets an early breakout outrank an older high-view video" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      early = Invidious::Popular::Candidate.new(
        video: popular_video("early-breakout", "UC1", now - 2.hours, 600_i64),
        local_subscription_count: 500_i64,
        baseline_48h: 2000.0,
        baseline_sample_count: 6_i64
      )
      older = Invidious::Popular::Candidate.new(
        video: popular_video("older-high-view", "UC2", now - 36.hours, 5000_i64),
        local_subscription_count: 1000_i64,
        baseline_48h: 7000.0,
        baseline_sample_count: 6_i64
      )

      ranked = described_class.rank([older, early], now)

      expect(ranked.first.video.id).to eq("early-breakout")
    end

    it "keeps a strong older month-window outlier competitive" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      outlier = Invidious::Popular::Candidate.new(
        video: popular_video("month-outlier", "UC1", now - 20.days, 200_000_i64),
        local_subscription_count: 12_000_i64,
        baseline_48h: 10_000.0,
        baseline_sample_count: 8_i64
      )
      recent = Invidious::Popular::Candidate.new(
        video: popular_video("recent-solid", "UC2", now - 3.hours, 1500_i64),
        local_subscription_count: 1000_i64,
        baseline_48h: 2000.0,
        baseline_sample_count: 8_i64
      )

      ranked = described_class.rank([recent, outlier], now)

      expect(ranked.first.video.id).to eq("month-outlier")
      expect(ranked.first.score > 0.9).to be_true
    end
  end

  describe ".score" do
    it "penalizes sparse baselines without dropping the video" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      video = popular_video("sparse-baseline", "UC1", now - 24.hours, 1000_i64)
      sparse = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 500_i64,
        baseline_48h: 1500.0,
        baseline_sample_count: 1_i64
      )
      confident = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 500_i64,
        baseline_48h: 1500.0,
        baseline_sample_count: 5_i64
      )

      sparse_score = described_class.score(sparse, now)
      confident_score = described_class.score(confident, now)

      expect(sparse_score > 0.0).to be_true
      expect(sparse_score < confident_score).to be_true
    end
  end
end
