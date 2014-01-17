require 'set'
require 'json'
require 'eventmachine'

require_relative 'channel'
require_relative 'core_emitter'
require_relative 'core_interface'
require_relative 'core_processor'
require_relative 'debug'
require_relative 'logging'
require_relative 'plugin_channel'
require_relative 'processor'
require_relative 'protocol'
require_relative 'statistics'
require_relative 'utils'

module EVD
  class Core
    include EVD::Logging

    # Arbitrary default queue limit.
    # Having a queue limit is critical to make sure we never run out of memory.
    DEFAULT_BUFFER_LIMIT = 5000
    DEFAULT_REPORT_INTERVAL = 600

    def initialize plugins, opts={}
      @tunnel_plugins = plugins[:tunnel] || []
      @bind_plugins = plugins[:bind] || []
      @connect_plugins = plugins[:connect] || []

      @report_interval = opts[:report_interval] || DEFAULT_REPORT_INTERVAL

      @statistics_opts = opts[:statistics]
      @debug_opts = opts[:debug]
      @core_opts = opts[:core] || {}
      @processor_opts = opts[:processor_opts] || {}

      @output = EVD::PluginChannel.new 'output'
      @input = EVD::PluginChannel.new 'input'
    end

    #
    # Main entry point.
    #
    # Starts an EventMachine and runs the given set of plugins.
    #
    def run
      tunnels = @tunnel_plugins.map do |plugin|
        plugin.setup self
      end

      debug = nil

      if @debug_opts
        debug = EVD::Debug.setup @debug_opts
      end

      processors = load_processors @processor_opts
      core = CoreInterface.new tunnels, processors, debug, @core_opts

      emitter = CoreEmitter.new @output, @core_opts
      processor = CoreProcessor.new emitter, processors

      bind_instances = @bind_plugins.map do |plugin|
        plugin.setup core
      end

      connect_instances = @connect_plugins.map do |plugin|
        plugin.setup core
      end

      # Configuration for statistics module.
      statistics = nil

      if config = @statistics_opts
        statistics = EVD::Statistics.setup(emitter, [@output, @input], config)
      end

      EM.run do
        processor.start @input

        reporters = []
        reporters += EVD.setup_reporters connect_instances
        reporters += processor.reporters

        log.info "Registered #{reporters.size} reporter(s)"

        bind_instances.each do |p|
          p.start @input, @output
        end

        connect_instances.each do |p|
          p.start @output
        end

        unless statistics.nil?
          statistics.start
        end

        unless debug.nil?
          debug.start
          debug.monitor "core.input", @input, EVD::Debug::Input
          debug.monitor "core.output", @output, EVD::Debug::Output
        end

        unless reporters.empty?
          EM::PeriodicTimer.new(@report_interval) do
            report! reporters
          end
        end
      end
    end

    private

    #
    # setup hash of datatype functions.
    #
    def load_processors opts
      processors = {}

      Processor.registry.each do |name, klass|
        processor_opts = opts[name] || {}
        processors[name] = lambda{klass.new(processor_opts)}
      end

      if processors.empty?
        raise "No processors loaded"
      end

      log.info "Loaded processors: #{processors.keys.join(', ')}"
      return processors
    end

    def report! reporters
      active = []

      reporters.each do |reporter|
        active << reporter if reporter.report?
      end

      return if active.empty?

      active.each_with_index do |reporter, i|
        reporter.report "report ##{i}"
      end
    end
  end
end
