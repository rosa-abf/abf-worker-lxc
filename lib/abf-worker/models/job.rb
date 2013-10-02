require 'abf-worker/models/base'

module AbfWorker::Models
  class Job < AbfWorker::Models::Base

    # A transformer. All data from an API will be transformed to 
    # BaseStat instance.
    class JobStat < APISmith::Smash
      property :worker_args,   transformer: :to_a
      property :worker_queue,  transformer: :to_s
      property :worker_class,  transformer: :to_s
    end # BuildListStat

    class BaseStat < APISmith::Smash
      property :job, transformer: JobStat
    end # BaseStat

    def self.shift
      new.get('/shift',
              extra_query: {worker_queues: APP_CONFIG['worker_queues']},
              transform: BaseStat).job
    rescue => e
      # We don't raise exception, because high classes don't rescue it.
      AbfWorker::BaseWorker.send_error(e)
      return nil
    end

    def self.status(options = {})
      new.get '/status', extra_query: options
    rescue => e
      # We don't raise exception, because high classes don't rescue it.
      AbfWorker::BaseWorker.send_error(e)
      return nil
    end

    def self.feedback(options = {})
      new.put '/feedback', extra_query: options
    rescue => e
      # We don't raise exception, because high classes don't rescue it.
      AbfWorker::BaseWorker.send_error(e)
      return nil
    end

    protected

    def endpoint
      "jobs"
    end

  end
end