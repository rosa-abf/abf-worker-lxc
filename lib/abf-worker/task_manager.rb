require 'securerandom'
require 'socket'
require 'abf-worker/models/job'

module AbfWorker
  class TaskManager

    def initialize(type)
      @queue    = []
      @shutdown = false
      @pid      = Process.pid
      @uid      = SecureRandom.hex
      @type     = type
      touch_pid
    end

    def run
      Signal.trap("USR1") { stop_and_clean }
      loop do 
        # begin
          find_new_job unless shutdown?
          if shutdown? && @queue.empty?
            remove_pid
            return
          end
          cleanup_queue
          send_statistics
          sleep 10
        # rescue Exception => e
        #   AbfWorker::BaseWorker.send_error(e)
        # end
      end
    rescue => e
      AbfWorker::BaseWorker.send_error(e)
    end

    private

    # only for RPM
    def send_statistics
      return if @type != :rpm
      AbfWorker::Models::Job.statistics({
        uid:          @uid,
        worker_count: APP_CONFIG['max_workers_count'],
        busy_workers: @queue.size,
        host:         Socket.gethostname
      })
    end

    def stop_and_clean
      @shutdown = true
      @queue.each do |thread|
        thread[:worker].shutdown = true
      end
    end

    def find_new_job
      return if @queue.size >= APP_CONFIG['max_workers_count'].to_i

      job = case @type
            when :rpm
              AbfWorker::Models::Job.shift
            when :publish, :iso
              resque_queues.each do |q|
                break if job = Resque.pop(q)
              end if APP_CONFIG['use_resque']
            end

      return unless job
      worker_id = ( (0...APP_CONFIG['max_workers_count'].to_i).to_a - @queue.map{ |t| t[:worker_id] } ).first
      thread = Thread.new do
        Thread.current[:subthreads] = []
        Thread.current[:worker_id]  = worker_id

        case @type
        when :rpm
          clazz       = job.worker_class
          worker_args = job.worker_args[0]
        when :publish, :iso # Resque format
          clazz       = job['class']
          worker_args = job['args'][0]
        end

        clazz  = clazz.split('::').inject(Object){ |o,c| o.const_get c }
        worker = clazz.new(worker_args.merge('worker_id' => worker_id))

        Thread.current[:worker] = worker
        worker.perform
      end
      @queue << thread
    end

    def cleanup_queue
      @queue.select! do |thread|
        if thread.alive?
          true
        else
          thread[:subthreads].each{ |t| t.kill }
          thread.kill
          false
        end
      end
    end

    def shutdown?
      @shutdown
    end

    def touch_pid
      path = "#{ROOT}/pids/#{@pid}"
      system "touch #{path}" unless File.exist?(path) 
    end

    def remove_pid
      system "rm -f #{ROOT}/pids/#{@pid}"
    end

    def resque_queues
      @resque_queues ||= ENV['QUEUE'].split(',')
    end

  end
end