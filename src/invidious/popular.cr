require "./channels/channels"

module Invidious::Popular
  enum Range
    Day
    Week
    TwoWeeks
    Month

    def key : String
      case self
      when .day?       then "day"
      when .week?      then "week"
      when .two_weeks? then "twoweeks"
      when .month?     then "month"
      else                  raise "Unhandled popular range: #{self}"
      end
    end

    def label_key : String
      case self
      when .day?       then "popular_range_day"
      when .week?      then "popular_range_week"
      when .two_weeks? then "popular_range_twoweeks"
      when .month?     then "popular_range_month"
      else                  raise "Unhandled popular range: #{self}"
      end
    end

    def days : Int32
      case self
      when .day?       then 2
      when .week?      then 7
      when .two_weeks? then 14
      when .month?     then 30
      else                  raise "Unhandled popular range: #{self}"
      end
    end

    def span : Time::Span
      days.days
    end
  end

  RANGES = {Range::Day, Range::Week, Range::TwoWeeks, Range::Month}

  struct Candidate
    property video : ChannelVideo
    property local_subscription_count : Int64
    property baseline_48h : Float64
    property baseline_sample_count : Int64

    def initialize(
      *,
      @video : ChannelVideo,
      @local_subscription_count : Int64,
      @baseline_48h : Float64,
      @baseline_sample_count : Int64,
    )
    end
  end

  struct RankedVideo
    property video : ChannelVideo
    property score : Float64

    def initialize(*, @video : ChannelVideo, @score : Float64)
    end
  end

  struct CandidateRow
    include DB::Serializable

    property id : String
    property title : String
    property published : Time
    property updated : Time
    property ucid : String
    property author : String
    property length_seconds : Int32 = 0
    property live_now : Bool = false
    property premiere_timestamp : Time? = nil
    property views : Int64? = nil
    property local_subscription_count : Int64
    property baseline_48h : Float64
    property baseline_sample_count : Int64

    def to_candidate : Candidate
      Candidate.new(
        video: ChannelVideo.new({
          id:                 @id,
          title:              @title,
          published:          @published,
          updated:            @updated,
          ucid:               @ucid,
          author:             @author,
          length_seconds:     @length_seconds,
          live_now:           @live_now,
          premiere_timestamp: @premiere_timestamp,
          views:              @views,
        }),
        local_subscription_count: @local_subscription_count,
        baseline_48h: @baseline_48h,
        baseline_sample_count: @baseline_sample_count
      )
    end
  end

  def self.parse_range(value : String?) : Range
    case value.try(&.downcase)
    when "week"
      Range::Week
    when "twoweeks", "two_weeks", "two-weeks", "2weeks", "2-weeks"
      Range::TwoWeeks
    when "month"
      Range::Month
    else
      Range::Day
    end
  end

  def self.empty_cache : Hash(Range, Array(ChannelVideo))
    cache = {} of Range => Array(ChannelVideo)
    RANGES.each do |range|
      cache[range] = [] of ChannelVideo
    end
    cache
  end

  def self.score(candidate : Candidate, now : Time = Time.utc) : Float64
    current_views = candidate.video.views || 0_i64
    age_seconds = (now - candidate.video.published).total_seconds
    return 0.0 if age_seconds < 0.0

    age_hours = age_seconds / 3600.0
    baseline_48h = effective_baseline_48h(candidate.baseline_48h, current_views, age_hours)

    relative_nowcast = current_views.to_f / Math.max(1.0, baseline_48h * age_curve_fraction_48h(age_hours))
    velocity_shock = (current_views.to_f / Math.max(age_hours, 1.0)) /
                     Math.max(1.0, baseline_48h * age_curve_expected_slope(age_hours))
    instance_reach = current_views.to_f / Math.max(candidate.local_subscription_count, 1_i64).to_f

    base_score = 0.55 * norm_ratio(relative_nowcast) +
                 0.20 * norm_ratio(velocity_shock) +
                 0.15 * norm_reach(instance_reach) +
                 0.05 * duration_prior(candidate.video.length_seconds)

    base_score * confidence_multiplier(current_views, candidate.baseline_sample_count) +
      early_breakout_boost(age_hours, relative_nowcast, velocity_shock)
  end

  def self.rank(candidates : Array(Candidate), now : Time = Time.utc) : Array(RankedVideo)
    candidates
      .map { |candidate| RankedVideo.new(video: candidate.video, score: score(candidate, now)) }
      .sort do |left, right|
        score_cmp = right.score <=> left.score
        score_cmp == 0 ? right.video.published <=> left.video.published : score_cmp
      end
  end

  private def self.effective_baseline_48h(baseline_48h : Float64, current_views : Int64, age_hours : Float64) : Float64
    return baseline_48h if baseline_48h > 0.0
    return 1.0 if current_views <= 0

    projected_48h = current_views.to_f * (48.0 / Math.max(age_hours, 1.0))
    Math.max(Math.max(projected_48h, current_views.to_f), 1.0)
  end

  private def self.age_curve_fraction_48h(age_hours : Float64) : Float64
    if age_hours <= 0.0
      0.03
    elsif age_hours <= 8.0
      (0.6 * (age_hours / 8.0)).clamp(0.03, 0.6)
    elsif age_hours < 48.0
      0.6 + 0.35 * ((age_hours - 8.0) / 40.0)
    else
      0.95
    end
  end

  private def self.age_curve_expected_slope(age_hours : Float64) : Float64
    if age_hours <= 8.0
      0.075
    elsif age_hours < 48.0
      0.00875
    else
      0.001
    end
  end

  private def self.duration_prior(length_seconds : Int32) : Float64
    if length_seconds <= 0
      0.5
    elsif length_seconds < 120
      0.35
    elsif length_seconds < 600
      0.6
    elsif length_seconds < 1800
      1.0
    elsif length_seconds < 3600
      0.7
    else
      0.5
    end
  end

  private def self.norm_ratio(value : Float64, cap : Float64 = 6.0) : Float64
    return 0.0 if value <= 0.0

    (Math.log1p(value) / Math.log1p(cap)).clamp(0.0, 1.0)
  end

  private def self.norm_reach(reach : Float64) : Float64
    return 0.0 if reach <= 0.0

    Math.sqrt(reach * 10.0).clamp(0.0, 1.0)
  end

  private def self.confidence_multiplier(current_views : Int64, sample_count : Int64) : Float64
    multiplier =
      if sample_count >= 5
        1.05
      elsif sample_count >= 2
        0.95
      else
        0.82
      end

    multiplier -= 0.07 if current_views <= 0
    multiplier.clamp(0.75, 1.05)
  end

  private def self.early_breakout_boost(age_hours : Float64, relative_nowcast : Float64, velocity_shock : Float64) : Float64
    return 0.0 if age_hours > 6.0
    return 0.0 if relative_nowcast < 1.2 || velocity_shock < 1.2

    (0.03 * Math.log1p(relative_nowcast * velocity_shock)).clamp(0.0, 0.12)
  end
end
