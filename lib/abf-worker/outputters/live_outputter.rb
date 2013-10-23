require 'log4r/outputter/outputter'

module AbfWorker::Outputters
  class LiveOutputter < Log4r::Outputter

    def initialize(name, hash={})
      super(name, hash)
      @name = name
      @worker = hash[:worker]
      @buffer = []
      @buffer_limit   = hash[:buffer_limit] || 100
      @time_interval  = hash[:time_interval] || 10
      init_thread
    end


    private

    # perform the write
    def write(data)
      line = data.to_s
      unless line.empty?
        last_line = @buffer.last
        if last_line && (line.strip =~ /^[\#]+$/) && (line[-1, 1] == last_line[-1, 1])
          last_line.rstrip!
          last_line << line.lstrip
        else
          @buffer.shift if @buffer.size > @buffer_limit
          @buffer << line
        end
      end
    end

    def init_thread
      @thread = Thread.new do
        while true
          sleep @time_interval
          str = @buffer.join
          if APP_CONFIG['log_server']
            redis.setex(@name, (@time_interval + 5), str) rescue @redis = nil
          else
            AbfWorker::Models::Job.logs({name: @name, logs: (str[-150..-1] || str)})
          end
        end # while
      end
      Thread.current[:subthreads] << @thread
      @thread.run
    end

    def redis
      @redis ||= Redis.new(
        host:   APP_CONFIG['log_server']['host'],
        port:   APP_CONFIG['log_server']['port'],
        driver: :hiredis
      )
    end

  end
end