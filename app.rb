require 'sinatra'
require 'feed-normalizer'
require 'open-uri'
require 'rss/maker'
require 'mongoid'
require 'haml'

require_relative 'lib/models/settings'

Mongoid.load!('config/mongoid.yml')

helpers do
  def base_url
    "#{request.scheme}://#{request.host_with_port}#{request.script_name}/"
  end
end

get '/' do
  @settings = get_settings
  haml :index
end

post '/settings' do
  settings = get_settings

  settings.filtering_regexp_str = params[:filtering_regexp_str]
  settings.source_urls = params[:source_url].select{|url| url != ''}

  halt 503, "Failed to save settings: #{settings.errors.full_messages.join(', ')}" unless settings.save

  redirect base_url
end

get '/feed' do
  entries = get_entries

  rss = RSS::Maker.make('2.0') do |rss|
    rss.channel.title = "#{get_settings.filtering_regexp_str} - turifo"
    rss.channel.description = 'Filtered fishing infomations.'
    rss.channel.link = "#{base_url}"

    entries.each do |entry|
      item = rss.items.new_item
      item.title = entry.title
      item.link = entry.url
      item.guid.content = entry.url
      # 便宜上entry.urlをguidに利用しているだけで、パーマリンクとして処理して欲しいわけではない。
      item.guid.isPermaLink = false
      item.description = entry.content
      item.date = entry.date_published
    end
  end

  content_type 'application/rss+xml', :charset => 'utf-8'
  rss.to_s
end

def get_settings
  Settings.first || Settings.new
end

def get_entries
  entries = get_settings.source_urls.map{|url|
    feed = FeedNormalizer::FeedNormalizer.parse(open(url))
    if feed
      feed.entries.each{|entry|
        # マージするので元のフィードが分かるようにentry.titleをいじっておく
        entry.title = "#{entry.title} - #{feed.title}"
        # 主に扱いたいカンパリのフィードのentry.date_publishedがぶっ壊れているので、代わりにfeed.last_updatedを突っ込んでおく
        entry.date_published = feed.last_updated if (entry.date_published.year < 0)
      }
      feed.entries
    else
      []
    end
  }.flatten
  entries = filter_entries(entries)
  entries.sort_by{|entry|
    # entry.date_publishedが被っているケースがある。
    # カンパリのフィードのentry.date_publishedを書き換えた場合などが該当する。
    # そうしたときに少しでもそれらしい並びになるよう、entry.urlも考慮するようにしている。
    # カンパリのフィードはentry.urlがオートインクリメントされているようなので、単一フィード内であればそれできれいに並ぶ。
    "#{entry.date_published}#{entry.url}"
  }.reverse
end

def filter_entries(entries)
  regexp = get_settings.filtering_regexp
  entries.select{|entry|
    "#{entry.title}#{entry.description}" =~ regexp
  }
end
