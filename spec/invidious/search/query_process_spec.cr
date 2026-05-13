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
require "../../../src/invidious/search/filters"
require "../../../src/invidious/search/query"
require "../../../src/invidious/search/processors"

require "http/params"

private def query_process_user(hide_shorts : Bool) : Invidious::User
  preferences = Preferences.from_json({"hide_shorts" => hide_shorts}.to_json)

  Invidious::User.new({
    updated:           Time.utc,
    notifications:     [] of String,
    subscriptions:     [] of String,
    email:             "user@example.com",
    preferences:       preferences,
    password:          nil,
    token:             "token",
    watched:           [] of String,
    feed_needs_update: false,
  })
end

module Invidious::Search::Processors
  class_property regular_hide_shorts : Bool? = nil
  class_property channel_hide_shorts : Bool? = nil
  class_property subscription_user_hide_shorts : Bool? = nil

  def self.reset_spec_state
    @@regular_hide_shorts = nil
    @@channel_hide_shorts = nil
    @@subscription_user_hide_shorts = nil
  end

  def self.regular(query : Query, *, hide_shorts : Bool = false) : Array(SearchItem)
    @@regular_hide_shorts = hide_shorts
    [] of SearchItem
  end

  def self.channel(query : Query, *, hide_shorts : Bool = false) : Array(SearchItem)
    @@channel_hide_shorts = hide_shorts
    [] of SearchItem
  end

  def self.subscriptions(query : Query, user : Invidious::User) : Array(ChannelVideo)
    @@subscription_user_hide_shorts = user.preferences.hide_shorts
    [] of ChannelVideo
  end
end

Spectator.describe Invidious::Search::Query do
  before_each do
    Invidious::Search::Processors.reset_spec_state
  end

  describe "#process" do
    it "passes request-level hide_shorts to regular search" do
      query = described_class.new(
        HTTP::Params.parse("q=chips"),
        Invidious::Search::Query::Type::Regular, nil
      )

      query.process(hide_shorts: true)

      expect(Invidious::Search::Processors.regular_hide_shorts).to be_true
    end

    it "passes request-level hide_shorts to channel search" do
      query = described_class.new(
        HTTP::Params.parse("q=soldering&channel=UC123456789"),
        Invidious::Search::Query::Type::Regular, nil
      )

      query.process(hide_shorts: true)

      expect(Invidious::Search::Processors.channel_hide_shorts).to be_true
    end

    it "uses the user object for subscription search preferences" do
      query = described_class.new(
        HTTP::Params.parse("q=subscriptions:true+soldering"),
        Invidious::Search::Query::Type::Regular, nil
      )
      user = query_process_user(true)

      query.process(user, hide_shorts: false)

      expect(Invidious::Search::Processors.subscription_user_hide_shorts).to be_true
    end
  end
end
