require "../spec_helper"
require "../../src/invidious/popular"

private def popular_video(
  id : String,
  ucid : String,
  published : Time,
  views : Int64?,
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
      expect(ranked.first.score.finite?).to be_true
      expect(ranked.first.score > 0.0).to be_true
    end

    it "does not let future published videos outrank normal candidates" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      future = Invidious::Popular::Candidate.new(
        video: popular_video("future", "UC1", now + 2.hours, 100_000_i64),
        local_subscription_count: 1000_i64,
        baseline_48h: 0.0,
        baseline_sample_count: 6_i64
      )
      normal = Invidious::Popular::Candidate.new(
        video: popular_video("normal", "UC2", now - 4.hours, 700_i64),
        local_subscription_count: 1000_i64,
        baseline_48h: 1200.0,
        baseline_sample_count: 6_i64
      )

      ranked = described_class.rank([future, normal], now)
      future_score = described_class.score(future, now)

      expect(future_score.finite?).to be_true
      expect(future_score).to eq(0.0)
      expect(ranked.first.video.id).to eq("normal")
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

    it "keeps nil views low and finite" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      candidate = Invidious::Popular::Candidate.new(
        video: popular_video("nil-views", "UC1", now - 6.hours, nil),
        local_subscription_count: 0_i64,
        baseline_48h: 0.0,
        baseline_sample_count: 0_i64
      )

      score = described_class.score(candidate, now)

      expect(score.finite?).to be_true
      expect(score >= 0.0).to be_true
      expect(score < 0.1).to be_true
    end

    it "keeps zero baselines conservative" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      video = popular_video("zero-baseline", "UC1", now - 2.hours, 4000_i64)
      zero_baseline = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 1000_i64,
        baseline_48h: 0.0,
        baseline_sample_count: 6_i64
      )
      known_baseline = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 1000_i64,
        baseline_48h: 4000.0,
        baseline_sample_count: 6_i64
      )

      zero_score = described_class.score(zero_baseline, now)
      known_score = described_class.score(known_baseline, now)

      expect(zero_score.finite?).to be_true
      expect(zero_score < known_score).to be_true
      expect(zero_score < 0.75).to be_true
    end
  end

  describe ".empty_cache" do
    it "has every supported range with independent empty arrays" do
      cache = described_class.empty_cache

      expect(cache.size).to eq(Invidious::Popular::RANGES.size)
      Invidious::Popular::RANGES.each do |range|
        expect(cache.has_key?(range)).to be_true
        expect(cache[range]).to be_empty
      end

      cache[Invidious::Popular::Range::Day] << popular_video("cached", "UC1", Time.utc(2026, 5, 10, 12, 0, 0), 1_i64)

      expect(cache[Invidious::Popular::Range::Day]).to_not be_empty
      expect(cache[Invidious::Popular::Range::Week]).to be_empty
      expect(cache[Invidious::Popular::Range::Day].object_id).to_not eq(cache[Invidious::Popular::Range::Week].object_id)
    end
  end

  describe Invidious::Popular::CandidateRow do
    it "preserves nullable views and baseline fields" do
      now = Time.utc(2026, 5, 10, 12, 0, 0)
      row = described_class.new({
        id:                       "row-video",
        title:                    "Video row-video",
        published:                now,
        updated:                  now,
        ucid:                     "UC1",
        author:                   "Channel UC1",
        length_seconds:           754,
        live_now:                 false,
        premiere_timestamp:       nil,
        views:                    nil,
        local_subscription_count: 17_i64,
        baseline_48h:             123.5,
        baseline_sample_count:    4_i64,
      })

      candidate = row.to_candidate

      expect(candidate.video.views).to be_nil
      expect(candidate.local_subscription_count).to eq(17_i64)
      expect(candidate.baseline_48h).to eq(123.5)
      expect(candidate.baseline_sample_count).to eq(4_i64)
    end
  end
end
