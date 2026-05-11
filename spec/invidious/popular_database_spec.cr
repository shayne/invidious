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
