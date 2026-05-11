# Invidious Popular Nowcast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Invidious Popular's publish-date list with an instance-wide, range-aware nowcast ranking based on all locally subscribed channels.

**Architecture:** Add a focused `Invidious::Popular` module for range parsing, candidate structs, score math, and ranking. Add one database selection method that gathers candidate videos from all channels in the local subscription graph, then update the Popular cache job, web route, API route, and template to use range-specific ranked caches.

**Tech Stack:** Crystal, Spectator specs, PostgreSQL through crystal-pg, Kemal route handlers, ECR templates.

---

## File Structure

- Create `src/invidious/popular.cr`: owns range parsing, range labels, candidate models, scoring math, and pure ranking.
- Create `spec/invidious/popular_spec.cr`: tests range parsing and nowcast ranking behavior without a database.
- Create `spec/invidious/popular_database_spec.cr`: tests the database query builder shape so the old top-40 cutoff cannot return.
- Modify `src/invidious/database/channels.cr`: add Popular candidate query and conversion to `Invidious::Popular::Candidate`.
- Modify `src/invidious/jobs/pull_popular_videos_job.cr`: refresh range-aware Popular caches.
- Modify `src/invidious.cr`: change `popular_videos` to accept a range.
- Modify `src/invidious/routes/feeds.cr`: parse `range=` and expose `popular_range`/`popular_range_options` to the template.
- Modify `src/invidious/routes/api/v1/feeds.cr`: parse `range=` and return the ranked list for that range.
- Modify `src/invidious/views/feeds/popular.ecr`: add the selector row and render the local `popular_videos`.
- Modify `locales/en-US.json`: add English labels for the range selector.

## Task 1: Core Popular Range And Scoring

**Files:**
- Create: `src/invidious/popular.cr`
- Create: `spec/invidious/popular_spec.cr`

- [ ] **Step 1: Write the failing range and scorer specs**

Create `spec/invidious/popular_spec.cr`:

```crystal
require "../spec_helper"
require "../../src/invidious/popular"

private def popular_video(
  id : String,
  ucid : String,
  published : Time,
  views : Int64,
  length_seconds : Int32 = 754
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
  describe ".parse_range" do
    it "defaults missing and invalid values to day" do
      expect(described_class.parse_range(nil)).to eq(Invidious::Popular::Range::Day)
      expect(described_class.parse_range("nonsense")).to eq(Invidious::Popular::Range::Day)
    end

    it "parses supported range values" do
      expect(described_class.parse_range("day")).to eq(Invidious::Popular::Range::Day)
      expect(described_class.parse_range("week")).to eq(Invidious::Popular::Range::Week)
      expect(described_class.parse_range("twoweeks")).to eq(Invidious::Popular::Range::TwoWeeks)
      expect(described_class.parse_range("month")).to eq(Invidious::Popular::Range::Month)
    end
  end

  describe ".rank" do
    it "lets an early breakout outrank an older high-view video" do
      now = Time.utc(2026, 5, 11, 12, 0, 0)

      breakout = Invidious::Popular::Candidate.new(
        video: popular_video("breakout", "UCBREAKOUT", now - 2.hours, 18_000_i64),
        local_subscription_count: 80_i64,
        baseline_48h: 20_000.0,
        baseline_sample_count: 8_i64
      )

      steady = Invidious::Popular::Candidate.new(
        video: popular_video("steady", "UCSTEADY", now - 24.hours, 280_000_i64),
        local_subscription_count: 5_000_i64,
        baseline_48h: 350_000.0,
        baseline_sample_count: 10_i64
      )

      ranked = described_class.rank([steady, breakout], now: now)

      expect(ranked.first.video.id).to eq("breakout")
      expect(ranked.first.score).to be > ranked.last.score
    end

    it "keeps strong older videos competitive inside wider windows" do
      now = Time.utc(2026, 5, 11, 12, 0, 0)

      recent = Invidious::Popular::Candidate.new(
        video: popular_video("recent", "UCRECENT", now - 18.hours, 55_000_i64),
        local_subscription_count: 300_i64,
        baseline_48h: 90_000.0,
        baseline_sample_count: 6_i64
      )

      month_outlier = Invidious::Popular::Candidate.new(
        video: popular_video("month-outlier", "UCMONTH", now - 29.days, 3_500_000_i64),
        local_subscription_count: 300_i64,
        baseline_48h: 90_000.0,
        baseline_sample_count: 6_i64
      )

      ranked = described_class.rank([recent, month_outlier], now: now)

      expect(ranked.first.video.id).to eq("month-outlier")
    end

    it "penalizes sparse baselines without dropping the video" do
      now = Time.utc(2026, 5, 11, 12, 0, 0)
      video = popular_video("sparse", "UCSPARSE", now - 5.hours, 30_000_i64)

      sparse = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 100_i64,
        baseline_48h: 25_000.0,
        baseline_sample_count: 0_i64
      )

      rich = Invidious::Popular::Candidate.new(
        video: video,
        local_subscription_count: 100_i64,
        baseline_48h: 25_000.0,
        baseline_sample_count: 8_i64
      )

      expect(described_class.score(sparse, now: now)).to be < described_class.score(rich, now: now)
      expect(described_class.score(sparse, now: now)).to be > 0.0
    end
  end
end
```

