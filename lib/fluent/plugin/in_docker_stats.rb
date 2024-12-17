require 'fluent/plugin/input'
require 'docker'
require 'uri'

module Fluent::Plugin

  class DockerStatsInput < Input
    Fluent::Plugin.register_input('docker_stats', self)

    config_param :stats_interval, :string, :default => "60s"
    config_param :tag, :string, :default => "docker"
    # config_param :container_ids, :array, :default => nil # mainly for testing
    config_param :container_regex, :string, :default => nil # mainly for testing

    last_stats = {}

    def initialize
      super
      puts "Found Docker details: #{Docker.version}"
      puts "Using interval: #{@stats_interval}"
      puts "Container Regex: #{@container_regex}"
      puts "Using tag: #{@tag}"
    end

    def configure(conf)
      super
    end

    def start
      @loop = Coolio::Loop.new
      tw = TimerWatcher.new(@stats_interval, true, @log, &method(:get_metrics))
      tw.attach(@loop)
      @thread = Thread.new(&method(:run))
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error => $!.to_s
      log.error_backtrace
    end

    def get_metrics
      # ids = list_container_ids
      # ids.each do |container_id|
      #   emit_container_stats(container_id)
      # end
      Docker::Container.all(all: true).each do |container|
        name = container.info['Name']
        if name in last_stats
          if last_stats[name] != container.status
            emit_container_up_down(container, container.status)
          end
        end
        last_stats[name] = container.status

        emit_container_stats(container.id)
      end
    end

    def emit_container_up_down(container)
      state = container.info['State']
      record = {
        "type": "alert",
        "container_id": container.id,
        "container_name": container.info['Name'].sub(/^\//, ''),
        "host_ip": container.json['NetworkSettings']['Networks'].values.first['IPAddress'],
        "created_time": container.info["Created"]
        "status": state['Status']
      }
      router.emit(@tag, Fluent::Engine.now, record)
    end

    def emit_container_stats(container_id)
      container = Docker::Container.get(container_id)
      puts "Processing container: #{container.info['Name']}"
      if @container_regex && !container.info['Name'].match(@container_regex)
        return
      end

      record = {
        "container_id": container_id,
        # "host_ip": container.info['NetworkSettings']['IPAddress'],
        "host_ip": container.json['NetworkSettings']['Networks'].values.first['IPAddress'],
        "container_name": container.info['Name'].sub(/^\//, ''),
        "created_time": container.info["Created"]
      }

      state = container.info['State']
      record["status"] = state['Status']
      record["is_running"] = state['Running']
      record["is_restarting"] = state['Restarting']
      record["is_paused"] = state['Paused']
      record["is_oom_killed"] = state['OOMKilled']
      record["started_time"] = state['StartedAt']
      record["finished_time"] = state['FinishedAt']

      stats = container.stats(stream: false)

      memory_stats = stats['memory_stats']
      record["mem_usage"] = memory_stats['usage']
      record["mem_limit"] = memory_stats['limit']
      record["mem_max_usage"] = memory_stats['max_usage']

      cpu_stats, = stats['cpu_stats']
      cpu_usage = cpu_stats['cpu_usage']

      cpu_system_usage = cpu_stats['system_cpu_usage']
      cpu_total_usage = cpu_usage['total_usage']
      cpu_percent = (cpu_total_usage.to_f / cpu_system_usage.to_f) * 100

      record["cpu_system_usage"] = cpu_system_usage
      record["cpu_total_usage"] = cpu_total_usage
      record["cpu_percent"] = cpu_percent

      record["networks"] = []
      stats['networks'].each do |network_name, network_info|
        record["networks"] << {
          "network_name": network_name,
          "rx": network_info['rx_bytes'],
          "tx": network_info['tx_bytes'],
        }
      end

      storage_stats = stats['storage_stats']
      if stats['storage_stats'] && !stats['storage_stats'].empty?
        record["volumes"] = []
        volume_stats = storage_stats['volumes']
        volume_stats.each do |volume_name, volume_info|
          puts "Volume #{volume_name} - Used: #{volume_info['used']} bytes, Total: #{volume_info['total']} bytes"
          record["volumes"] << {
            "volume_name": volume_name,
            "volume_used": volume_info['used'],
            "volume_total": volume_info['total'],
          }
        end
      end

      router.emit(@tag, Fluent::Engine.now, record)
    end

    def list_container_ids
      # List all containers including stopped ones
      Docker::Container.all().map do |container|
        container.id
      end
    end

    def shutdown
      @loop.stop
      @thread.join
    end

    class TimerWatcher < Coolio::TimerWatcher
      def initialize(interval, repeat, log, &callback)
        @callback = callback
        @log = log
        super(interval, repeat)
      end

      def on_timer
        @callback.call
      rescue
        @log.error $!.to_s
        @log.error_backtrace
      end
    end
  end
end