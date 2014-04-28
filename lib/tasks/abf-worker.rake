$LOAD_PATH.unshift File.dirname(__FILE__) + '/../../lib'
require 'abf-worker'
# require 'resque/tasks'
# require 'airbrake/tasks'

namespace :abf_worker do

  task :lock do
    system "lockfile -r 0 #{ENV['PIDFILE']} 1>/dev/null 2>&1" if ENV['PIDFILE']
  end

  desc 'Start ABF Worker service (rpm/publish/iso)'
  task start: ['abf_worker:lock'] do
    queue = ENV['QUEUE']
    if queue =~ /rpm_/
      AbfWorker::TaskManager.new(:rpm).run
    elsif queue =~ /publish_/
      AbfWorker::TaskManager.new(:publish).run
    elsif queue =~ /iso_/
      AbfWorker::TaskManager.new(:iso).run
    end
  end

  desc 'Stop ABF Worker service'
  task :stop do
    folder = "#{ROOT}/pids/"
    %x[ ls -1 #{folder} ].split("\n").each do |pid|
      system "kill -USR1 #{pid}" if pid =~ /^[\d]+$/
    end
    loop do
      break if %x[ ls -1 #{folder} ].split("\n").select{ |pid| pid =~ /^[\d]+$/ }.empty?
      sleep 5
    end
    puts "==> ABF Worker service has been stopped [OK]"
  end

  # desc 'Init dev env'
  # task :init_env do
  #   path = File.dirname(__FILE__).to_s + '/../../'
  #   Dir.mkdir path + 'log'
  # end

  desc 'Init Vagrant boxes'
  task :init_boxes do
    vm_yml = YAML.load_file(File.dirname(__FILE__).to_s + '/../../config/vm.yml')

    all_boxes = []
    vm_yml.each do |distrib_type, configs|
      boxes = configs['default'].select{ |k, v| k !~ /\_hwaddr$/ }.values |
        (configs['platforms'] || {}).map{ |name, arches| arches.select{ |k, v| k !~ /\_hwaddr$/ }.values }.flatten
      all_boxes << boxes
      boxes.each do |sha1|
        puts "Checking #{distrib_type} - #{sha1} ..."
        path = "#{APP_CONFIG['vms_path']}/#{sha1}.box"
        unless File.exist?(path)
          puts '- downloading box...'
          if system "curl -o #{path} -L #{APP_CONFIG['file_store']['url']}/#{sha1}"
            puts '- box has been downloaded successfully'
          else
            raise "Box '#{sha1}' does not exist on File-Store"
          end
        end
        puts 'Done.'
      end
    end
  end

  desc "Destroy worker VM's, logs and etc."
  task :clean_up do
    system "rm -rf ~/.vagrant.d/boxes/*"
    system "rm -rf #{APP_CONFIG['tmp_path']}"
    system "rm -rf #{ROOT}/log/*"
    system "rm -rf #{ROOT}/pids/*"
    %x[ lxc-ls -1 | grep vagrant ].split("\n").each do |name|
      system "sudo lxc-destroy -f -n #{name}"
    end

    ps = %x[ ps aux | grep redir | grep -v grep | awk '{ print $2 }' ].
      split("\n").join(' ')
    system "sudo kill -9 #{ps}" unless ps.empty?

  end

  desc "Safe destroy worker containers"
  task :safe_clean_up do
    worker_ids = %x[ ps aux | grep resque | grep -v grep | awk '{ print $2 }' ].split("\n").join('|')

    vagrantfiles = APP_CONFIG['tmp_path'] + '/vagrantfiles'
    Dir.new(vagrantfiles).entries.each do |vf_name|
      next if vf_name =~ /^\./ || vf_name =~ /\-(#{worker_ids})$/
      vagrant_env = Vagrant::Environment.new(cwd: vagrantfiles, vagrantfile_name: vf_name)
      vm_id = vagrant_env.machine(vf_name.to_sym, :lxc).id

      ps = %x[ ps aux | grep lxc | grep #{vm_id} | grep -v grep | awk '{ print $2 }' ].split("\n").join(' ')
      system "sudo kill -9 #{ps}" unless ps.empty?
      system "sudo lxc-destroy -f -n #{vm_id}"
      FileUtils.rm_f "#{vagrantfiles}/#{vf_name}"
    end if File.exist?(vagrantfiles)
  end

end