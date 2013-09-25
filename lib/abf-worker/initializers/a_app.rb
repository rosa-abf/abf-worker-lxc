require 'yaml'

env = ENV['ENV'] || 'development'

ROOT = File.dirname(__FILE__) + '/../../../'
CONFIG_FOLDER = File.dirname(__FILE__).to_s << '/../../../config'

APP_CONFIG = YAML.load_file("#{ROOT}/config/application.yml")[env]
APP_CONFIG['env'] = env