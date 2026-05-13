module Invidious::Shorts
  extend self

  def visible?(is_short : Bool?) : Bool
    is_short != true
  end

  def filter_channel_videos(videos : Array(ChannelVideo), *, hide_shorts : Bool) : Array(ChannelVideo)
    return videos unless hide_shorts

    videos.select { |video| visible?(video.is_short) }
  end

  def filter_search_items(items : Array(SearchItem), *, hide_shorts : Bool) : Array(SearchItem)
    return items unless hide_shorts

    filtered = [] of SearchItem
    items.each do |item|
      if item.is_a?(SearchVideo) && !visible?(item.is_short)
        next
      end

      filtered << item
    end
    filtered
  end

  def mark_from_shorts_tab(items : Array(SearchItem)) : Array(SearchItem)
    mark_search_videos(items) { true }
  end

  def mark_from_videos_tab(items : Array(SearchItem)) : Array(SearchItem)
    mark_search_videos(items) do |video|
      video.is_short == true ? true : false
    end
  end

  private def mark_search_videos(items : Array(SearchItem), & : SearchVideo -> Bool?) : Array(SearchItem)
    marked = [] of SearchItem

    items.each do |item|
      case item
      when SearchVideo
        marked << item.with_is_short(yield item)
      else
        marked << item
      end
    end

    marked
  end
end
