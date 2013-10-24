source 'http://rubygems.org'

gem 'rake'
gem 'redis', '3.0.4'
gem 'hiredis', '~> 0.4.5'
gem 'god'

gem 'vagrant', git: 'git://github.com/avokhmin/vagrant.git', branch: 'v1.3.3-abf'
gem 'vagrant-lxc', git: 'git://github.com/avokhmin/vagrant-lxc.git', branch: 'v0.6.4-abf-worker-service'
# gem 'vagrant-lxc', "~> 0.6.0"

gem 'log4r', '1.1.10'
gem 'api_smith', '1.2.0'

gem 'airbrake'

group :development do
  # deploy
  gem 'capistrano', :require => false
  gem 'rvm-capistrano', :require => false
  gem 'cape', :require => false
  gem 'capistrano_colors', :require => false
end

group :test do
  gem 'rspec'
  gem 'shoulda'
  gem 'rr'
  gem 'mock_redis'
  gem 'rake'
end