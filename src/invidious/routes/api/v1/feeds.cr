module Invidious::Routes::API::V1::Feeds
  def self.trending(env)
    locale = env.get("preferences").as(Preferences).locale

    env.response.content_type = "application/json"

    region = env.params.query["region"]?
    trending_type = env.params.query["type"]?

    begin
      trending, plid = fetch_trending(trending_type, region, locale)
    rescue ex
      return error_json(500, ex)
    end

    videos = JSON.build do |json|
      json.array do
        trending.each do |video|
          video.to_json(locale, json)
        end
      end
    end

    videos
  end

  def self.popular(env)
    preferences = env.get("preferences").as(Preferences)
    locale = preferences.locale

    env.response.content_type = "application/json"

    if !CONFIG.popular_enabled
      error_message = {"error" => "Administrator has disabled this endpoint."}.to_json
      haltf env, 403, error_message
    end

    popular_range = Invidious::Popular.parse_range(env.params.query["range"]?)

    JSON.build do |json|
      json.array do
        popular_videos(popular_range, hide_shorts: preferences.hide_shorts).each do |video|
          video.to_json(locale, json)
        end
      end
    end
  end
end
