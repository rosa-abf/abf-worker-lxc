require 'airbrake'

Airbrake.configure do |config|
  config.api_key  = APP_CONFIG['airbrake_api_key']
  config.host     = 'api.rollbar.com'
  config.secure   = true
end