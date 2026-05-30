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

  it "marks videoRenderer with LIVE overlay as live now" do
    item = parse_search_item(%({
      "videoRenderer": {
        "videoId": "LIVEOVER01",
        "title": { "runs": [{ "text": "Live video" }] },
        "ownerText": { "runs": [{ "text": "Fallback Author", "navigationEndpoint": { "browseEndpoint": { "browseId": "UCFALLBACK" } } }] },
        "viewCountText": { "runs": [{ "text": "123" }, { "text": " watching" }] },
        "thumbnailOverlays": [{
          "thumbnailOverlayTimeStatusRenderer": {
            "text": { "simpleText": "LIVE" }
          }
        }]
      }
    }))

    video = item.as(SearchVideo)
    expect(video.badges.live_now?).to be_true
    expect(video.length_seconds).to eq(0)
    expect(video.is_short).to be_nil
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

  it "parses normal video lockupViewModel duration from thumbnail bottom overlays" do
    item = parse_search_item(%({
      "lockupViewModel": {
        "contentId": "NORMALLOCK1",
        "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
        "contentImage": {
          "thumbnailViewModel": {
            "image": {
              "sources": [{
                "url": "https://i.ytimg.com/vi/NORMALLOCK1/hqdefault.jpg",
                "width": 168,
                "height": 94
              }]
            },
            "overlays": [{
              "thumbnailBottomOverlayViewModel": {
                "badges": [{
                  "thumbnailBadgeViewModel": {
                    "text": "12:34"
                  }
                }]
              }
            }]
          }
        },
        "metadata": {
          "lockupMetadataViewModel": {
            "title": { "content": "Normal lockup video" },
            "metadata": {
              "contentMetadataViewModel": {
                "metadataRows": [{
                  "metadataParts": [
                    { "text": { "content": "1.2K views" } },
                    { "text": { "content": "1 day ago" } }
                  ]
                }]
              }
            }
          }
        },
        "rendererContext": {
          "commandContext": {
            "onTap": {
              "innertubeCommand": {
                "watchEndpoint": {
                  "videoId": "NORMALLOCK1"
                }
              }
            }
          }
        }
      }
    }))

    video = item.as(SearchVideo)
    expect(video.id).to eq("NORMALLOCK1")
    expect(video.title).to eq("Normal lockup video")
    expect(video.length_seconds).to eq(754)
    expect(video.views).to eq(1200)
    expect(video.ucid).to eq("UCFALLBACK")
    expect(video.author).to eq("Fallback Author")
    expect(video.is_short).to be_nil
  end
end
