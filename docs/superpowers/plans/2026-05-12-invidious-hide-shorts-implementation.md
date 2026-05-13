# Invidious Per-User Shorts Hiding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-user "Hide YouTube Shorts" preference backed by durable Shorts metadata and authoritative backfill.

**Architecture:** Add nullable `is_short` metadata to parsed videos and stored `channel_videos`, plus a focused `Invidious::Shorts` helper for marking and filtering. Classify only from explicit Shorts parsers/tabs, migrate the database without guessing, and add a low-rate backfill job that progressively classifies existing rows while unknown rows remain visible.

**Tech Stack:** Crystal, Spectator specs, PostgreSQL through crystal-pg, Kemal routes, ECR templates, existing Invidious job framework.

---

## File Structure

- Create `src/invidious/shorts.cr`: pure helper methods for `is_short` visibility, marking `SearchVideo` arrays from explicit tab context, and filtering mixed arrays.
- Create `src/invidious/jobs/backfill_shorts_job.cr`: background job that classifies old `channel_videos` rows from explicit Shorts and Videos tab IDs.
- Create `src/invidious/database/migrations/0012_add_channel_videos_is_short.cr`: adds nullable `is_short`, hidden-Shorts index, and stale feed marker.
- Create `spec/invidious/shorts_spec.cr`: tests helper behavior and JSON `isShort` output.
- Create `spec/invidious/shorts_extractors_spec.cr`: tests authoritative parser classification.
- Create `spec/invidious/shorts_database_spec.cr`: tests query shape and migration text for durable metadata/backfill support.
- Modify `config/sql/channel_videos.sql`: keep fresh installs aligned with migrations.
- Modify `src/invidious/channels/channels.cr`: add `ChannelVideo#is_short`, JSON `isShort`, and copy parser metadata into rows.
- Modify `src/invidious/channels/videos.cr`: mark explicit Shorts tab results true and explicit Videos tab results false unless already true.
- Modify `src/invidious/helpers/serialized_yt_data.cr`: add `SearchVideo#is_short`, `SearchVideo#with_is_short`, and JSON `isShort`.
- Modify `src/invidious/yt_backend/extractors.cr`: set `is_short` from authoritative parser structures and the exact `"SHORTS"` overlay.
- Modify `src/invidious/database/channels.cr`: write/read `is_short`, add classification update methods, update Popular candidate query.
- Modify `src/invidious/popular.cr`: carry `is_short` through Popular candidates and add a cache filter helper.
- Modify `src/invidious.cr`: allow `popular_videos` to filter per-user without changing the global cache.
- Modify `src/invidious/jobs/pull_popular_videos_job.cr`: keep existing global cache, relying on updated candidates and baselines.
- Modify `src/invidious/users.cr`: exclude confirmed Shorts from subscription feed SQL when the preference is on.
- Modify `src/invidious/search/processors.cr`: exclude confirmed Shorts from subscription search and filter mixed YouTube search results.
- Modify `src/invidious/routes/feeds.cr`: use `preferences.hide_shorts` for Popular and subscriptions.
- Modify `src/invidious/routes/api/v1/feeds.cr`: use request preferences for `/api/v1/popular`.
- Modify `src/invidious/routes/channels.cr`: filter mixed Videos tab items while preserving direct Shorts route access.
- Modify `src/invidious/routes/api/v1/channels.cr`: filter mixed Videos API items while preserving explicit Shorts API.
- Modify `src/invidious/frontend/channel_page.cr`: hide Shorts tab navigation link when `hide_shorts` is true.
- Modify `src/invidious/views/components/channel_info.ecr`: pass request preferences into tab generation.
- Modify `src/invidious/config.cr`: add default `hide_shorts`.
- Modify `src/invidious/user/preferences.cr`: add user preference.
- Modify `src/invidious/routes/preferences.cr`: parse and persist the checkbox.
- Modify `src/invidious/views/user/preferences.ecr`: render the checkbox.
- Modify `config/config.example.yml`: document `default_user_preferences.hide_shorts`.
- Modify `locales/en-US.json`: add the checkbox label.

## Task 1: Shorts Metadata Models And Pure Filtering

**Files:**
- Create: `src/invidious/shorts.cr`
- Create: `spec/invidious/shorts_spec.cr`
- Modify: `src/invidious/helpers/serialized_yt_data.cr`
- Modify: `src/invidious/channels/channels.cr`

- [ ] **Step 1: Write the failing metadata/filter specs**

Create `spec/invidious/shorts_spec.cr`:

```crystal
require "../spec_helper"
require "../../src/invidious/shorts"

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

Spectator.describe SearchVideo do
  it "serializes isShort as true, false, and null" do
    expect(JSON.parse(shorts_search_video("short", true).to_json("en-US", nil))["isShort"].as_bool).to be_true
    expect(JSON.parse(shorts_search_video("normal", false).to_json("en-US", nil))["isShort"].as_bool).to be_false
    expect(JSON.parse(shorts_search_video("unknown", nil).to_json("en-US", nil))["isShort"]).to be_nil
  end
end

Spectator.describe ChannelVideo do
  it "serializes a dedicated nullable isShort field without changing type" do
    json = JSON.parse(shorts_channel_video("short", true).to_json("en-US"))

    expect(json["type"].as_s).to eq("shortVideo")
    expect(json["isShort"].as_bool).to be_true
  end
end
```

- [ ] **Step 2: Run the focused spec and verify it fails**

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr
```

Expected: fail because `src/invidious/shorts.cr`, `SearchVideo#is_short`, `SearchVideo#with_is_short`, `ChannelVideo#is_short`, and `isShort` JSON are not implemented.

- [ ] **Step 3: Implement `SearchVideo` and `ChannelVideo` metadata**

In `src/invidious/helpers/serialized_yt_data.cr`, add the property after `badges`:

```crystal
property is_short : Bool? = nil
```

Add this method inside `struct SearchVideo`:

```crystal
def with_is_short(value : Bool?) : SearchVideo
  SearchVideo.new({
    title:              self.title,
    id:                 self.id,
    author:             self.author,
    ucid:               self.ucid,
    published:          self.published,
    views:              self.views,
    description_html:   self.description_html,
    length_seconds:     self.length_seconds,
    premiere_timestamp: self.premiere_timestamp,
    author_verified:    self.author_verified,
    author_thumbnail:   self.author_thumbnail,
    badges:             self.badges,
    is_short:           value,
  })
end
```

In `SearchVideo#to_json`, after `json.field "type", "video"` add:

```crystal
json.field "isShort", self.is_short
```

In `src/invidious/channels/channels.cr`, add this property to `struct ChannelVideo` after `views`:

```crystal
property is_short : Bool? = nil
```

In `ChannelVideo#to_json`, after `json.field "type", "shortVideo"` add:

```crystal
json.field "isShort", self.is_short
```

- [ ] **Step 4: Implement `Invidious::Shorts` helpers**

Create `src/invidious/shorts.cr`:

```crystal
module Invidious::Shorts
  extend self

  def visible?(is_short : Bool?) : Bool
    is_short != true
  end

  def filter_channel_videos(videos : Array(ChannelVideo), *, hide_shorts : Bool) : Array(ChannelVideo)
    return videos unless hide_shorts

    videos.select { |video| visible?(video.is_short) }
  end

  def filter_search_items(items : Array(SearchItem), *, hide_shorts : Bool) : Array(SearchItem)
    return items unless hide_shorts

    filtered = [] of SearchItem
    items.each do |item|
      if item.is_a?(SearchVideo) && !visible?(item.is_short)
        next
      end

      filtered << item
    end
    filtered
  end

  def mark_from_shorts_tab(items : Array(SearchItem)) : Array(SearchItem)
    mark_search_videos(items) { true }
  end

  def mark_from_videos_tab(items : Array(SearchItem)) : Array(SearchItem)
    mark_search_videos(items) do |video|
      video.is_short == true ? true : false
    end
  end

  private def mark_search_videos(items : Array(SearchItem), & : SearchVideo -> Bool?) : Array(SearchItem)
    marked = [] of SearchItem

    items.each do |item|
      case item
      when SearchVideo
        marked << item.with_is_short(yield item)
      else
        marked << item
      end
    end

    marked
  end
end
```

- [ ] **Step 5: Run the focused spec and verify it passes**

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr
```

Expected: pass.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/invidious/shorts.cr src/invidious/helpers/serialized_yt_data.cr src/invidious/channels/channels.cr spec/invidious/shorts_spec.cr
git commit -m "feat: add shorts metadata helpers"
```

## Task 2: Database Schema, Insert Semantics, And Popular Query Shape

**Files:**
- Create: `src/invidious/database/migrations/0012_add_channel_videos_is_short.cr`
- Create: `spec/invidious/shorts_database_spec.cr`
- Modify: `config/sql/channel_videos.sql`
- Modify: `src/invidious/database/channels.cr`
- Modify: `src/invidious/popular.cr`
- Modify: `spec/invidious/popular_database_spec.cr`

- [ ] **Step 1: Write failing database/query specs**

Create `spec/invidious/shorts_database_spec.cr`:

```crystal
require "../spec_helper"
require "../../src/invidious/database/channels"

Spectator.describe Invidious::Database::ChannelVideos do
  describe ".insert_query" do
    it "inserts is_short with an explicit column list" do
      query = described_class.insert_query(with_premiere_timestamp: false)

      expect(query.includes?("INSERT INTO channel_videos")).to be_true
      expect(query.includes?("is_short")).to be_true
      expect(query.includes?("VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)")).to be_true
    end

    it "does not overwrite known Shorts metadata with unknown metadata" do
      query = described_class.insert_query(with_premiere_timestamp: true)

      expect(query.includes?("WHEN $11 IS NULL THEN channel_videos.is_short")).to be_true
      expect(query.includes?("WHEN channel_videos.is_short IS TRUE AND $11 IS FALSE THEN TRUE")).to be_true
      expect(query.includes?("ELSE $11")).to be_true
    end
  end

  describe ".select_unclassified_shorts_channels_query" do
    it "selects recent channels with unknown Shorts classification" do
      query = described_class.select_unclassified_shorts_channels_query

      expect(query.includes?("is_short IS NULL")).to be_true
      expect(query.includes?("GROUP BY ucid")).to be_true
      expect(query.includes?("ORDER BY MAX(published) DESC")).to be_true
      expect(query.includes?("LIMIT $1")).to be_true
    end
  end

  describe ".mark_shorts_query" do
    it "marks matching ids as confirmed Shorts" do
      query = described_class.mark_shorts_query

      expect(query.includes?("SET is_short = TRUE")).to be_true
      expect(query.includes?("WHERE id = ANY($1)")).to be_true
    end
  end

  describe ".mark_non_shorts_query" do
    it "marks only unknown matching ids as confirmed non-Shorts" do
      query = described_class.mark_non_shorts_query

      expect(query.includes?("SET is_short = FALSE")).to be_true
      expect(query.includes?("WHERE id = ANY($1)")).to be_true
      expect(query.includes?("AND is_short IS NULL")).to be_true
    end
  end
end

Spectator.describe "AddChannelVideosIsShort migration" do
  it "uses migration version 12 and marks feeds stale" do
    migration = File.read("src/invidious/database/migrations/0012_add_channel_videos_is_short.cr")

    expect(migration.includes?("version 12")).to be_true
    expect(migration.includes?("ADD COLUMN IF NOT EXISTS is_short boolean NULL")).to be_true
    expect(migration.includes?("UPDATE users SET feed_needs_update = true")).to be_true
  end
end
```

Modify `spec/invidious/popular_database_spec.cr` with two new examples:

```crystal
it "selects Shorts metadata for candidate rows" do
  query = described_class.popular_candidates_query

  expect(query.includes?("cv.is_short")).to be_true
end

it "excludes confirmed Shorts from baseline samples" do
  query = described_class.popular_candidates_query

  expect(query.includes?("cv2.is_short IS DISTINCT FROM TRUE")).to be_true
end
```

- [ ] **Step 2: Run focused specs and verify they fail**

Run:

```bash
crystal spec spec/invidious/shorts_database_spec.cr spec/invidious/popular_database_spec.cr
```

Expected: fail because migration 12, insert query helpers, classification queries, and Popular `is_short` selection are not implemented.

- [ ] **Step 3: Add migration and fresh-install schema**

Create `src/invidious/database/migrations/0012_add_channel_videos_is_short.cr`:

```crystal
module Invidious::Database::Migrations
  class AddChannelVideosIsShort < Migration
    version 12

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.channel_videos
        ADD COLUMN IF NOT EXISTS is_short boolean NULL;
      SQL

      conn.exec <<-SQL
      CREATE INDEX IF NOT EXISTS channel_videos_ucid_published_not_shorts_idx
        ON public.channel_videos
        USING btree
        (ucid COLLATE pg_catalog."default", published DESC)
        WHERE is_short IS DISTINCT FROM TRUE;
      SQL

      conn.exec <<-SQL
      UPDATE users SET feed_needs_update = true;
      SQL
    end
  end
end
```

In `config/sql/channel_videos.sql`, add the column after `views bigint`:

```sql
  views bigint,
  is_short boolean,
```

Add the matching index after `channel_videos_ucid_published_idx`:

```sql
-- Index: public.channel_videos_ucid_published_not_shorts_idx

-- DROP INDEX public.channel_videos_ucid_published_not_shorts_idx;

CREATE INDEX IF NOT EXISTS channel_videos_ucid_published_not_shorts_idx
  ON public.channel_videos
  USING btree
  (ucid COLLATE pg_catalog."default", published DESC)
  WHERE is_short IS DISTINCT FROM TRUE;
```

- [ ] **Step 4: Update `ChannelVideos.insert` with merge-safe metadata**

In `src/invidious/database/channels.cr`, replace the body of `insert` with a call to an `insert_query` helper:

```crystal
def insert(video : ChannelVideo, with_premiere_timestamp : Bool = false) : Bool
  return PG_DB.query_one(insert_query(with_premiere_timestamp), *video.to_tuple, as: Bool)
end

def insert_query(with_premiere_timestamp : Bool) : String
  premiere_assignment =
    if with_premiere_timestamp
      "premiere_timestamp = $9,"
    else
      ""
    end

  <<-SQL
    INSERT INTO channel_videos
      (id, title, published, updated, ucid, author, length_seconds, live_now, premiere_timestamp, views, is_short)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    ON CONFLICT (id) DO UPDATE
    SET title = $2, published = $3, updated = $4, ucid = $5,
        author = $6, length_seconds = $7, live_now = $8,
        #{premiere_assignment}
        views = $10,
        is_short = CASE
          WHEN $11 IS NULL THEN channel_videos.is_short
          WHEN channel_videos.is_short IS TRUE AND $11 IS FALSE THEN TRUE
          ELSE $11
        END
    RETURNING (xmax=0) AS was_insert
  SQL
end
```

- [ ] **Step 5: Add classification query helpers**

In `src/invidious/database/channels.cr`, add these methods inside `module Invidious::Database::ChannelVideos`:

```crystal
def select_unclassified_shorts_channels_query : String
  <<-SQL
    SELECT ucid
    FROM channel_videos
    WHERE is_short IS NULL
      AND ucid IS NOT NULL
      AND ucid != ''
      AND published >= now() - interval '180 days'
    GROUP BY ucid
    ORDER BY MAX(published) DESC
    LIMIT $1
  SQL
end

def select_unclassified_shorts_channels(limit : Int32) : Array(String)
  PG_DB.query_all(select_unclassified_shorts_channels_query, limit, as: String)
end

def mark_shorts_query : String
  <<-SQL
    UPDATE channel_videos
    SET is_short = TRUE
    WHERE id = ANY($1)
  SQL
end

def mark_shorts(ids : Array(String)) : Nil
  return if ids.empty?
  PG_DB.exec(mark_shorts_query, ids)
end

def mark_non_shorts_query : String
  <<-SQL
    UPDATE channel_videos
    SET is_short = FALSE
    WHERE id = ANY($1)
      AND is_short IS NULL
  SQL
end

def mark_non_shorts(ids : Array(String)) : Nil
  return if ids.empty?
  PG_DB.exec(mark_non_shorts_query, ids)
end
```

- [ ] **Step 6: Carry Shorts metadata through Popular candidates**

In `src/invidious/popular.cr`, add `property is_short : Bool? = nil` to `CandidateRow`, and add `is_short: @is_short` to the `ChannelVideo.new` inside `to_candidate`.

In `src/invidious/database/channels.cr`, update `popular_candidates_query`:

```sql
        cv.views,
        cv.is_short,
        sc.local_subscription_count,
```

Inside the baseline sample `WHERE`, add:

```sql
            AND cv2.is_short IS DISTINCT FROM TRUE
```

- [ ] **Step 7: Run focused specs and commit**

Run:

```bash
crystal spec spec/invidious/shorts_database_spec.cr spec/invidious/popular_database_spec.cr
```

Expected: pass.

Run:

```bash
git add config/sql/channel_videos.sql src/invidious/database/migrations/0012_add_channel_videos_is_short.cr src/invidious/database/channels.cr src/invidious/popular.cr spec/invidious/shorts_database_spec.cr spec/invidious/popular_database_spec.cr
git commit -m "feat: persist shorts classification"
```

## Task 3: Authoritative Parser And Channel Tab Classification

**Files:**
- Create: `spec/invidious/shorts_extractors_spec.cr`
- Modify: `src/invidious/yt_backend/extractors.cr`
- Modify: `src/invidious/channels/videos.cr`
- Modify: `src/invidious/channels/channels.cr`
- Modify: `src/invidious/routes/feeds.cr`

- [ ] **Step 1: Write failing extractor classification specs**

Create `spec/invidious/shorts_extractors_spec.cr`:

```crystal
require "../parsers_helper.cr"

private def parse_search_item(raw : String) : SearchItem
  parse_item(JSON.parse(raw), "Fallback Author", "UCFALLBACK").as(SearchItem)
end

Spectator.describe "YouTube Shorts extraction" do
  it "marks reelItemRenderer results as Shorts" do
    item = parse_search_item(%({
      "reelItemRenderer": {
        "videoId": "SHORTREEL01",
        "headline": { "simpleText": "Reel short" },
        "viewCountText": { "simpleText": "1.2K views" },
        "accessibility": { "accessibilityData": { "label": "Reel short - 10 seconds - play video" } },
        "navigationEndpoint": {
          "reelWatchEndpoint": {
            "overlay": {
              "reelPlayerOverlayRenderer": {
                "reelPlayerHeaderSupportedRenderers": {
                  "reelPlayerHeaderRenderer": {
                    "reelTitleText": { "simpleText": "Reel short" },
                    "timestampText": { "simpleText": "1 day ago" },
                    "channelTitleText": { "runs": [{ "text": "Fallback Author" }] },
                    "channelNavigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } },
                    "viewCountText": { "simpleText": "1.2K views" }
                  }
                }
              }
            }
          }
        }
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks shortsLockupViewModel results as Shorts" do
    item = parse_search_item(%({
      "shortsLockupViewModel": {
        "onTap": { "innertubeCommand": { "reelWatchEndpoint": { "videoId": "SHORTLOCK01" } } },
        "overlayMetadata": {
          "primaryText": { "content": "Lockup short" },
          "secondaryText": { "content": "2K views" }
        }
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks videoRenderer with exact SHORTS overlay as Shorts" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "SHORTOVER01",
        "title": { "runs": [{ "text": "Overlay short" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "publishedTimeText": { "simpleText": "1 day ago" },
        "viewCountText": { "simpleText": "123 views" },
        "thumbnailOverlays": [{
          "thumbnailOverlayTimeStatusRenderer": {
            "text": { "simpleText": "SHORTS" }
          }
        }]
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks ordinary videoRenderer results as unknown until tab context confirms them" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "NORMAL0001",
        "title": { "runs": [{ "text": "Normal video" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "publishedTimeText": { "simpleText": "1 day ago" },
        "viewCountText": { "simpleText": "123 views" },
        "lengthText": { "simpleText": "12:34" }
      }
    }))

    expect(item.as(SearchVideo).is_short).to be_nil
  end
end
```

