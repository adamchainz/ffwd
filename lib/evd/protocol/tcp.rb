require_relative '../reporter'
require_relative '../tunnel'

module EVD::TCP
  class Connection < EM::Connection
    def initialize(parent)
      @parent = parent
    end

    def connection_completed
      @parent.connection_completed
    end

    def unbind
      @parent.unbind
    end

    def receive_data(data)
      @parent.receive_data data
    end
  end

  class Connect
    attr_reader :log

    INITIAL_TIMEOUT = 2

    include EVD::Reporter

    def initialize(log, host, port, handler, flush_period, outbound_limit)
      @log = log
      @host = host
      @port = port
      @handler = handler
      @flush_period = flush_period
      @outbound_limit = outbound_limit

      @peer = "#{host}:#{port}"
      @closing = false
      @reconnect_timer = nil
      @reconnect_timeout = INITIAL_TIMEOUT

      @event_buffer = []
      @metric_buffer = []

      @open = false
      @c = nil
    end

    def id
      @id ||= "#{@handler.class.name}(#{@peer})"
    end

    def connection_completed
      @open = true
      @log.info "Connected tcp://#{@peer}"
      @reconnect_timeout = INITIAL_TIMEOUT

      unless @reconnect_timer.nil?
        @reconnect_timer.cancel
        @reconnect_timer = nil
      end
    end

    def unbind
      @open = false

      if @closing
        @log.info "Disconnected from tcp://#{@peer}"
        return
      end

      @log.info "Disconnected from tcp://#{@peer}, reconnecting in #{@reconnect_timeout}s"

      unless @reconnect_timer.nil?
        @reconnect_timer.cancel
        @reconnect_timer = nil
      end

      @reconnect_timer = EM::Timer.new(@reconnect_timeout) do
        @reconnect_timeout *= 2
        @reconnect_timer = nil
        @c.reconnect @host, @port
      end
    end

    def receive_data data
      @handler.receive_data data
    end

    def start output
      @c = EM.connect(@host, @port, Connection, self)

      EM.add_shutdown_hook{close}

      if @flush_period == 0
        output.event_subscribe{|e| handle_event e}
        output.metric_subscribe{|e| handle_metric e}
        return
      end

      @log.info "Flushing every #{@flush_period}s"

      EM::PeriodicTimer.new(@flush_period){
        flush!
      }

      output.event_subscribe{|e| @event_buffer << e}
      output.metric_subscribe{|e| @metric_buffer << e}
    end

    def close
      @closing = true
      @c.close_connection
    end

    private

    def connected?
      @open
    end

    # Check if a connection is writable or not.
    def writable?
      connected? and @c.get_outbound_data_size < @outbound_limit
    end

    def flush!
      if @event_buffer.empty? and @metric_buffer.empty?
        return
      end

      unless writable?
        increment :dropped_events, @event_buffer.size
        increment :dropped_metrics, @metric_buffer.size
        return
      end

      @c.send_data @handler.serialize_all(@event_buffer, @metric_buffer)
      increment :sent_events, @event_buffer.size
      increment :sent_metrics, @metric_buffer.size
    rescue => e
      @log.error "Failed to flush", e
    ensure
      @event_buffer = []
      @metric_buffer = []
    end

    def handle_event event
      return increment :dropped_events, 1 unless writable?
      @c.send_data @handler.serialize_event(event)
      increment :sent_events, 1
    rescue => e
      @log.error "Failed to handle event", e
    end

    def handle_metric metric
      return increment :dropped_metrics, 1 unless writable?
      @c.send_data @handler.serialize_metric(metric)
      increment :sent_metrics, 1
    rescue => e
      @log.error "Failed to handle metric", e
    end
  end

  class Bind
    def initialize log, host, port, handler, args
      @log = log
      @host = host
      @port = port
      @handler = handler
      @args = args
      @peer = "#{host}:#{port}"
    end

    def start input, output
      @log.info "Binding to tcp://#{@peer}"
      EM.start_server @host, @port, @handler, input, output, *@args
    end
  end

  def self.family
    :tcp
  end

  DEFAULT_FLUSH_PERIOD = 10
  DEFAULT_OUTBOUND_LIMIT = 2 ** 20

  def self.connect log, opts, handler
    raise "Missing required key :host" if (host = opts[:host]).nil?
    raise "Missing required key :port" if (port = opts[:port]).nil?
    flush_period = opts[:flush_period] || DEFAULT_FLUSH_PERIOD
    outbound_limit = opts[:outbound_limit] || DEFAULT_OUTBOUND_LIMIT
    Connect.new log, host, port, handler, flush_period, outbound_limit
  end

  def self.bind log, opts, handler, *args
    raise "Missing required key :host" if (host = opts[:host]).nil?
    raise "Missing required key :port" if (port = opts[:port]).nil?
    Bind.new log, host, port, handler, args
  end

  def self.tunnel log, opts, handler, *args
    raise "Missing required key :port" if (port = opts[:port]).nil?
    EVD::Tunnel.new log, self.family, port, handler, args
  end
end
