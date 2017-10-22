require 'mongoid'
require 'uri'

class Settings
  include Mongoid::Document
  include Mongoid::Timestamps

  field :filtering_regexp_str, type: String, default: ''
  field :source_urls, type: Array, default: []

  validate :validate_filtering_regexp_str
  validate :validate_source_urls

  def validate_filtering_regexp_str
    begin
      filtering_regexp
    rescue RegexpError => e
      errors.add(:filtering_regexp_str, "is invalid: #{e}")
    end
  end

  def validate_source_urls
    source_urls.each {|url|
      uri = URI.parse(url)
      %w(http https).include?(uri.scheme) or raise 'has invalid scheme'
    }
  rescue
    errors.add(:url, $!.message)
  end

  def filtering_regexp
    Regexp.new(filtering_regexp_str)
  end
end
