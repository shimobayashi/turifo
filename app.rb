require 'sinatra/async'
require 'feed-normalizer'
require 'rss/maker'
require 'mongoid'
require 'haml'
require 'em-http-request'
require 'nokogiri'
require 'net/https'
require 'json'

require_relative 'lib/models/settings'

class Turifo < Sinatra::Base
  register Sinatra::Async

  enable :show_exceptions

  configure do
    Mongoid.load!('config/mongoid.yml')
    POST_API_URL = ENV['POST_API_URL']
    POST_API_KEY = ENV['POST_API_KEY']
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

    redirect to('/')
  end

  aget '/feed' do
    get_entries_and_errors do |entries, errors|
      rss = RSS::Maker.make('2.0') do |rss|
        rss.channel.title = "#{get_settings.filtering_regexp_str} - turifo"
        rss.channel.description = errors.size > 0 ? errors.join("\n") : 'There is no error.'
        rss.channel.link = to('/')

        entries.each do |entry|
          item = rss.items.new_item
          item.title = entry.title
          item.link = entry.url
          item.guid.content = entry.id
          # 元のフィードでisPermaLinkがどうだったかは保存されていない気がする(要出典)ので、一律でfalseにしておく
          item.guid.isPermaLink = false
          item.description = entry.content
          item.date = entry.date_published
        end
      end

      content_type 'application/rss+xml', :charset => 'utf-8'
      body rss.to_s

      if POST_API_URL && POST_API_URL != ""
        EM::defer do
          uri = URI.parse(POST_API_URL)
          http = Net::HTTP.new(uri.host, uri.port)

          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE

          # 雑にentry毎にリクエストを投げているので、その内まとめてリクエストするようにして効率化したい。
          entries.each do |entry|
            req = Net::HTTP::Post.new(uri.path)
            req.set_form_data({
              api_key: POST_API_KEY,
              row_contents: [
                entry.id,
                entry.date_published,
                entry.title,
                entry.url,
                entry.content,
              ].to_json,
            })

            res = http.request(req)
          end
        end
      end
    end
  end

  def get_settings
    Settings.first || Settings.new
  end

  def get_entries_and_errors
    multi = EM::MultiRequest.new

    get_settings.source_urls.each do |url|
      multi.add(url, EM::HttpRequest.new(url).get)
    end

    multi.callback do
      entries = []
      errors = []

      multi.responses[:callback].each do |name, http|
        feed = FeedNormalizer::FeedNormalizer.parse(http.response)
        if feed
          feed.entries.each{|entry|
            # マージするので元のフィードが分かるようにentry.titleをいじっておく
            entry.title = "#{entry.title} - #{feed.title}"
            # entry.date_publishedが無ければよしなに埋める。
            #   主に扱いたいカンパリのフィードのentry.date_publishedがぶっ壊れているので、代わりにfeed.last_updatedを突っ込んでおく。
            #   XPathFeedなどで生成したフィードはそもそも日付系の情報が一切存在しないため、適当に現在時刻で埋めておく。
            if (!entry.date_published || entry.date_published.year < 0)
              entry.date_published = feed.last_updated ? feed.last_updated : Time.now
            end
            # entry.idが無ければよしなに埋める。
            unless entry.id
              # はてなアンテナのフィードはguidが存在しないがURLを採用すると永遠に浮上してこないためdate_publishedとの組み合わせとする。
              # はてなアンテナ由来のエントリーかどうかはかなり雑に判定しているので、問題が起きたら修正すること。
              if entry.title =~ /はてなアンテナ/
                entry.id = "#{entry.url}#{entry.date_published}"
              # 基本的にはURLをguidとすれば問題ないはずである。
              else
                entry.id = "#{entry.url}"
              end
            end
          }
          entries.concat(feed.entries)
        else
          errors << "Failed to parse: #{http.req.uri}"
        end
      end

      multi.responses[:errback].each do |name, http|
        errors << "Failed to fetch: #{http.req.uri}(#{http.error})"
      end

      entries = filter_entries(entries)
      insert_ogimage_to_entries(entries) do |entries|
        entries = entries.sort_by{|entry|
          # entry.date_publishedが被っているケースがある。
          # カンパリのフィードのentry.date_publishedを書き換えた場合などが該当する。
          # そうしたときに少しでもそれらしい並びになるよう、entry.urlも考慮するようにしている。
          # カンパリのフィードはentry.urlがオートインクリメントされているようなので、単一フィード内であればそれできれいに並ぶ。
          "#{entry.date_published}#{entry.url}"
        }.reverse

        yield entries, errors
      end
    end
  end

  def filter_entries(entries)
    regexp = get_settings.filtering_regexp
    entries.select{|entry|
      "#{entry.title}#{entry.description}" =~ regexp
    }
  end

  def insert_ogimage_to_entries(entries)
    multi = EM::MultiRequest.new

    # imgタグらしきものが無いエントリーのみを対象とする。
    no_img_entries = entries.select{|entry| entry.content !~ /img/}
    # そもそも対象となるエントリーが無ければ何もせずに終わる。
    if no_img_entries.size == 0
      yield entries
      return
    end

    no_img_entries.each do |entry|
      multi.add(entry.url, EM::HttpRequest.new(entry.url).get)
    end

    # imgタグらしきものが無いエントリーのみに絞ってもいいが、将来的に混乱しそうなのであえて絞らない。
    entry_by_url = Hash[*entries.map{|entry| [entry.url, entry]}.flatten(1)]

    multi.callback do
      multi.responses[:callback].each do |name, http|
        doc = Nokogiri::HTML.parse(http.response)

        ogimage = nil
        # カンパリであればog:imageの代わりに釣り場の地図を利用する。
        # フィードで一覧するときにはog:imageよりも釣果の多い釣り場を把握したいため。
        if http.req.uri.host == 'fishing.ne.jp'
          attr = doc.css('//.map_area/img/@src').first || doc.css('//.map_area/img/@data-original').first
          ogimage = attr ? attr.value : nil
        else
          attr = doc.css('//meta[property="og:image"]/@content').first
          ogimage = attr ? attr.value : nil
        end

        if ogimage && ogimage != ""
          entry = entry_by_url[http.req.uri.to_s]
          entry.content = %{<img src="#{ogimage}" /><br />#{entry.content}}
        end
      end

      multi.responses[:errback].each do |name, http|
        # 何もしない。
      end

      yield entries
    end
  end
end
