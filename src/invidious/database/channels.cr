require "./base.cr"
require "../popular"

#
# This module contains functions related to the "channels" table.
#
module Invidious::Database::Channels
  extend self

  # -------------------
  #  Insert / delete
  # -------------------

  def insert(channel : InvidiousChannel, update_on_conflict : Bool = false)
    channel_array = channel.to_a

    request = <<-SQL
      INSERT INTO channels
      VALUES (#{arg_array(channel_array)})
    SQL

    if update_on_conflict
      request += <<-SQL
        ON CONFLICT (id) DO UPDATE
        SET author = $2, updated = $3
      SQL
    end

    PG_DB.exec(request, args: channel_array)
  end

  # -------------------
  #  Update
  # -------------------

  def update_author(id : String, author : String)
    request = <<-SQL
      UPDATE channels
      SET updated = now(), author = $1, deleted = false
      WHERE id = $2
    SQL

    PG_DB.exec(request, author, id)
  end

  def update_subscription_time(id : String)
    request = <<-SQL
      UPDATE channels
      SET subscribed = now()
      WHERE id = $1
    SQL

    PG_DB.exec(request, id)
  end

  def update_mark_deleted(id : String)
    request = <<-SQL
      UPDATE channels
      SET updated = now(), deleted = true
      WHERE id = $1
    SQL

    PG_DB.exec(request, id)
  end

  # -------------------
  #  Select
  # -------------------

  def select(id : String) : InvidiousChannel?
    request = <<-SQL
      SELECT * FROM channels
      WHERE id = $1
    SQL

    return PG_DB.query_one?(request, id, as: InvidiousChannel)
  end

  def select(ids : Array(String)) : Array(InvidiousChannel)?
    return [] of InvidiousChannel if ids.empty?

    request = <<-SQL
      SELECT * FROM channels
      WHERE id = ANY($1)
    SQL

    return PG_DB.query_all(request, ids, as: InvidiousChannel)
  end
end

#
# This module contains functions related to the "channel_videos" table.
#
module Invidious::Database::ChannelVideos
  extend self

  # -------------------
  #  Insert
  # -------------------

  # This function returns the status of the query (i.e: success?)
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

  # -------------------
  #  Select
  # -------------------

  def select(ids : Array(String)) : Array(ChannelVideo)
    return [] of ChannelVideo if ids.empty?

    request = <<-SQL
      SELECT * FROM channel_videos
      WHERE id = ANY($1)
      ORDER BY published DESC
    SQL

    return PG_DB.query_all(request, ids, as: ChannelVideo)
  end

  def select_notfications(ucid : String, since : Time) : Array(ChannelVideo)
    request = <<-SQL
      SELECT * FROM channel_videos
      WHERE ucid = $1 AND published > $2
      ORDER BY published DESC
      LIMIT 15
    SQL

    return PG_DB.query_all(request, ucid, since, as: ChannelVideo)
  end

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
        cv.is_short,
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
            AND cv2.is_short IS DISTINCT FROM TRUE
          ORDER BY cv2.published DESC
          LIMIT 20
        ) sample
      ) baseline ON true
      WHERE cv.published >= now() - ($1::interval)
        AND cv.published <= now()
    SQL
  end

  def select_popular_candidates(range : Invidious::Popular::Range) : Array(Invidious::Popular::Candidate)
    interval = "#{range.days} days"

    PG_DB.query_all(popular_candidates_query, interval, as: Invidious::Popular::CandidateRow)
      .map(&.to_candidate)
  end
end