- [ ] **Step 2: Run the focused spec and verify it fails**

Run:

```bash
crystal spec spec/invidious/popular_spec.cr
```

Expected: fail because `src/invidious/popular.cr` does not exist or `Invidious::Popular` is undefined.

- [ ] **Step 3: Implement the Popular module**

Create `src/invidious/popular.cr`:

```crystal
module Invidious::Popular
  enum Range
    Day
    Week
    TwoWeeks
    Month

    def key : String
      case self
      when Invidious::Popular::Range::Week
        "week"
      when Invidious::Popular::Range::TwoWeeks
        "twoweeks"
      when Invidious::Popular::Range::Month
        "month"
      else
        "day"
      end
    end

    def label_key : String
      case self
      when Invidious::Popular::Range::Week
        "popular_range_week"
      when Invidious::Popular::Range::TwoWeeks
        "popular_range_twoweeks"
      when Invidious::Popular::Range::Month
        "popular_range_month"
      else
        "popular_range_day"
      end
    end

    def days : Int32
      case self
      when Invidious::Popular::Range::Week
        7
      when Invidious::Popular::Range::TwoWeeks
        14
      when Invidious::Popular::Range::Month
        30
      else
        2
      end
    end

    def span : Time::Span
      days.days
    end
  end

  RANGES = {
    Range::Day,
    Range::Week,
    Range::TwoWeeks,
    Range::Month,
  }

  struct Candidate
    getter video : ChannelVideo
    getter local_subscription_count : Int64
    getter baseline_48h : Float64
    getter baseline_sample_count : Int64

    def initialize(
      @video : ChannelVideo,
      @local_subscription_count : Int64,
      @baseline_48h : Float64,
      @baseline_sample_count : Int64
    )
    end
  end

  struct RankedVideo
    getter video : ChannelVideo
    getter score : Float64

    def initialize(@video : ChannelVideo, @score : Float64)
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
      video = ChannelVideo.new({
        id:                 id,
        title:              title,
        published:          published,
        updated:            updated,
        ucid:               ucid,
        author:             author,
        length_seconds:     length_seconds,
        live_now:           live_now,
        premiere_timestamp: premiere_timestamp,
        views:              views,
      })

      Candidate.new(
        video: video,
        local_subscription_count: local_subscription_count,
        baseline_48h: baseline_48h,
        baseline_sample_count: baseline_sample_count
      )
    end
  end

  def self.parse_range(value : String?) : Range
    case value.try &.downcase
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
    RANGES.each { |range| cache[range] = [] of ChannelVideo }
    cache
  end

  def self.age_curve_fraction_48h(age_hours : Float64) : Float64
    if age_hours <= 0.0
      0.03
    elsif age_hours <= 8.0
      clamp(0.6 * (age_hours / 8.0), 0.03, 0.6)
    elsif age_hours < 48.0
      0.6 + 0.35 * ((age_hours - 8.0) / 40.0)
    else
      0.95
    end
  end

  def self.age_curve_expected_slope(age_hours : Float64) : Float64
    if age_hours <= 8.0
      0.075
    elsif age_hours < 48.0
      0.00875
    else
      0.001
    end
  end

  def self.duration_prior(duration_seconds : Int32) : Float64
    return 0.5 if duration_seconds <= 0
    return 0.35 if duration_seconds < 120
    return 0.6 if duration_seconds < 600
    return 1.0 if duration_seconds < 1800
    return 0.7 if duration_seconds < 3600
    0.5
  end

  def self.score(candidate : Candidate, now : Time = Time.utc) : Float64
    current_views = candidate.video.views || 0_i64
    age_hours = ((now - candidate.video.published).total_seconds / 3600.0)
    age_hours = 0.0 if age_hours < 0.0

    baseline_48h = candidate.baseline_48h
    baseline_48h = current_views > 0 ? current_views.to_f : 1.0 if baseline_48h <= 0.0

    expected_fraction = age_curve_fraction_48h(age_hours)
    expected_views_now = max_float(1.0, baseline_48h * expected_fraction)
    relative_nowcast = current_views.to_f / expected_views_now

    expected_vph = max_float(1.0, baseline_48h * age_curve_expected_slope(age_hours))
    views_per_hour = current_views.to_f / max_float(age_hours, 1.0)
    velocity_shock = views_per_hour / expected_vph

    instance_reach = current_views.to_f / max_float(candidate.local_subscription_count.to_f, 1.0)
    base_score =
      0.55 * norm_ratio(relative_nowcast) +
      0.20 * norm_ratio(velocity_shock) +
      0.15 * norm_reach(instance_reach) +
      0.05 * duration_prior(candidate.video.length_seconds)

    confidence = confidence_multiplier(candidate.baseline_sample_count, current_views)
    (base_score * confidence) + early_breakout_boost(age_hours, relative_nowcast, velocity_shock)
  end

  def self.rank(candidates : Array(Candidate), now : Time = Time.utc) : Array(RankedVideo)
    candidates
      .map { |candidate| RankedVideo.new(candidate.video, score(candidate, now: now)) }
      .sort_by { |ranked| {ranked.score, ranked.video.published} }
      .reverse!
  end

  private def self.confidence_multiplier(baseline_sample_count : Int64, current_views : Int64) : Float64
    confidence =
      if baseline_sample_count >= 5
        1.05
      elsif baseline_sample_count >= 2
        0.95
      else
        0.82
      end

    confidence -= 0.07 if current_views <= 0
    clamp(confidence, 0.75, 1.05)
  end

  private def self.early_breakout_boost(age_hours : Float64, relative_nowcast : Float64, velocity_shock : Float64) : Float64
    return 0.0 if age_hours > 6.0
    return 0.0 if relative_nowcast < 1.2 || velocity_shock < 1.2

    clamp(0.03 * Math.log1p(relative_nowcast * velocity_shock), 0.0, 0.12)
  end

  private def self.norm_ratio(value : Float64, cap : Float64 = 6.0) : Float64
    return 0.0 if value <= 0.0
    clamp(Math.log1p(value) / Math.log1p(cap), 0.0, 1.0)
  end

  private def self.norm_reach(reach : Float64) : Float64
    return 0.0 if reach <= 0.0
    clamp(Math.sqrt(reach * 10.0), 0.0, 1.0)
  end

  private def self.clamp(value : Float64, lower : Float64, upper : Float64) : Float64
    return lower if value < lower
    return upper if value > upper
    value
  end

  private def self.max_float(left : Float64, right : Float64) : Float64
    left > right ? left : right
  end
end
```

