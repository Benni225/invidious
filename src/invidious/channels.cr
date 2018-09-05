class InvidiousChannel
  add_mapping({
    id:      String,
    author:  String,
    updated: Time,
  })
end

class ChannelVideo
  add_mapping({
    id:        String,
    title:     String,
    published: Time,
    updated:   Time,
    ucid:      String,
    author:    String,
  })
end

def get_channel(id, client, db, refresh = true, pull_all_videos = true)
  if db.query_one?("SELECT EXISTS (SELECT true FROM channels WHERE id = $1)", id, as: Bool)
    channel = db.query_one("SELECT * FROM channels WHERE id = $1", id, as: InvidiousChannel)

    if refresh && Time.now - channel.updated > 10.minutes
      channel = fetch_channel(id, client, db, pull_all_videos)
      channel_array = channel.to_a
      args = arg_array(channel_array)

      db.exec("INSERT INTO channels VALUES (#{args}) \
        ON CONFLICT (id) DO UPDATE SET updated = $3", channel_array)
    end
  else
    channel = fetch_channel(id, client, db, pull_all_videos)
    args = arg_array(channel.to_a)
    db.exec("INSERT INTO channels VALUES (#{args})", channel.to_a)
  end

  return channel
end

def fetch_channel(ucid, client, db, pull_all_videos = true)
  rss = client.get("/feeds/videos.xml?channel_id=#{ucid}").body
  rss = XML.parse_html(rss)

  author = rss.xpath_node(%q(//feed/title))
  if !author
    raise "Deleted or invalid channel"
  end
  author = author.content

  if !pull_all_videos
    rss.xpath_nodes("//feed/entry").each do |entry|
      video_id = entry.xpath_node("videoid").not_nil!.content
      title = entry.xpath_node("title").not_nil!.content
      published = Time.parse(entry.xpath_node("published").not_nil!.content, "%FT%X%z", Time::Location.local)
      updated = Time.parse(entry.xpath_node("updated").not_nil!.content, "%FT%X%z", Time::Location.local)
      author = entry.xpath_node("author/name").not_nil!.content
      ucid = entry.xpath_node("channelid").not_nil!.content

      video = ChannelVideo.new(video_id, title, published, Time.now, ucid, author)

      db.exec("UPDATE users SET notifications = notifications || $1 \
        WHERE updated < $2 AND $3 = ANY(subscriptions) AND $1 <> ALL(notifications)", video.id, video.published, ucid)

      video_array = video.to_a
      args = arg_array(video_array)
      db.exec("INSERT INTO channel_videos VALUES (#{args}) \
        ON CONFLICT (id) DO UPDATE SET title = $2, published = $3, \
        updated = $4, ucid = $5, author = $6", video_array)
    end
  else
    videos = [] of ChannelVideo
    page = 1

    loop do
      url = produce_channel_videos_url(ucid, page)
      response = client.get(url)

      json = JSON.parse(response.body)
      content_html = json["content_html"].as_s
      if content_html.empty?
        # If we don't get anything, move on
        break
      end
      document = XML.parse_html(content_html)

      document.xpath_nodes(%q(//li[contains(@class, "feed-item-container")])).each do |item|
        anchor = item.xpath_node(%q(.//h3[contains(@class,"yt-lockup-title")]/a))
        if !anchor
          raise "could not find anchor"
        end

        title = anchor.content.strip
        video_id = anchor["href"].lchop("/watch?v=")

        published = item.xpath_node(%q(.//div[@class="yt-lockup-meta"]/ul/li[1]))
        if !published
          # This happens on Youtube red videos, here we just skip them
          next
        end
        published = published.content
        published = decode_date(published)

        videos << ChannelVideo.new(video_id, title, published, Time.now, ucid, author)
      end

      if document.xpath_nodes(%q(//li[contains(@class, "channels-content-item")])).size < 30
        break
      end

      page += 1
    end

    video_ids = [] of String
    videos.each do |video|
      db.exec("UPDATE users SET notifications = notifications || $1 \
        WHERE updated < $2 AND $3 = ANY(subscriptions) AND $1 <> ALL(notifications)", video.id, video.published, ucid)
      video_ids << video.id

      video_array = video.to_a
      args = arg_array(video_array)
      db.exec("INSERT INTO channel_videos VALUES (#{args}) ON CONFLICT (id) DO NOTHING", video_array)
    end

    # When a video is deleted from a channel, we find and remove it here
    db.exec("DELETE FROM channel_videos * WHERE NOT id = ANY ('{#{video_ids.map { |a| %("#{a}") }.join(",")}}') AND ucid = $1", ucid)
  end

  channel = InvidiousChannel.new(ucid, author, Time.now)

  return channel
end

def produce_channel_videos_url(ucid, page = 1, auto_generated = nil)
  if auto_generated
    seed = Time.epoch(1525757349)

    until seed >= Time.now
      seed += 1.month
    end
    timestamp = seed - (page - 1).months

    page = "#{timestamp.epoch}"
    switch = "\x36"
  else
    page = "#{page}"
    switch = "\x00"
  end

  meta = "\x12\x06videos #{switch}\x30\x02\x38\x01\x60\x01\x6a\x00\x7a"
  meta += page.size.to_u8.unsafe_chr
  meta += page
  meta += "\xb8\x01\x00"

  meta = Base64.urlsafe_encode(meta)
  meta = URI.escape(meta)

  continuation = "\x12"
  continuation += ucid.size.to_u8.unsafe_chr
  continuation += ucid
  continuation += "\x1a"
  continuation += meta.size.to_u8.unsafe_chr
  continuation += meta

  continuation = continuation.size.to_u8.unsafe_chr + continuation
  continuation = "\xe2\xa9\x85\xb2\x02" + continuation

  continuation = Base64.urlsafe_encode(continuation)
  continuation = URI.escape(continuation)

  url = "/browse_ajax?continuation=#{continuation}"

  return url
end