- [ ] **Step 2: Run extractor specs and verify they fail**

Run:

```bash
crystal spec spec/invidious/shorts_extractors_spec.cr
```

Expected: fail because parser constructors do not set `is_short`.

- [ ] **Step 3: Update parser constructors with explicit metadata**

In `src/invidious/yt_backend/extractors.cr`, initialize `is_short = nil` near the VideoRenderer length extraction.

When `length_text == "SHORTS"`, set:

```crystal
is_short = true
length_seconds = 60_i32
```

For the `SearchVideo.new` in `VideoRendererParser`, add:

```crystal
is_short:           is_short,
```

For the `SearchVideo.new` in `ReelItemRendererParser`, add:

```crystal
is_short:           true,
```

For the `SearchVideo.new` in `ShortsLockupViewModelParser`, add:

```crystal
is_short:           true,
```

For all other `SearchVideo.new` constructors in `src/invidious/yt_backend/extractors.cr`, `src/invidious/routes/feeds.cr`, `src/invidious/playlists.cr`, `src/invidious/mixes.cr`, and imports, add `is_short: nil`.

- [ ] **Step 4: Mark explicit channel tab context**

In `src/invidious/channels/videos.cr`, change `get_videos` to return marked Videos-tab items:

```crystal
items, continuation = extract_items(initial_data, author, ucid)
return Invidious::Shorts.mark_from_videos_tab(items), continuation
```

Change `get_shorts` to return marked Shorts-tab items:

```crystal
items, continuation = extract_items(initial_data, channel.author, channel.ucid)
return Invidious::Shorts.mark_from_shorts_tab(items), continuation
```

Leave `get_livestreams` unchanged unless a parser already identifies Shorts, because the streams tab is not a Shorts source.

- [ ] **Step 5: Copy parser metadata into `ChannelVideo` rows**

In `src/invidious/channels/channels.cr`, after reading `premiere_timestamp`, add:

```crystal
is_short = channel_video.try &.is_short
```

Add `is_short: is_short` to the `ChannelVideo.new` for RSS entries.

In the `pull_all_videos` loop, add:

```crystal
is_short:           video.is_short,
```

to the `ChannelVideo.new` built from `SearchVideo`.

In `src/invidious/routes/feeds.cr` PubSub ingestion, set:

```crystal
is_short:           nil,
```

Do not infer PubSub Shorts status from `length_seconds`.

- [ ] **Step 6: Run extractor and shorts specs, then commit**

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr spec/invidious/shorts_extractors_spec.cr
```

Expected: pass.

Run:

```bash
git add src/invidious/yt_backend/extractors.cr src/invidious/channels/videos.cr src/invidious/channels/channels.cr src/invidious/routes/feeds.cr src/invidious/playlists.cr src/invidious/mixes.cr spec/invidious/shorts_extractors_spec.cr
git commit -m "feat: classify shorts from explicit youtube sources"
```

## Task 4: Per-User Preference Plumbing

**Files:**
- Modify: `src/invidious/config.cr`
- Modify: `src/invidious/user/preferences.cr`
- Modify: `src/invidious/routes/preferences.cr`
- Modify: `src/invidious/views/user/preferences.ecr`
- Modify: `config/config.example.yml`
- Modify: `locales/en-US.json`

- [ ] **Step 1: Add the config and user preference fields**

In `src/invidious/config.cr`, add this property near other user-facing booleans in `ConfigPreferences`:

```crystal
property hide_shorts : Bool = false
```

In `src/invidious/user/preferences.cr`, add:

```crystal
property hide_shorts : Bool = CONFIG.default_user_preferences.hide_shorts
```

- [ ] **Step 2: Parse and persist the preferences form field**

In `src/invidious/routes/preferences.cr`, after `related_videos` parsing, add:

```crystal
hide_shorts = env.params.body["hide_shorts"]?.try &.as(String)
hide_shorts ||= "off"
hide_shorts = hide_shorts == "on"
```

In the `Preferences.from_json` hash, add:

```crystal
hide_shorts:                 hide_shorts,
```

- [ ] **Step 3: Add the checkbox to preferences UI**

In `src/invidious/views/user/preferences.ecr`, place this in the subscription preferences section after `notifications_only`:

```ecr
<div class="pure-control-group">
    <label for="hide_shorts"><%= I18n.translate(locale, "preferences_hide_shorts_label") %></label>
    <input name="hide_shorts" id="hide_shorts" type="checkbox" <% if preferences.hide_shorts %>checked<% end %>>