- [ ] **Step 4: Run the focused spec and verify it passes**

Run:

```bash
crystal spec spec/invidious/popular_spec.cr
```

Expected: all examples in `spec/invidious/popular_spec.cr` pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add src/invidious/popular.cr spec/invidious/popular_spec.cr
git commit -m "feat: add popular nowcast scorer"
```

## Task 2: Select Popular Candidates From All Subscribed Channels

**Files:**
- Modify: `src/invidious/database/channels.cr`
- Create: `spec/invidious/popular_database_spec.cr`

- [ ] **Step 1: Write the failing query-shape spec**

Create `spec/invidious/popular_database_spec.cr`:

```crystal
require "../spec_helper"
require "../../src/invidious/database/channels"
require "../../src/invidious/popular"

Spectator.describe Invidious::Database::ChannelVideos do
  describe ".popular_candidates_query" do
    it "uses all channels in the local subscription graph" do
      query = described_class.popular_candidates_query

      expect(query.includes?("UNNEST(subscriptions)")).to be_true
      expect(query.includes?("GROUP BY channel")).to be_true
      expect(query.includes?("COUNT(*)")).to be_true
    end

    it "does not keep the old top-40 channel cutoff" do
      query = described_class.popular_candidates_query

      expect(query.includes?("LIMIT 40")).to be_false
      expect(query.includes?("ORDER BY COUNT(channel) DESC LIMIT")).to be_false
    end

    it "bounds candidates by the selected publish window before ranking" do
      query = described_class.popular_candidates_query

      expect(query.includes?("cv.published >= now() - ($1::interval)")).to be_true
    end
  end
