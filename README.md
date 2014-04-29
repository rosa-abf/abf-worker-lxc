RosaLab ABF workers
===================

**Workers for building packages, processing repositories and etc.**

This describes the resources that make up the official Rosa ABF workers. If you have any problems or requests please contact [support](https://abf.rosalinux.ru/contact).

**Note: This Documentation is in a beta state. Breaking changes may occur.**

## Installation

    curl -L get.rvm.io | bash -s stable
    source /home/rosa/.rvm/scripts/rvm
    rvm install ruby-2.1.0
    rvm gemset create abf-worker
    rvm use ruby-2.1.0@abf-worker --default

    cd abf-worker
    bundle install

    cp config/application.yml.sample config/application.yml
    vi config/application.yml

    cp config/vm.yml.sample config/vm.yml

    cp config/deploy/production.rb.sample config/deploy/production.rb
    vi config/deploy/production.rb

    cp config/deploy.rb.sample config/deploy.rb

## Deploy

### On server

    sudo apt-get install curl procmail

    curl -L get.rvm.io | bash -s stable
    source /home/rosa/.rvm/scripts/rvm
    rvm install ruby-2.1.1
    rvm gemset create abf-worker
    rvm use ruby-2.1.1@abf-worker --default

    # configure newrelic

    # only for VM
    # echo noop > /sys/block/vda/queue/scheduler

### on DEV PC

    cap production deploy:init
    cap production deploy:update

### on Server

    cd abf-worker/shared/config/
    vi application.yml 

### on DEV PC

    cap production deploy:update
    cap production deploy:rpm
