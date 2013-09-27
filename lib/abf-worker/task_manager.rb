require 'abf-worker/models/job'

module AbfWorker
  class TaskManager
    @@semaphore = Mutex.new


    def initialize
      @queue = []
      @shutdown = false
      @pid = Process.pid
      touch_pid
    end

    def run
      Signal.trap("USR1") { stop_and_clean }
      loop do 
        begin
          find_new_job unless shutdown?
          if shutdown? && @queue.empty?
            remove_pid
            break
          end
          cleanup_queue
          sleep 10
        rescue Exception => e
          puts e.inspect
        end
      end
    end

    private

    def stop_and_clean
      @@semaphore.synchronize do
        @shutdown = true
        @queue.each do |thread|
          thread[:worker].shutdown = true
        end
      end
    end

    def find_new_job
      return if @queue.size >= APP_CONFIG['max_workers_count']

      if job = AbfWorker::Models::Job.shift
        @@semaphore.synchronize do
          @queue << Thread.new do
            clazz = job.worker_class.split('::').inject(Object){ |o,c| o.const_get c }
            worker = clazz.new(job.worker_args)
            Thread.current[:worker] = worker
            worker.perform
          end
        end
      end
    end

    def cleanup_queue
      @@semaphore.synchronize do
        @queue.select!{ |thread| thread.alive? }
      end
    end

    def shutdown?
      @shutdown
    end

    def touch_pid
      system "touch #{ROOT}/pids/#{@pid}"
    end

    def remove_pid
      system "rm -f #{ROOT}/pids/#{@pid}"
    end

  end
end