end
```

- [ ] **Step 2: Run the database spec and verify it fails**

Run:

```bash
crystal spec spec/invidious/popular_database_spec.cr
```

Expected: fail because `popular_candidates_query` is undefined.

- [ ] **Step 3: Add the query builder and candidate selector**

In `src/invidious/database/channels.cr`, replace `select_popular_videos` with:

```crystal
  def popular_candidates_query : String
    <<-SQL
      WITH subscribed_channels AS (
        SELECT channel AS ucid, COUNT(*) AS local_subscription_count
        FROM (
          SELECT UNNEST(subscriptions) AS channel
          FROM users
        ) AS local_subscriptions
        WHERE channel IS NOT NULL AND channel != ''
        GROUP BY channel
      )
      SELECT
        cv.id,
        cv.title,
        cv.published,
        cv.updated,
        cv.ucid,
        cv.author,
        cv.length_seconds,
        cv.live_now,
        cv.premiere_timestamp,
        cv.views,
        sc.local_subscription_count,
        COALESCE(baseline.baseline_48h, NULLIF(cv.views, 0), 1)::float8 AS baseline_48h,
        COALESCE(baseline.sample_count, 0)::bigint AS baseline_sample_count
      FROM channel_videos cv
      JOIN subscribed_channels sc ON sc.ucid = cv.ucid
      LEFT JOIN LATERAL (
        SELECT AVG(sample.views)::float8 AS baseline_48h,
               COUNT(*)::bigint AS sample_count
        FROM (
          SELECT cv2.views
          FROM channel_videos cv2
          WHERE cv2.ucid = cv.ucid
            AND cv2.id != cv.id
            AND cv2.views IS NOT NULL
            AND cv2.views > 0
            AND cv2.published < now() - interval '48 hours'
            AND cv2.published >= now() - interval '180 days'
          ORDER BY cv2.published DESC
          LIMIT 20
        ) sample
      ) baseline ON true
      WHERE cv.published >= now() - ($1::interval)
        AND cv.published <= now()
      ORDER BY cv.published DESC
    SQL
  end

  def select_popular_candidates(range : Invidious::Popular::Range) : Array(Invidious::Popular::Candidate)
    interval = "#{range.days} days"

    rows = PG_DB.query_all(
      popular_candidates_query,
      interval,
      as: Invidious::Popular::CandidateRow
    )

    rows.map(&.to_candidate)
  end
```

Keep the method inside `module Invidious::Database::ChannelVideos`.

- [ ] **Step 4: Run the query-shape spec and focused scorer spec**

Run:

```bash
crystal spec spec/invidious/popular_database_spec.cr spec/invidious/popular_spec.cr
```

Expected: both spec files pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add src/invidious/database/channels.cr spec/invidious/popular_database_spec.cr
git commit -m "feat: select popular candidates from all subscriptions"
```

## Task 3: Make The Popular Cache Range-Aware

**Files:**
- Modify: `src/invidious/jobs/pull_popular_videos_job.cr`
- Modify: `src/invidious.cr`
- Modify: `spec/invidious/popular_spec.cr`

- [ ] **Step 1: Add a cache behavior spec**

Append this example to `spec/invidious/popular_spec.cr` inside `Spectator.describe Invidious::Popular do`:

```crystal
  describe ".empty_cache" do
    it "creates an empty bucket for every supported range" do
      cache = described_class.empty_cache

      expect(cache[Invidious::Popular::Range::Day]).to be_empty
      expect(cache[Invidious::Popular::Range::Week]).to be_empty
      expect(cache[Invidious::Popular::Range::TwoWeeks]).to be_empty
      expect(cache[Invidious::Popular::Range::Month]).to be_empty
    end
  end
```

- [ ] **Step 2: Run the spec**

Run:

```bash
crystal spec spec/invidious/popular_spec.cr
```

Expected: pass if Task 1's `empty_cache` implementation exists.

- [ ] **Step 3: Update the Popular job cache**

Replace `src/invidious/jobs/pull_popular_videos_job.cr` with:

```crystal
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
```

- [ ] **Step 4: Update the global helper**

In `src/invidious.cr`, replace:

```crystal
def popular_videos
  Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get
end
```

with:

```crystal
def popular_videos(range : Invidious::Popular::Range = Invidious::Popular::Range::Day)
  Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get[range]? || [] of ChannelVideo
end
```

- [ ] **Step 5: Run compile verification**

Run:

```bash
make verify
```

