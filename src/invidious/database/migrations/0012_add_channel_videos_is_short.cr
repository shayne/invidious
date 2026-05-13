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
