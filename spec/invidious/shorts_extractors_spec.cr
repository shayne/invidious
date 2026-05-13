require "../spec_helper"
require "../../src/invidious/comments/content"
require "../../src/invidious/yt_backend/extractors"
require "../../src/invidious/yt_backend/extractors_utils"

{% unless @top_level.has_constant?(:OUTPUT) %}
  OUTPUT = File.open(File::NULL, "w")
{% end %}

{% unless @top_level.has_constant?(:LOGGER) %}
  LOGGER = Invidious::LogHandler.new(OUTPUT, LogLevel::Off)
{% end %}

private def parse_search_item(raw : String) : SearchItem
  parse_item(JSON.parse(raw), "Fallback Author", "UCFALLBACK").as(SearchItem)
end

Spectator.describe "YouTube Shorts extraction" do
  it "marks reelItemRenderer results as Shorts" do
    item = parse_search_item(%({
      "reelItemRenderer": {
        "videoId": "SHORTREEL01",
        "headline": { "simpleText": "Reel short" },
        "viewCountText": { "simpleText": "1.2K views" },
        "accessibility": { "accessibilityData": { "label": "Reel short - 10 seconds - play video" } },
        "navigationEndpoint": {
          "reelWatchEndpoint": {
            "overlay": {
              "reelPlayerOverlayRenderer": {
                "reelPlayerHeaderSupportedRenderers": {
                  "reelPlayerHeaderRenderer": {
                    "reelTitleText": { "simpleText": "Reel short" },
                    "timestampText": { "simpleText": "1 day ago" },
                    "channelTitleText": { "runs": [{ "text": "Fallback Author" }] },
                    "channelNavigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } },
                    "viewCountText": { "simpleText": "1.2K views" }
                  }
                }
              }
            }
          }
        }
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks shortsLockupViewModel results as Shorts" do
    item = parse_search_item(%({
      "shortsLockupViewModel": {
        "onTap": { "innertubeCommand": { "reelWatchEndpoint": { "videoId": "SHORTLOCK01" } } },
        "overlayMetadata": {
          "primaryText": { "content": "Lockup short" },
          "secondaryText": { "content": "2K views" }
        }
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks videoRenderer with exact SHORTS overlay as Shorts" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "SHORTOVER01",
        "title": { "runs": [{ "text": "Overlay short" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "publishedTimeText": { "simpleText": "1 day ago" },
        "viewCountText": { "simpleText": "123 views" },
        "thumbnailOverlays": [{
          "thumbnailOverlayTimeStatusRenderer": {
            "text": { "simpleText": "SHORTS" }
          }
        }]
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks videoRenderer with lengthText and exact SHORTS overlay as Shorts" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "SHORTBOTH01",
        "title": { "runs": [{ "text": "Overlay short with length" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "publishedTimeText": { "simpleText": "1 day ago" },
        "viewCountText": { "simpleText": "123 views" },
        "lengthText": { "simpleText": "12:34" },
        "thumbnailOverlays": [{
          "thumbnailOverlayTimeStatusRenderer": {
            "text": { "simpleText": "SHORTS" }
          }
        }]
      }
    }))

    expect(item.as(SearchVideo).is_short).to eq(true)
  end

  it "marks ordinary videoRenderer results as unknown until tab context confirms them" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "NORMAL0001",
        "title": { "runs": [{ "text": "Normal video" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "publishedTimeText": { "simpleText": "1 day ago" },
        "viewCountText": { "simpleText": "123 views" },
        "lengthText": { "simpleText": "12:34" }
      }
    }))

    expect(item.as(SearchVideo).is_short).to be_nil
  end
end
