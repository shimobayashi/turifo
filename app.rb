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
  feed = FeedNormalizer::FeedNormalizer.parse open('https://fishing.ne.jp/fishingpost/area/kobe-tobu/feed')

  rss = RSS::Maker.make('2.0') do |rss|
    rss.channel.title = 'turifo'
    rss.channel.description = 'Filtering info will here?'
    rss.channel.link = "#{base_url}#{request.fullpath}"

    feed.entries.each do |entry|
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