</div>
```

- [ ] **Step 4: Add locale and example config documentation**

In `locales/en-US.json`, add:

```json
"preferences_hide_shorts_label": "Hide YouTube Shorts",
```

In `config/config.example.yml`, under `default_user_preferences`, add:

```yaml
  ## Hide confirmed YouTube Shorts from mixed feeds and results.
  ##
  ## Accepted values: true, false
  ## Default: false
  ##
  #hide_shorts: false
```

- [ ] **Step 5: Run compile check and commit**

Run:

```bash
crystal build src/invidious.cr -Dskip_videojs_download --no-codegen --error-trace
```

Expected: compile succeeds.

Run:

```bash
git add src/invidious/config.cr src/invidious/user/preferences.cr src/invidious/routes/preferences.cr src/invidious/views/user/preferences.ecr config/config.example.yml locales/en-US.json
git commit -m "feat: add hide shorts preference"
```

## Task 5: Mixed Surface Filtering

**Files:**
- Modify: `src/invidious.cr`
- Modify: `src/invidious/users.cr`
- Modify: `src/invidious/search/processors.cr`
- Modify: `src/invidious/routes/feeds.cr`
- Modify: `src/invidious/routes/api/v1/feeds.cr`
- Modify: `src/invidious/routes/channels.cr`
- Modify: `src/invidious/routes/api/v1/channels.cr`
- Modify: `src/invidious/frontend/channel_page.cr`
- Modify: `src/invidious/views/components/channel_info.ecr`
- Modify: `spec/invidious/shorts_spec.cr`

- [ ] **Step 1: Add focused filtering specs**

Append to `spec/invidious/shorts_spec.cr`:

```crystal
Spectator.describe Invidious::Shorts do
  describe ".filter_search_items" do
    it "filters confirmed Shorts and preserves unknown SearchVideos and non-video items" do
      items = [
        shorts_search_video("short", true),
        shorts_search_video("unknown", nil),
        shorts_search_video("normal", false),
      ] of SearchItem

      filtered = described_class.filter_search_items(items, hide_shorts: true)

      expect(filtered.map { |item| item.as(SearchVideo).id }).to eq(["unknown", "normal"])
    end
  end
end
```

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr
```

Expected: pass if Task 1 implemented `filter_search_items` correctly.

- [ ] **Step 2: Add per-user Popular filtering**

In `src/invidious/popular.cr`, add:

```crystal
def self.filter_videos(videos : Array(ChannelVideo), *, hide_shorts : Bool) : Array(ChannelVideo)
  Invidious::Shorts.filter_channel_videos(videos, hide_shorts: hide_shorts)
end
```

In `src/invidious.cr`, replace `popular_videos` with:

```crystal
def popular_videos(
  range : Invidious::Popular::Range = Invidious::Popular::Range::Day,
  *,
  hide_shorts : Bool = false,
)
  videos = Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get[range]? || [] of ChannelVideo
  Invidious::Popular.filter_videos(videos, hide_shorts: hide_shorts)
end
```

In `src/invidious/routes/feeds.cr`, change Popular route setup to:

```crystal
preferences = env.get("preferences").as(Preferences)
locale = preferences.locale
popular_range = Invidious::Popular.parse_range(env.params.query["range"]?)
popular_range_options = Invidious::Popular::RANGES
popular_videos = popular_videos(popular_range, hide_shorts: preferences.hide_shorts)
```

In `src/invidious/routes/api/v1/feeds.cr`, read preferences and call:

```crystal
preferences = env.get("preferences").as(Preferences)
popular_videos(popular_range, hide_shorts: preferences.hide_shorts).each do |video|
```

- [ ] **Step 3: Filter subscription feed SQL before pagination**

In `src/invidious/users.cr`, update the `MATERIALIZED_VIEW_SQL` lambda to include `is_short` automatically through `cv.*`; no change is needed there after the migration recreates views.

Add this helper near `get_subscription_feed`:

