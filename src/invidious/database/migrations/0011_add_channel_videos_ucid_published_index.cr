module Invidious::Database::Migrations
  class AddChannelVideosUcidPublishedIndex < Migration
    version 11

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      CREATE INDEX IF NOT EXISTS channel_videos_ucid_published_idx
        ON public.channel_videos
        USING btree
        (ucid COLLATE pg_catalog."default", published DESC);
      SQL
    end
  end
end
