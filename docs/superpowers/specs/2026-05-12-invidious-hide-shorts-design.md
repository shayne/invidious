# Per-User YouTube Shorts Hiding

## Purpose

Add a per-user preference that hides YouTube Shorts from mixed Invidious surfaces without blocking direct access to Shorts. The implementation must use durable Shorts metadata, not a duration heuristic.

The main goal is to make subscriptions, Popular, search, and mixed channel views usable for people who do not want Shorts in those feeds while preserving normal Invidious behavior for direct links and explicit Shorts pages.

## Current State

Invidious already has explicit Shorts routes and parsers:

- `/channel/:ucid/shorts` and `/api/v1/channels/:ucid/shorts` fetch a channel's Shorts tab.
- `/shorts/:id` redirects to the normal watch route.
- `ReelItemRendererParser` and `ShortsLockupViewModelParser` parse YouTube Shorts-specific structures.

The durable data model does not currently know whether a `ChannelVideo` is a YouTube Short. The `channel_videos` table has no Shorts column, and `ChannelVideo#to_json` emits `"type": "shortVideo"` for all channel videos, so that field cannot be used as a Shorts signal.

## Requirements

- Add `hide_shorts` as a per-user preference, defaulting to false.
- Allow admins to set the default preference through `default_user_preferences`.
- Hide only confirmed Shorts from mixed feeds and results.
- Keep unclassified historical videos visible until they are classified.
- Keep direct Shorts access available.
- Do not use duration, aspect ratio guesses, title text, thumbnail shape, or URL guesses as classification sources.
- Persist Shorts classification in the database so it improves over time and survives process restarts.
- Do not repurpose existing API `type` fields for Shorts detection.

## Non-Goals

- Do not block playback of a known Short when a user explicitly opens the video.
- Do not remove the existing Shorts routes or API endpoints.
- Do not classify old videos by duration.
- Do not personalize the global Popular ranking cache beyond filtering what an individual user sees.

## Data Model

Add nullable Shorts identity to video list models and stored channel videos.

`SearchVideo` gets:

```crystal
property is_short : Bool? = nil
```

`ChannelVideo` gets:

```crystal
property is_short : Bool? = nil
```

`channel_videos` gets:

```sql
is_short boolean NULL
```

Meaning:

- `true`: confirmed YouTube Short.
- `false`: confirmed not a YouTube Short.
- `NULL`: not classified yet.

Unknown values stay visible when `hide_shorts` is enabled. Filtering should use `is_short IS DISTINCT FROM TRUE`, not `is_short = false`.

API JSON for `SearchVideo` and `ChannelVideo` should expose a dedicated `isShort` field with `true`, `false`, or `null`. Existing `type` fields should remain compatible with current API shape and should not be treated as Shorts identity.

## Classification Sources

Only explicit YouTube Shorts structures or explicit YouTube tabs may classify a video as a Short.

Confirmed Short:

- `ReelItemRendererParser`.
- `ShortsLockupViewModelParser`.
- `thumbnailOverlayTimeStatusRenderer` with text exactly `"SHORTS"`.
- Items returned from `Channel::Tabs.get_shorts`.

Confirmed non-Short:

- Items returned from the explicit channel Videos tab, as long as the parser did not produce a Shorts signal for the item.

Unknown:

- RSS/PubSub entries when no matching channel tab or parser metadata is available.
- Existing rows before backfill classifies them.
- Any item from a source that does not provide an explicit Shorts/non-Short signal.

Duration must never be used for Shorts classification.

## Preference

Add `hide_shorts : Bool = false` to:

- `ConfigPreferences`, for instance defaults.
- `Preferences`, for user/cookie preferences.
- The preferences form.
- Authenticated preferences API serialization and deserialization through the existing `Preferences` model.
- Import/export through existing preference JSON behavior.

The label should be direct, for example "Hide YouTube Shorts".

## Filtering Scope

When `hide_shorts` is enabled, confirmed Shorts are hidden from mixed surfaces:

- Popular page and `/api/v1/popular`.
- Subscription feed.
- Subscription search.
- General search and channel search results.
- Channel Videos tab.
- Mixed related/recommended lists where the item model carries `is_short`.
- Feed notifications and subscription feed display.

Direct access remains available:

- `/shorts/:id`.
- `/watch?v=...`.
- Explicit channel Shorts tab route when opened directly.
- `/api/v1/channels/:ucid/shorts`.

Channel navigation should hide the Shorts tab link when `hide_shorts` is enabled, but the route should still work if opened directly.

## Popular Behavior

Popular remains instance-wide.

The global Popular job can continue to compute a shared ranked cache. Per-user filtering should remove confirmed Shorts from the returned list when `hide_shorts` is enabled. Since the scorer produces per-video scores, filtering after ranking preserves the order of non-Shorts.

Candidate rows should include `is_short`. Baseline calculations should ignore confirmed Shorts when scoring normal videos where the data is available, so Shorts-heavy channel history does not distort normal-video baselines. Unknown rows remain eligible and visible until classified.

## Migration

Add a migration that:

1. Adds `channel_videos.is_short boolean NULL`.
2. Adds an index for hidden-Shorts feed queries:

   ```sql
   CREATE INDEX IF NOT EXISTS channel_videos_ucid_published_not_shorts_idx
     ON public.channel_videos
     USING btree (ucid COLLATE pg_catalog."default", published DESC)
     WHERE is_short IS DISTINCT FROM TRUE;
   ```

3. Marks subscription materialized views stale:

   ```sql
   UPDATE users SET feed_needs_update = true;
   ```

`RefreshFeedsJob` already compares materialized view columns against `ChannelVideo.type_array` and recreates stale views. Marking users stale ensures existing subscription views converge to the new column shape.

The migration must not classify rows by duration.

## Backfill

Backfill should be a background job, not a blocking migration.

For channels with recent `channel_videos.is_short IS NULL` rows:

1. Fetch explicit Shorts tab pages.
2. Mark matching stored video IDs `is_short = true`.
3. Fetch explicit Videos tab pages.
4. Mark matching stored video IDs `is_short = false`, but only where `is_short IS NULL`.
5. Leave unresolved rows as `NULL`.

The job should batch work, sleep between channels, tolerate failures, and be restartable. It should prefer recent unclassified rows first because those are most visible in feeds and Popular.

## Data Flow

New fetches:

1. YouTube data is parsed into `SearchVideo` with `is_short` when the parser knows it.
2. Channel refresh, full refresh, and PubSub ingestion copy `is_short` into `ChannelVideo` when available.
3. `ChannelVideos.insert` writes and updates `is_short` without overwriting a confirmed value with unknown.

Reads:

1. Routes load user preferences from the existing request context.
2. Mixed feed/search routes filter confirmed Shorts when `preferences.hide_shorts` is true.
3. Direct Shorts/watch routes ignore the preference.

## Error Handling

- Parser changes from YouTube should degrade to `is_short = nil`, not false.
- Backfill failures should log and continue with other channels.
- Unknown rows must remain visible.
- Existing user preferences without `hide_shorts` should deserialize with the default false value.

## Testing

Add focused tests for:

- Parser classification of `reelItemRenderer`, `shortsLockupViewModel`, and `"SHORTS"` overlay.
- `ChannelVideo` and `SearchVideo` JSON output includes dedicated nullable `isShort`.
- Preference parsing and form update for `hide_shorts`.
- Subscription feed SQL excludes only `is_short = true`.
- Popular filtering hides confirmed Shorts but keeps unknowns.
- Channel tab navigation hides the Shorts link while direct Shorts route remains accessible.
- Migration adds the column and marks feeds stale.

## Acceptance Criteria

- A user can enable "Hide YouTube Shorts" in preferences.
- Confirmed Shorts disappear from mixed feeds/results for that user.
- Unknown videos remain visible.
- Direct Shorts/watch URLs continue to work.
- New Shorts are stored with durable `is_short = true` when fetched from explicit Shorts sources.
- Existing database rows converge over time through authoritative backfill.
- No duration-based Shorts classification exists in the implementation.
