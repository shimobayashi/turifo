require 'sinatra'
require 'feed-normalizer'
require 'open-uri'
require 'rss/maker'

helpers do
  def base_url
    "#{request.scheme}://#{request.host_with_port}#{request.script_name}"
  end
end

get '/' do
  'hello world!'
end

get '/feed' do
  entries = [
    'https://fishing.ne.jp/fishingpost/area/kobe-tobu/feed',
    'https://fishing.ne.jp/fishingpost/area/wakayama/feed',
  ].map{|url|
    feed = FeedNormalizer::FeedNormalizer.parse(open(url))
    feed.entries.each{|entry|
      # 主に扱いたいカンパリのフィードのentry.date_publishedがぶっ壊れているので、代わりにfeed.last_updatedを突っ込んでおく
      entry.date_published = feed.last_updated if (entry.date_published.year < 0)
    }
    feed.entries
  }.flatten.sort_by{|entry|
    # entry.date_publishedが被っているケースがある。
    # カンパリのフィードのentry.date_publishedを書き換えた場合などが該当する。
    # そうしたときに少しでもそれらしい並びになるよう、entry.urlも考慮するようにしている。
    # カンパリのフィードはentry.urlがオートインクリメントされているようなので、単一フィード内であればそれできれいに並ぶ。
    "#{entry.date_published}#{entry.url}"
  }.reverse

  rss = RSS::Maker.make('2.0') do |rss|
    rss.channel.title = 'turifo'
    rss.channel.description = 'Filtering info will here?'
    rss.channel.link = "#{base_url}#{request.fullpath}"

    entries.each do |entry|
      item = rss.items.new_item
      item.title = entry.title
      item.link = entry.url
      item.guid.content = entry.url
      # 便宜上entry.urlを利用しているだけで、パーマリンクとして処理して欲しいわけではない。
      item.guid.isPermaLink = false
      item.description = entry.content
      item.date = entry.date_published
    end
  end

  content_type 'application/xml'
  rss.to_s
end