```crystal
private def hide_shorts_clause(user : User) : String
  user.preferences.hide_shorts ? " AND is_short IS DISTINCT FROM TRUE" : ""
end
```

In `get_subscription_feed`, set:

```crystal
shorts_clause = hide_shorts_clause(user)
```

Apply `#{shorts_clause}` inside every materialized view query that selects feed videos:

```crystal
videos = PG_DB.query_all("SELECT DISTINCT ON (ucid) * FROM #{view_name} WHERE NOT id = ANY (#{values})#{shorts_clause} ORDER BY ucid, published DESC", as: ChannelVideo)
videos = PG_DB.query_all("SELECT DISTINCT ON (ucid) * FROM #{view_name} WHERE is_short IS DISTINCT FROM TRUE ORDER BY ucid, published DESC", as: ChannelVideo)
videos = PG_DB.query_all("SELECT * FROM #{view_name} WHERE NOT id = ANY (#{values})#{shorts_clause} ORDER BY published DESC LIMIT $1 OFFSET $2", limit, offset, as: ChannelVideo)
videos = PG_DB.query_all("SELECT * FROM #{view_name} WHERE is_short IS DISTINCT FROM TRUE ORDER BY published DESC LIMIT $1 OFFSET $2", limit, offset, as: ChannelVideo)
```

For the two no-`WHERE` queries, use the full `WHERE is_short IS DISTINCT FROM TRUE` form instead of appending `AND`.

In the notifications-only branch, after loading notifications, add:

```crystal
notifications = Invidious::Shorts.filter_channel_videos(notifications, hide_shorts: user.preferences.hide_shorts)
```

- [ ] **Step 4: Filter subscription search and YouTube search results**

In `src/invidious/search/processors.cr`, update subscription search SQL:

```crystal
shorts_clause = user.preferences.hide_shorts ? "AND v_search.is_short IS DISTINCT FROM TRUE" : ""

return PG_DB.query_all("
  SELECT *
  FROM (
    SELECT *,
    to_tsvector(#{view_name}.title) ||
    to_tsvector(#{view_name}.author)
    as document
    FROM #{view_name}
  ) v_search WHERE v_search.document @@ plainto_tsquery($1) #{shorts_clause} LIMIT 20 OFFSET $2;",
  query.text, (query.page - 1) * 20,
  as: ChannelVideo
)
```

In `src/invidious/search/processors.cr`, change the regular and channel signatures:

```crystal
def regular(query : Query, *, hide_shorts : Bool = false) : Array(SearchItem)
def channel(query : Query, *, hide_shorts : Bool = false) : Array(SearchItem)
```

For both processors, after `items.reject!(Category)`, return:

```crystal
return Invidious::Shorts.filter_search_items(items.reject!(Category), hide_shorts: hide_shorts)
```

In `src/invidious/search/query.cr`, update `process` to pass the optional user preference into regular and channel searches:

```crystal
hide_shorts = user.try(&.preferences.hide_shorts) || false

case @type
when .regular?, .playlist?
  items = Processors.regular(self, hide_shorts: hide_shorts)
when .channel?
  items = Processors.channel(self, hide_shorts: hide_shorts)
when .subscriptions?
  if user
    items = Processors.subscriptions(self, user.as(Invidious::User))
  end
end
```

- [ ] **Step 5: Filter channel Videos tab and preserve Shorts route/API**

In `src/invidious/routes/channels.cr`, after the Videos tab sets `items`, add:

```crystal
preferences = env.get("preferences").as(Preferences)
items = Invidious::Shorts.filter_search_items(items.select(SearchItem), hide_shorts: preferences.hide_shorts)
```

Do not add this filter to `def self.shorts`.

In `src/invidious/routes/api/v1/channels.cr`, inside `def self.videos`, filter before JSON output:

```crystal
preferences = env.get("preferences").as(Preferences)
videos = Invidious::Shorts.filter_search_items(videos.select(SearchItem), hide_shorts: preferences.hide_shorts)
```

Do not add this filter to `def self.shorts`.

- [ ] **Step 6: Hide the Shorts tab navigation link only**

In `src/invidious/frontend/channel_page.cr`, change the signature:

```crystal
def generate_tabs_links(locale : String, channel : AboutChannel, selected_tab : TabsAvailable, *, hide_shorts : Bool = false)
```

Inside the `TabsAvailable.each` loop, after `tab_name = tab.to_s.downcase`, add:

```crystal
next if hide_shorts && tab.shorts?
```

In `src/invidious/views/components/channel_info.ecr`, update the call:

```ecr
<%= Invidious::Frontend::ChannelPage.generate_tabs_links(locale, channel, selected_tab, hide_shorts: env.get("preferences").as(Preferences).hide_shorts) %>
```

