require 'mongoid'

class Settings
  include Mongoid::Document
  include Mongoid::Timestamps

  field :filtering_regexp_str, type: String

  validate :validate_filtering_regexp_str

  def validate_filtering_regexp_str
    begin
      filtering_regexp
    rescue RegexpError => e
      errors.add(:filtering_regexp_str, "is invalid: #{e}")
    end
  end

  def filtering_regexp
    Regexp.new(filtering_regexp_str)
  end
end
