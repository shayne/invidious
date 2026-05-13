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

    it "limits backfill scope to recent unknown rows" do
      query = described_class.select_unclassified_shorts_channels_query

      expect(query.includes?("published >= now() - interval '180 days'")).to be_true
      expect(query.includes?("is_short IS NULL")).to be_true
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
