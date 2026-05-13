require "../../spec_helper"
require "../../../src/invidious/jobs/base_job"
require "../../../src/invidious/jobs"
require "../../../src/invidious/config"

{% unless @top_level.has_constant?(:CONFIG) %}
  CONFIG = Config.from_yaml(File.open("config/config.example.yml"))
{% end %}

{% unless @top_level.has_constant?(:MAX_ITEMS_PER_PAGE) %}
  MAX_ITEMS_PER_PAGE = 1500
{% end %}

require "../../../src/invidious/user/preferences"
require "../../../src/invidious/user/user"
require "../../../src/invidious/shorts"
require "../../../src/invidious/search/filters"
require "../../../src/invidious/search/query"
require "../../../src/invidious/search/processors"

require "http/params"

private def query_process_search_video(id : String, is_short : Bool?) : SearchVideo
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

Spectator.describe Invidious::Search::Query do
  describe "#filter_youtube_items" do
    it "keeps the raw YouTube page-size next-page signal before filtering Shorts" do
      query = described_class.new(
        HTTP::Params.parse("q=chips"),
        Invidious::Search::Query::Type::Regular, nil
      )
      items = [] of SearchItem
      (1..20).each do |index|
        items << query_process_search_video("video#{index}", index == 1 ? true : false)
      end

      filtered = query.filter_youtube_items(items, hide_shorts: true)

      expect(filtered.size).to eq(19)
      expect(query.has_next_page?).to be_true
    end

    it "does not advertise another page when the raw YouTube page is short" do
      query = described_class.new(
        HTTP::Params.parse("q=chips"),
        Invidious::Search::Query::Type::Regular, nil
      )
      items = [] of SearchItem
      (1..19).each do |index|
        items << query_process_search_video("video#{index}", false)
      end

      query.filter_youtube_items(items, hide_shorts: true)

      expect(query.has_next_page?).to be_false
    end
  end
end
