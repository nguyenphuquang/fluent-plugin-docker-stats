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

    def initialize
      super
      @last_stats = {}
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
      es = Fluent::MultiEventStream.new
      Docker::Container.all(all: true).each do |container|
        container_detail = Docker::Container.get(container.id, all: true)
        name = container_detail.info['Name']
        current_state = container_detail.info['State']
        status = current_state['Status']
        if @last_stats.include?(name)
          if @last_stats[name] != status
            emit_container_up_down(container_detail, es)
          end
        end
        @last_stats[name] = status
        puts "last stats: #{@last_stats.inspect}"

        emit_container_stats(container_detail, es)
      end
      router.emit_stream(@tag, es)
    end

    def emit_container_up_down(container, es)
      container_name = container.info['Name']
      state = container.info['State']
      record = {
        "type": "alert",
        "container_id": container.id,
        "container_name": container_name,
        "host_ip": ENV['HOST_IP'],
        "created_time": container.info["Created"],
        "status": state['Status']
      }
      es.add(Fluent::Engine.now, record)
    end

    def emit_container_stats(container, es)
      container_name = container.info['Name']
      puts "Processing container: #{container_name || 'UNNAMED'} (ID: #{container.id})"
      
      # Skip containers without names
      if container_name.nil?
        puts "Skipping container #{container.id} due to missing name"
        return
      end

      if @container_regex && !container_name.match(@container_regex)
        puts "Skipping container #{container_name} dont match regex"
        return
      end

      state = container.info['State']
      record = {
        "container_id": container.id,
        "host_ip": ENV['HOST_IP'],
        "container_name": container_name,
        "created_time": container.info["Created"],
        "status": state['Status'],
        "is_running": state['Running'],
        "is_restarting": state['Restarting'],
        "is_paused": state['Paused'],
        "is_oom_killed": state['OOMKilled'],
        "started_time": state['StartedAt'],
        "finished_time": state['FinishedAt']
      }

      # Only collect detailed stats for running containers
      if state['Running']
        begin
          stats = container.stats(stream: false)
          
          if stats && stats['memory_stats']
            memory_stats = stats['memory_stats']
            record["mem_usage"] = memory_stats['usage'] || 0
            record["mem_limit"] = memory_stats['limit'] || 0
            record["mem_max_usage"] = memory_stats['max_usage'] || 0
          end

          if stats && stats['cpu_stats']
            cpu_stats = stats['cpu_stats']
            cpu_usage = cpu_stats['cpu_usage']
            cpu_system_usage = cpu_stats['system_cpu_usage']
            
            if cpu_usage && cpu_system_usage && cpu_system_usage > 0
              cpu_total_usage = cpu_usage['total_usage'] || 0
              cpu_percent = (cpu_total_usage.to_f / cpu_system_usage.to_f) * 100
              record["cpu_system_usage"] = cpu_system_usage
              record["cpu_total_usage"] = cpu_total_usage
              record["cpu_percent"] = cpu_percent
            else
              record["cpu_system_usage"] = 0
              record["cpu_total_usage"] = 0
              record["cpu_percent"] = 0.0
            end
          end

          record["networks"] = []
          if stats && stats['networks']
            stats['networks'].each do |network_name, network_info|
              record["networks"] << {
                "network_name": network_name,
                "rx": network_info['rx_bytes'] || 0,
                "tx": network_info['tx_bytes'] || 0
              }
            end
          end

          if stats && stats['storage_stats']
            storage_stats = stats['storage_stats']
            if storage_stats['read_count']
              record["storage"] = {
                "read_count": storage_stats['read_count'],
                "read_size": storage_stats['read_size_bytes'],
                "write_count": storage_stats['write_count'],
                "write_size": storage_stats['write_size_bytes']
              }
            end
          end
        rescue => e
          puts "Error collecting stats for container #{container_name}: #{e.message}"
        end
      else
        # Set default values for non-running containers
        record["mem_usage"] = 0
        record["mem_limit"] = 0
        record["mem_max_usage"] = 0
        record["cpu_system_usage"] = 0
        record["cpu_total_usage"] = 0
        record["cpu_percent"] = 0.0
        record["networks"] = []
      end

      # Ensure all values in record are properly formatted
      record.each do |k, v|
        if v.nil?
          record[k] = ""  # Convert nil to empty string
        end
      end

      # Convert symbol keys to strings to ensure consistent format
      record = Hash[record.map { |k, v| [k.to_s, v] }]

      time = Fluent::Engine.now
      es.add(time, record)

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