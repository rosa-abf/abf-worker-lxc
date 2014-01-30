require 'redis'

class Redis
  def self.connect!
    Redis.current = Redis.new(
      host:   APP_CONFIG['log_server']['host'],
      port:   APP_CONFIG['log_server']['port'],
      driver: :hiredis
    )
  end
end

Redis.connect! if APP_CONFIG['log_server']