Expected: Crystal compile check exits `0`.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/invidious/jobs/pull_popular_videos_job.cr src/invidious.cr spec/invidious/popular_spec.cr
git commit -m "feat: cache popular videos by range"
```

## Task 4: Add Range Support To Web And API Routes

**Files:**
- Modify: `src/invidious/routes/feeds.cr`
- Modify: `src/invidious/routes/api/v1/feeds.cr`

- [ ] **Step 1: Update the web Popular route**

In `src/invidious/routes/feeds.cr`, replace `def self.popular(env)` with:

```crystal
  def self.popular(env)
    locale = env.get("preferences").as(Preferences).locale

    if CONFIG.popular_enabled
      popular_range = Invidious::Popular.parse_range(env.params.query["range"]?)
      popular_range_options = Invidious::Popular::RANGES
      popular_videos = popular_videos(popular_range)

      templated "feeds/popular"
    else
      message = I18n.translate(locale, "The Popular feed has been disabled by the administrator.")
      templated "message"
    end
  end
```

- [ ] **Step 2: Update the API Popular route**

In `src/invidious/routes/api/v1/feeds.cr`, replace the JSON array loop inside `def self.popular(env)` with:

```crystal
    popular_range = Invidious::Popular.parse_range(env.params.query["range"]?)

    JSON.build do |json|
      json.array do
        popular_videos(popular_range).each do |video|
          video.to_json(locale, json)
        end
      end
    end
```

Keep the existing content type and disabled-endpoint check.

- [ ] **Step 3: Run compile verification**

Run:

```bash
make verify
```

Expected: Crystal compile check exits `0`.

- [ ] **Step 4: Commit**

Run:

```bash
git add src/invidious/routes/feeds.cr src/invidious/routes/api/v1/feeds.cr
git commit -m "feat: add popular range route support"
```

## Task 5: Add The Popular Range Selector UI

**Files:**
- Modify: `src/invidious/views/feeds/popular.ecr`
- Modify: `locales/en-US.json`

- [ ] **Step 1: Add English translation keys**

In `locales/en-US.json`, add these keys near the existing Popular strings:

```json
    "popular_range_day": "Last 2 days",
    "popular_range_week": "Last week",
    "popular_range_twoweeks": "Last 2 weeks",
    "popular_range_month": "Last month",
```

Preserve valid JSON commas based on the surrounding keys.

- [ ] **Step 2: Update the Popular template**

Replace the body section of `src/invidious/views/feeds/popular.ecr` after `<%= rendered "components/feed_menu" %>` with:

```ecr
<div class="pure-g h-box">
    <div class="pure-u-1">
        <div class="pure-g" style="text-align:right">
            <% popular_range_options.each do |range_option| %>
                <div class="pure-u-1 pure-md-1-4">
                    <% if popular_range == range_option %>
                        <b><%= I18n.translate(locale, range_option.label_key) %></b>
                    <% else %>
                        <a href="/feed/popular?range=<%= range_option.key %>">
                            <%= I18n.translate(locale, range_option.label_key) %>
                        </a>
                    <% end %>
                </div>
            <% end %>
        </div>
    </div>
</div>

<div class="h-box">
    <hr>
</div>

<div class="pure-g">
<% popular_videos.each do |item| %>
    <%= rendered "components/item" %>
<% end %>
</div>

<script src="/js/watched_indicator.js"></script>
```

- [ ] **Step 3: Verify locale JSON parses**

Run:

```bash
ruby -e 'require "json"; JSON.parse(File.read("locales/en-US.json")); puts "locales/en-US.json: ok"'
```

Expected:

```text
locales/en-US.json: ok
```

- [ ] **Step 4: Run compile verification**

Run:

```bash
make verify
```

Expected: Crystal compile check exits `0`.

- [ ] **Step 5: Commit**

Run:

```bash
git add src/invidious/views/feeds/popular.ecr locales/en-US.json
git commit -m "feat: add popular range selector"
```

## Task 6: Final Verification

**Files:**
- Verify all modified files

- [ ] **Step 1: Run the focused Popular specs**

Run:

```bash
crystal spec spec/invidious/popular_spec.cr spec/invidious/popular_database_spec.cr
```

Expected: all examples pass.

- [ ] **Step 2: Run the full Crystal spec suite**

Run:

```bash
crystal spec
```

Expected: full suite exits `0`.

- [ ] **Step 3: Run compile verification**

Run:

```bash
make verify
```

Expected: Crystal compile check exits `0`.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git status --short --branch
git diff --stat HEAD~5..HEAD
```

Expected: working tree is clean and the diff only covers Popular scoring, candidate selection, route/API integration, the Popular template, English labels, and tests.

- [ ] **Step 5: Build and publish after implementation approval**

After code review, use the fork container workflow already configured for GHCR:

```bash
git push origin master
gh workflow run build-stable-container.yml -R shayne/invidious --ref master
```

Expected: the workflow publishes a new `ghcr.io/shayne/invidious:latest` image.
