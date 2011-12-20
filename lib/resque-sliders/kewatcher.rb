#!/usr/bin/env ruby

require 'resque'
require 'timeout'
require 'fileutils'

module ResqueSliders
  class KEWatcher

    attr_accessor :verbosity

    def initialize(options={})
      @verbosity = (options[:verbosity] || 0).to_i
      @rakefile = File.expand_path(options[:rakefile]) rescue nil
      @rakefile = File.exists?(@rakefile) ? @rakefile : nil if @rakefile
      @pidfile = File.expand_path(options[:pidfile]) rescue nil
      @pidfile = @pidfile =~ /\.pid/ ? @pidfile : @pidfile + '.pid' if @pidfile
      save_pid!

      @max_children = (options[:max_children] || 5).to_i
      @hostname = `hostname -s`.chomp.downcase
      @pids = Hash.new # init pids array to track running children
      @resque_key = "plugins:resque-sliders:#{@hostname}" # Resque also as resque namespace we use
      @sliders_hosts_key = "plugins:resque-sliders:hosts" # name of config Hash for running daemons
      @need_queues = Array.new # keep track of pids that are needed
      @dead_queues = Array.new # keep track of pids that are dead

      rails_env = ENV['RAILS_ENV'] || 'development'
      resque_config = options[:config] || 'localhost'
      case resque_config
      when Hash
        Resque.redis = resque_config[rails_env]
      when String
        Resque.redis = resque_config
      end
    end

    def run!(interval=0.1)
      # run it
      interval = Float(interval)
      $0 = "KEWatcher: Starting"
      startup

      count = 0
      loop do
        break if shutdown?
        count += 1
        log! ["watching:", @pids.keys.join(', '), "(#{@pids.keys.length})"].delete_if { |x| x == (nil || '') }.join(' ') if count % (10 / interval) == 1

        if not (paused? || shutdown?)
          if count % (20 / interval) == 1
            # about every 20 seconds
            queue_diff!
            procline @pids.keys.join(', ')
          end

          while @pids.keys.length < @max_children && (@need_queues.length > 0 || @dead_queues.length > 0)
            queue = @dead_queues.shift || @need_queues.shift
            @pids.store(fork { exec("QUEUE='#{queue}' rake #{'-f ' + @rakefile if @rakefile} resque:work") }, queue)
            procline @pids.keys.join(', ')
          end
        end

        sleep(interval)
        @pids.keys.each do |pid|
          begin
            # check to see if pid is running, by waiting for it, with a timeout
            Timeout::timeout(interval / 100) { Process.wait(pid) }
          rescue Timeout::Error
            # Timeout expired, goto next pid
            next
          rescue Errno::ECHILD
            # if no pid exists to wait for, remove it
            log! (paused? || shutdown?) ? "#{pid} (#{@pids[pid]}) child died; no one cares..." : "#{pid} (#{@pids[pid]}) child died; spawning another..."
            remove pid
            break
          end
        end
      end
    end

    def startup
      enable_gc_optimizations
      register_signal_handlers
      register_self
      $stdout.sync = true
    end

    def enable_gc_optimizations
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
    end

    def register_signal_handlers
      trap('TERM') { shutdown! }
      trap('INT') { shutdown! }

      begin
        trap('QUIT') { shutdown! }
        trap('HUP') { signal_hup }
        trap('USR1') { signal_usr1 }
        trap('USR2') { signal_usr2 }
        trap('CONT') { signal_cont }
      rescue ArgumentError
        warn "Signals QUIT, USR1, USR2, and/or CONT not supported."
      end

      log! "Registered signals"
    end

    def procline(string)
      $0 = "KEWatcher (#{@pids.keys.length}): #{string}"
      log! $0
    end

    def queue_diff!
      # Forces queue diff
      # Overrides what needs to start from Redis
      diff = queue_diff
      to_start = diff.first
      to_kill = diff.last
      to_kill.each { |pid| remove! pid }
      @need_queues = to_start # authoritative answer from redis of what needs to be running
    end

    def queue_diff
      # Queries Redis to get Hash of what should running
      # figures what is running and does a diff
      # returns an Array of 2 Arrays: to_start, to_kill

      goal, to_start, to_kill = [], [], []
      Resque.redis.hgetall(@resque_key).each_pair { |queue,count| goal += [queue] * count.to_i }
      # to sort or not to sort?
      # goal.sort!

      running_queues = @pids.values # check list
      goal.each do |q|
        if running_queues.include?(q)
          # delete from checklist cause its already running
          running_queues.delete_at(running_queues.index(q))
        else
          # not included in running queue, need to start
          to_start << q
        end
      end

      @pids.dup.each_pair do |k,v|
        if running_queues.include?(v)
          # whatever is left over in this checklist shouldn't be running
          to_kill << k
          running_queues.delete_at(running_queues.index(v))
        end
      end

      if (to_start.length + @pids.keys.length - to_kill.length) > @max_children
        # if to_start with existing minus whats to be killed is still greater than max children
        log "WARN: need to start too many children, please raise max children"
      end

      kill_queues = to_kill.map { |x| @pids[x] }
      log! ["GOTTA START:", to_start.map { |x| "#{x} (#{to_start.count(x)})" }.uniq.join(', '), "= #{to_start.length}"].delete_if { |x| x == (nil || '') }.join(' ')
      log! ["GOTTA KILL:", kill_queues.map { |x| "#{x} (#{kill_queues.count(x)})" }.uniq.join(', '), "= #{to_kill.length}"].delete_if { |x| x == (nil || '') }.join(' ')

      [to_start, to_kill] # return whats left
    end

    def remove!(pid)
      # removes pid completely, ignores its queues
      kill_child pid
      @pids.delete(pid)
      procline @pids.keys.join(', ')
    end

    def remove(pid)
      # remove pid, and respawn same queues
      @dead_queues.unshift(@pids[pid]) # keep track of queues that pid was running, put it at front of list
      @pids.delete(pid)
      procline @pids.keys.join(', ')
    end

    def shutdown!
      log "Exiting..."
      @shutdown = true
      kill_children
      unregister_self
      remove_pidfile!
    end

    def shutdown?
      @shutdown
    end

    def paused?
      @paused
    end

    def signal_hup
      log "HUP received; purging children..."
      kill_children
      @paused = false # unpause after kill (restart child)
    end

    def signal_usr1
      log "USR1 received; killing little children..."
      kill_children
      @paused = true # pause after kill cause we're paused
    end

    def signal_usr2
      log "USR2 received; not making babies"
      @paused = true # paused again
    end

    def signal_cont
      log "CONT received; making babies..."
      @paused = false # unpause
    end

    def kill_child(pid)
      begin
        Process.kill("QUIT", pid) # try graceful shutdown
        log! "Child #{pid} killed. (#{@pids.keys.length-1})"
      rescue Object => e # dunno what this does but it works; dont know exception
        log! "Child #{pid} already dead, sad day. (#{@pids.keys.length-1})"
      end
    end

    def kill_children
      @pids.dup.keys.each do |pid|
        kill_child pid
        remove pid
      end
      Process.waitall() # wait for it.
    end

    def register_self
      #my_config = Resque.redis.hgetall(@sliders_hosts_key)
      #if my_config.key?(@hostname)
      #  # do shit here when its already set
      Resque.redis.hset(@sliders_hosts_key, @hostname, @max_children)
      log! "Registered Master with Redis"
    end

    def unregister_self
      Resque.redis.hdel(@sliders_hosts_key, @hostname)
      log! "Unregistered self"
    end

    def log(message)
      if verbosity == 1
        puts "* #{message}"
      elsif verbosity > 1
        time = Time.now.strftime('%H:%M:%S %Y-%m-%d')
        puts "*** [#{time}] #$$: #{message}"
      end
    end

    def log!(message)
      log message if verbosity > 1
    end

    def save_pid!
      if @pidfile
        begin
          log "Saving pid to => #{@pidfile}"
          File.open(@pidfile, 'w') { |f| f.write(Process.pid) }
        rescue Errno::EACCES => e
          puts "Cannot write pidfile => #{e}"
          exit 1
        rescue Errno::ENOENT => e
          dir = File.dirname(@pidfile)
          begin
            log! "#{dir} doesnt exist; Creating it..."
            FileUtils.mkdir_p(dir)
          rescue Errno::EACCES => e
            puts "Cannot create directory => #{e}"
            exit 1
          end
          save_pid! rescue nil
        end
      end
    end

    def remove_pidfile!
      File.exists?(@pidfile) && File.delete(@pidfile) if @pidfile
    end

  end
end
