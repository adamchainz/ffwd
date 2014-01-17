require 'eventmachine'

require_relative '../protocol'
require_relative '../plugin'
require_relative '../logging'
require_relative '../connection'

module EVD::Plugin
  module Carbon
    include EVD::Plugin
    include EVD::Logging

    register_plugin "carbon"

    class Connection < EVD::Connection
      include EVD::Logging
      include EM::Protocols::LineText2

      def initialize input, output
        @input = input
      end

      def parse(line)
        path, value, timestamp = line.split ' ', 3
        raise "invalid frame" if timestamp.nil?

        return nil if path.empty? or value.empty? or timestamp.empty?

        value = value.to_f unless value.nil?
        time = Time.at(timestamp.to_i)

        return {:key => path, :value => value, :time => time}
      end

      def receive_line(ln)
        metric = parse(ln)
        return if metric.nil?
        @input.metric metric
      rescue => e
        log.error "Failed to receive data", e
      end
    end

    DEFAULT_HOST = "localhost"
    DEFAULT_PORT = 2003
    DEFAULT_PROTOCOL = "tcp"

    def self.setup_input core, opts={}
      opts[:host] ||= DEFAULT_HOST
      opts[:port] ||= DEFAULT_PORT
      protocol = EVD.parse_protocol(opts[:protocol] || DEFAULT_PROTOCOL)
      protocol.bind log, opts, Connection
    end

    def self.setup_tunnel core, opts={}
      opts[:port] ||= DEFAULT_PORT
      protocol = EVD.parse_protocol(opts[:protocol] || DEFAULT_PROTOCOL)
      protocol.tunnel log, opts, Connection
    end
  end
end
