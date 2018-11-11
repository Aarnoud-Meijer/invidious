class Config
  YAML.mapping({
    crawl_threads:   Int32,
    channel_threads: Int32,
    feed_threads:    Int32,
    video_threads:   Int32,
    db:              NamedTuple(
      user: String,
      password: String,
      host: String,
      port: Int32,
      dbname: String,
    ),
    dl_api_key:   String?,
    https_only:   Bool?,
    hmac_key:     String?,
    full_refresh: Bool,
    geo_bypass:   Bool,
  })
end

def login_req(login_form, f_req)
  data = {
    "pstMsg"          => "1",
    "checkConnection" => "youtube",
    "checkedDomains"  => "youtube",
    "hl"              => "en",
    "deviceinfo"      => %q([null,null,null,[],null,"US",null,null,[],"GlifWebSignIn",null,[null,null,[]]]),
    "f.req"           => f_req,
    "flowName"        => "GlifWebSignIn",
    "flowEntry"       => "ServiceLogin",
  }

  data = login_form.merge(data)

  return HTTP::Params.encode(data)
end

def generate_captcha(key)
  minute = Random::Secure.rand(12)
  minute_angle = minute * 30
  minute = minute * 5

  hour = Random::Secure.rand(12)
  hour_angle = hour * 30 + minute_angle.to_f / 12
  if hour == 0
    hour = 12
  end

  clock_svg = <<-END_SVG
  <svg viewBox="0 0 100 100" width="200px">
  <circle cx="50" cy="50" r="45" fill="#eee" stroke="black" stroke-width="2"></circle>
  
  <text x="69"     y="20.091" text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 1</text>
  <text x="82.909" y="34"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 2</text>
  <text x="88"     y="53"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 3</text>
  <text x="82.909" y="72"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 4</text>
  <text x="69"     y="85.909" text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 5</text>
  <text x="50"     y="91"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 6</text>
  <text x="31"     y="85.909" text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 7</text>
  <text x="17.091" y="72"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 8</text>
  <text x="12"     y="53"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px"> 9</text>
  <text x="17.091" y="34"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px">10</text>
  <text x="31"     y="20.091" text-anchor="middle" fill="black" font-family="Arial" font-size="10px">11</text>
  <text x="50"     y="15"     text-anchor="middle" fill="black" font-family="Arial" font-size="10px">12</text>

  <circle cx="50" cy="50" r="3" fill="black"></circle>
  <line id="minute" transform="rotate(#{minute_angle}, 50, 50)" x1="50" y1="50" x2="50" y2="16" fill="black" stroke="black" stroke-width="2"></line>
  <line id="hour"   transform="rotate(#{hour_angle}, 50, 50)" x1="50" y1="50" x2="50" y2="24" fill="black" stroke="black" stroke-width="2"></line>
  </svg>
  END_SVG

  challenge = ""
  convert = Process.run(%(convert -density 1200 -resize 400x400 -background none svg:- png:-), shell: true,
    input: IO::Memory.new(clock_svg), output: Process::Redirect::Pipe) do |proc|
    challenge = proc.output.gets_to_end
    challenge = Base64.strict_encode(challenge)
    challenge = "data:image/png;base64,#{challenge}"
  end

  answer = "#{hour}:#{minute.to_s.rjust(2, '0')}"
  token = OpenSSL::HMAC.digest(:sha256, key, answer)
  token = Base64.urlsafe_encode(token)

  return {challenge: challenge, token: token}
end

def html_to_content(description_html)
  if !description_html
    description = ""
    description_html = ""
  else
    description_html = description_html.to_s
    description = description_html.gsub("<br>", "\n")
    description = description.gsub("<br/>", "\n")

    if description.empty?
      description = ""
    else
      description = XML.parse_html(description).content.strip("\n ")
    end
  end

  return description_html, description
end

def extract_videos(nodeset, ucid = nil)
  videos = extract_items(nodeset, ucid)
  videos.select! { |item| !item.is_a?(SearchChannel | SearchPlaylist) }
  videos.map { |video| video.as(SearchVideo) }
end

