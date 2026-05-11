# Invidious Popular Nowcast Design

## Goal

Replace the existing Popular feed ranking with an Invidious-native version of the `ytsubs` nowcast algorithm while preserving the current Invidious Popular feed concept: an instance-wide feed based on channels that local users subscribe to.

The feature adds time range facets to the web Popular tab and `/api/v1/popular`:

- `day`: Last 2 days
- `week`: Last week
- `twoweeks`: Last 2 weeks
- `month`: Last month

## Current Behavior

The current Popular feed is populated by `Invidious::Jobs::PullPopularVideosJob`. That job asks the database for one latest video from each of the top 40 most-subscribed channels on the instance, sorts those videos by publish time, and stores them in an in-memory cache.

The web route `/feed/popular` renders the cached list through `src/invidious/views/feeds/popular.ecr`. The API route `/api/v1/popular` returns the same cached list as standard Invidious video JSON.

## Source Model

Popular remains an instance-wide feed. It is not personalized to the logged-in user.

Candidate videos come from all channels that appear in the instance subscription graph:

```sql
SELECT DISTINCT UNNEST(subscriptions) AS ucid
FROM users
```

The ranking query must consider every subscribed channel, not just the top N channels by local subscriber count. To keep the query bounded, candidate videos are restricted by the selected time range, with `month` as the maximum window used by the cache.

## Range Facets

The web Popular route accepts:

```text
/feed/popular?range=day
/feed/popular?range=week
/feed/popular?range=twoweeks
/feed/popular?range=month
```

`range` defaults to `day`. Invalid or missing values fall back to `day`.

`/api/v1/popular` accepts the same optional `range=` parameter and returns standard video JSON in the new ranked order.

## Ranking Algorithm

The ranking uses the same shape as `ytsubs`, adapted to data Invidious already has or can derive from local database state.

For each candidate video:

1. Compute video age in hours from `channel_videos.published`.
2. Use `channel_videos.views` as the current view count.
3. Derive a per-channel 48-hour baseline from recent `channel_videos` history.
4. Use local subscription count for the channel as the reach denominator.
5. Use `channel_videos.length_seconds` for the duration prior.

The score is:

```text
core =
  0.55 * norm_ratio(relative_nowcast)
+ 0.20 * norm_ratio(velocity_shock)
+ 0.15 * norm_reach(instance_reach)
+ 0.05 * duration_prior
```

Then apply:

```text
score = (core * confidence_multiplier) + early_breakout_boost
```

### Nowcast vs Expected

`relative_nowcast` compares current views to expected views at the video's current age:

```text
expected_views_now = max(1, baseline_48h * age_curve_fraction_48h(age_hours))
relative_nowcast = current_views / expected_views_now
```

The age curve is ported from `ytsubs`:

- `age_hours <= 0`: `0.03`
- `0 < age_hours <= 8`: grows linearly from `0.03` to `0.60`
- `8 < age_hours < 48`: grows linearly from `0.60` to `0.95`
- `age_hours >= 48`: `0.95`

### Velocity Shock

`velocity_shock` compares current views/hour to expected views/hour at the video's age:

```text
views_per_hour = current_views / max(age_hours, 1)
expected_vph = max(1, baseline_48h * age_curve_expected_slope(age_hours))
velocity_shock = views_per_hour / expected_vph
```

The expected slope curve is ported from `ytsubs`:

- `age_hours <= 8`: `0.075`
- `8 < age_hours < 48`: `0.00875`
- `age_hours >= 48`: `0.001`

### Instance Reach

`instance_reach` replaces `ytsubs` subscriber reach:

```text
instance_reach = current_views / max(local_subscription_count, 1)
```

`local_subscription_count` is the number of local users whose `subscriptions` array contains the video's channel ID. This keeps the signal local to the Invidious instance and avoids extra YouTube scraping.

### Duration Prior

The duration prior is ported from `ytsubs`:

- missing or invalid duration: `0.5`
- `< 2 minutes`: `0.35`
- `2-10 minutes`: `0.6`
- `10-30 minutes`: `1.0`
- `30-60 minutes`: `0.7`
- `>= 60 minutes`: `0.5`

### Normalization

`norm_ratio(value, cap = 6.0)`:

```text
if value <= 0: 0
else: clamp(log1p(value) / log1p(cap), 0, 1)
```

`norm_reach(reach)`:

```text
if reach <= 0: 0
else: clamp(sqrt(reach * 10), 0, 1)
```

### Confidence Multiplier

The confidence multiplier reflects baseline quality:

- high confidence for channels with enough recent videos to derive a baseline
- lower confidence when the baseline is sparse
- lower confidence when the video has no view count

The multiplier is clamped between `0.75` and `1.05`, matching the `ytsubs` range.

### Early Breakout Boost

The early breakout boost is ported from `ytsubs`:

```text
if age_hours > 6: 0
if relative_nowcast < 1.2 or velocity_shock < 1.2: 0
else clamp(0.03 * log1p(relative_nowcast * velocity_shock), 0, 0.12)
```

## Baseline Derivation

The implementation derives `baseline_48h` from local `channel_videos` rows.

Preferred baseline:

1. Use recent videos from the same channel with non-zero views.
2. Prefer videos older than 48 hours, because their current views are a usable 48-hour-ish proxy.
3. Use a robust aggregate such as median, or a trimmed average if median is awkward in PostgreSQL/Crystal.

Fallbacks:

1. If there are only sparse same-channel rows, use the average of available same-channel non-zero views.
2. If same-channel data is absent, use the current video's views with a minimum of `1`.

The scoring layer also receives a baseline sample count so it can lower confidence for sparse baselines.

## Cache and Data Flow

`PullPopularVideosJob` changes from a single cached list to a range-aware cache.

The job refreshes ranked lists for:

- `day`
- `week`
- `twoweeks`
- `month`

Each cached entry contains the standard `ChannelVideo` plus its computed score. The web and API routes use the selected range to read from the cache.

The job should refresh on the same broad cadence as today unless implementation profiling shows the all-subscribed-channel query needs a longer interval. The query must first restrict candidates to the maximum needed time window before ranking.

## Web UX

`/feed/popular` keeps the standard Invidious feed layout and video cards.

Add a compact range selector above the grid:

- `Last 2 days`
- `Last week`
- `Last 2 weeks`
- `Last month`

The active range is shown as selected text or bold text, following the existing style used by nearby feed pages such as Trending. The selector updates the URL using `?range=...`.

Do not add score badges, popovers, or ytsubs-style cards in this pass.

## API UX

`/api/v1/popular` accepts `range=day|week|twoweeks|month`.

The endpoint returns the same JSON shape as today. It does not expose scores by default.

Invalid `range` values fall back to `day`.

## Testing

Add focused specs for:

- range parsing and fallback behavior
- nowcast scoring where an early breakout outranks an older high-view video
- month-window behavior where a strong older video can appear after being excluded from shorter windows
- all-subscribed-channel behavior where a low-local-subscription channel is still considered
- API range behavior returning ranked standard video JSON

Where route-level setup is too heavy, keep algorithm and database-query tests close to the new ranking module and cover routes with smaller smoke tests.

## Non-Goals

- Do not personalize Popular by logged-in user.
- Do not scrape YouTube subscriber counts.
- Do not add ytsubs-style score badges or score detail popovers.
- Do not change the Trending feed.
- Do not change subscription feed ranking.