- [ ] **Step 7: Run focused compile/specs and commit**

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr spec/invidious/popular_spec.cr spec/invidious/popular_database_spec.cr
crystal build src/invidious.cr -Dskip_videojs_download --no-codegen --error-trace
```

Expected: specs pass and compile succeeds.

Run:

```bash
git add src/invidious.cr src/invidious/users.cr src/invidious/search/processors.cr src/invidious/routes/feeds.cr src/invidious/routes/api/v1/feeds.cr src/invidious/routes/channels.cr src/invidious/routes/api/v1/channels.cr src/invidious/frontend/channel_page.cr src/invidious/views/components/channel_info.ecr src/invidious/popular.cr spec/invidious/shorts_spec.cr
git commit -m "feat: filter shorts from mixed surfaces"
```

## Task 6: Backfill Job

**Files:**
- Create: `src/invidious/jobs/backfill_shorts_job.cr`
- Modify: `src/invidious.cr`
- Modify: `spec/invidious/shorts_database_spec.cr`

- [ ] **Step 1: Add database specs for backfill query limits**

Append to `spec/invidious/shorts_database_spec.cr`:

```crystal
Spectator.describe Invidious::Database::ChannelVideos do
  describe ".select_unclassified_shorts_channels_query" do
    it "limits backfill scope to recent unknown rows" do
      query = described_class.select_unclassified_shorts_channels_query

      expect(query.includes?("published >= now() - interval '180 days'")).to be_true
      expect(query.includes?("is_short IS NULL")).to be_true
    end
  end
end
```

Run:

```bash
crystal spec spec/invidious/shorts_database_spec.cr
```

Expected: pass if Task 2 already implemented the query.

- [ ] **Step 2: Implement bounded, restartable backfill job**

Create `src/invidious/jobs/backfill_shorts_job.cr`:

```crystal
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
```

- [ ] **Step 3: Register the backfill job**

In `src/invidious.cr`, after `PullPopularVideosJob` registration and before `RefreshFeedsJob` registration, add:

```crystal
Invidious::Jobs.register Invidious::Jobs::BackfillShortsJob.new
```

The job is low-rate and no-ops when no recent unknown rows exist.

- [ ] **Step 4: Run compile check and commit**

Run:

```bash
crystal build src/invidious.cr -Dskip_videojs_download --no-codegen --error-trace
```

Expected: compile succeeds.

Run:

```bash
git add src/invidious/jobs/backfill_shorts_job.cr src/invidious.cr spec/invidious/shorts_database_spec.cr
git commit -m "feat: backfill shorts classification"
```

## Task 7: Full Verification, Container, And Deployment Handoff

- [ ] **Step 1: Format Crystal files**

Run:

```bash
crystal tool format
```

Expected: command exits 0. Review `git diff` after formatting and keep only formatting for touched Crystal files.

- [ ] **Step 2: Run focused specs**

Run:

```bash
crystal spec spec/invidious/shorts_spec.cr spec/invidious/shorts_extractors_spec.cr spec/invidious/shorts_database_spec.cr spec/invidious/popular_spec.cr spec/invidious/popular_database_spec.cr
```

Expected: all focused specs pass.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
crystal spec
```

Expected: all specs pass.

- [ ] **Step 4: Run compile verification**

Run:

```bash
make verify
```

Expected: Crystal compile verification succeeds with `--no-codegen`.

- [ ] **Step 5: Confirm no duration-based Shorts classification exists**

Run:

```bash
rg -n "is_short.*length|length.*is_short|duration.*is_short|is_short.*duration|60.*is_short|isShort.*length|length.*isShort" src spec
```

Expected: no matches that classify Shorts from duration. Existing duration parsing for display is acceptable only when it does not set `is_short` from duration.

- [ ] **Step 6: Commit final fixes**

If verification changed files, commit the verification fixes:

```bash
git status --short
git add src spec config locales
git commit -m "fix: harden shorts hiding"
```

If there are no fixes, do not create an empty commit.

- [ ] **Step 7: Push and publish container**

Run:

```bash
git status --short
git push origin master
```

Expected: working tree is clean before push, and push succeeds.

Monitor the existing GHCR workflow for `ghcr.io/shayne/invidious:latest`. Once successful, record the image digest.

- [ ] **Step 8: Redeploy yeet service**

In `/Users/shayne/yeet-services`, run:

```bash
yeet docker update invidious
```

Expected: Invidious restarts with the new `ghcr.io/shayne/invidious:latest` image.

- [ ] **Step 9: Run production smoke checks**

Run:

```bash
curl -fsS https://vid.puffyan.us/api/v1/stats
curl -fsS 'https://vid.puffyan.us/api/v1/popular?range=day' | jq 'length'
curl -fsS 'https://vid.puffyan.us/feed/popular?range=day' | rg 'Popular|Day'
```

Expected: stats endpoint returns JSON, Popular API returns a JSON array length, and Popular page renders.

Manually confirm the preferences page contains "Hide YouTube Shorts" and that direct `/shorts/:id` redirects to watch as before.
