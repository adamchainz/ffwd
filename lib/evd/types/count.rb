require 'evd/data_type'

module EVD
  #
  # Implements counting statistics (similar to statsd).
  #
  class Count
    include EVD::DataType

    register_type "count"

    def initialize(opts={})
      @cache_limit = opts[:cache_limit] || 10000
      @_cache = {}
    end

    def process(msg)
      key = msg[:key]
      value = msg[:value]

      unless (prev_value = @_cache[key]).nil?
        value = prev_value + value
      end

      @_cache[key] = value
      emit(:key => key, :value => value)
    end
  end
end