def extract_items(nodeset, ucid = nil)
  # TODO: Make this a 'common', so it makes more sense to be used here
  items = [] of SearchItem

  nodeset.each do |node|
    anchor = node.xpath_node(%q(.//h3[contains(@class,"yt-lockup-title")]/a))
    if !anchor
      next
    end

    if anchor["href"].starts_with? "https://www.googleadservices.com"
      next
    end

    anchor = node.xpath_node(%q(.//div[contains(@class, "yt-lockup-byline")]/a))
    if !anchor
      author = ""
      author_id = ""
    else
      author = anchor.content.strip
      author_id = anchor["href"].split("/")[-1]
    end

    anchor = node.xpath_node(%q(.//h3[contains(@class, "yt-lockup-title")]/a))
    if !anchor
      next
    end
    title = anchor.content.strip
    id = anchor["href"]

    description_html = node.xpath_node(%q(.//div[contains(@class, "yt-lockup-description")]))
    description_html, description = html_to_content(description_html)

    tile = node.xpath_node(%q(.//div[contains(@class, "yt-lockup-tile")]))
    if !tile
      next
    end

    case tile["class"]
    when .includes? "yt-lockup-playlist"
      plid = HTTP::Params.parse(URI.parse(id).query.not_nil!)["list"]

      anchor = node.xpath_node(%q(.//div[contains(@class, "yt-lockup-meta")]/a))

      if !anchor
        anchor = node.xpath_node(%q(.//ul[@class="yt-lockup-meta-info"]/li/a))
      end

      video_count = node.xpath_node(%q(.//span[@class="formatted-video-count-label"]/b))
      if video_count
        video_count = video_count.content

        if video_count == "50+"
          author = "YouTube"
          author_id = "UC-9-kyTW8ZkZNDHQJ6FgpwQ"
          video_count = video_count.rchop("+")
        end

        video_count = video_count.to_i?
      end
      video_count ||= 0

      videos = [] of SearchPlaylistVideo
      node.xpath_nodes(%q(.//*[contains(@class, "yt-lockup-playlist-items")]/li)).each do |video|
        anchor = video.xpath_node(%q(.//a))
        if anchor
          video_title = anchor.content.strip
          id = HTTP::Params.parse(URI.parse(anchor["href"]).query.not_nil!)["v"]
        end
        video_title ||= ""
        id ||= ""

        anchor = video.xpath_node(%q(.//span/span))
        if anchor
          length_seconds = decode_length_seconds(anchor.content)
        end
        length_seconds ||= 0

        videos << SearchPlaylistVideo.new(
          video_title,
          id,
          length_seconds
        )
      end

      items << SearchPlaylist.new(
        title,
        plid,
        author,
        author_id,
        video_count,
        videos
      )
    when .includes? "yt-lockup-channel"
      author = title.strip
      ucid = id.split("/")[-1]

      author_thumbnail = node.xpath_node(%q(.//div/span/img)).try &.["data-thumb"]?
      author_thumbnail ||= node.xpath_node(%q(.//div/span/img)).try &.["src"]
      author_thumbnail ||= ""

      subscriber_count = node.xpath_node(%q(.//span[contains(@class, "yt-subscriber-count")])).try &.["title"].delete(",").to_i?
      subscriber_count ||= 0

      video_count = node.xpath_node(%q(.//ul[@class="yt-lockup-meta-info"]/li)).try &.content.split(" ")[0].delete(",").to_i?
      video_count ||= 0

      items << SearchChannel.new(
        author,
        ucid,
        author_thumbnail,
        subscriber_count,
        video_count,
        description,
        description_html
      )
    else
      id = id.lchop("/watch?v=")

      metadata = node.xpath_nodes(%q(.//div[contains(@class,"yt-lockup-meta")]/ul/li))

      begin
        published = decode_date(metadata[0].content.lchop("Streamed ").lchop("Starts "))
      rescue ex
      end
      begin
        published ||= Time.unix(metadata[0].xpath_node(%q(.//span)).not_nil!["data-timestamp"].to_i64)
      rescue ex
      end
      published ||= Time.now

      begin
        view_count = metadata[0].content.rchop(" watching").delete(",").try &.to_i64?
      rescue ex
      end
      begin
        view_count ||= metadata.try &.[1].content.delete("No views,").try &.to_i64?
      rescue ex
      end
      view_count ||= 0_i64

      length_seconds = node.xpath_node(%q(.//span[@class="video-time"]))
      if length_seconds
        length_seconds = decode_length_seconds(length_seconds.content)
      else
        length_seconds = -1
      end

      live_now = node.xpath_node(%q(.//span[contains(@class, "yt-badge-live")]))
      if live_now
        live_now = true
      else
        live_now = false
      end

      if node.xpath_node(%q(.//span[text()="Premium"]))
        premium = true
      else
        premium = false
      end

      if node.xpath_node(%q(.//span[contains(text(), "Get YouTube Premium")]))
        paid = true
      else
        paid = false
      end

      items << SearchVideo.new(
        title,
        id,
        author,
        author_id,
        published,
        view_count,
        description,
        description_html,
        length_seconds,
        live_now,
        paid,
        premium
      )
    end
  end

  return items
end

def create_response(user_id, operation, key, expire = 6.hours)
  expire = Time.now + expire
  nonce = Random::Secure.hex(4)

  challenge = "#{expire.to_unix}-#{nonce}-#{user_id}-#{operation}"
  token = OpenSSL::HMAC.digest(:sha256, key, challenge)

  challenge = Base64.urlsafe_encode(challenge)
  token = Base64.urlsafe_encode(token)

  return challenge, token
end

def validate_response(challenge, token, user_id, operation, key)
  if !challenge
    raise "Hidden field \"challenge\" is a required field"
  end

  if !token
    raise "Hidden field \"token\" is a required field"
  end

  challenge = Base64.decode_string(challenge)
  if challenge.split("-").size == 4
    expire, nonce, challenge_user_id, challenge_operation = challenge.split("-")

    expire = expire.to_i?
    expire ||= 0
  else
    raise "Invalid challenge"
  end

  challenge = OpenSSL::HMAC.digest(:sha256, HMAC_KEY, challenge)
  challenge = Base64.urlsafe_encode(challenge)

  if challenge != token
    raise "Invalid token"
  end

  if challenge_operation != operation
    raise "Invalid token"
  end

  if challenge_user_id != user_id
    raise "Invalid token"
  end

  if expire < Time.now.to_unix
    raise "Token is expired, please try again"
  end
end
