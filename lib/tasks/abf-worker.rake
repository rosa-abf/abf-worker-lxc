$LOAD_PATH.unshift File.dirname(__FILE__) + '/../../lib'
require 'abf-worker'
# require 'resque/tasks'
# require 'airbrake/tasks'

namespace :abf_worker do

  desc 'Start ABF Worker service'
  task :start do
    AbfWorker::TaskManager.new.run
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

  # desc "Safe destroy worker VM's"
  # task :safe_clean_up do
  #   worker_ids = %x[ ps aux | grep resque | grep -v grep | awk '{ print $2 }' ].split("\n").join('|')

  #   %w(rpm iso publish).each do |worker|
  #     vagrantfiles = "#{APP_CONFIG['tmp_path']}/#{worker}/vagrantfiles"
  #     next unless File.exist?(vagrantfiles)
  #     Dir.new(vagrantfiles).entries.each do |vf_name|
  #       next if vf_name =~ /^\./ || vf_name =~ /\_(#{worker_ids})$/
  #       vagrant_env = Vagrant::Environment.new(cwd: vagrantfiles, vagrantfile_name: vf_name)
  #       vm_id = vagrant_env.vms[vf_name.to_sym].id

  #       ps = %x[ ps aux | grep VBox | grep #{vm_id} | grep -v grep | awk '{ print $2 }' ].split("\n").join(' ')
  #       system "sudo kill -9 #{ps}" unless ps.empty?
  #       system "VBoxManage unregistervm #{vm_id} --delete"
  #       FileUtils.rm_f "#{vagrantfiles}/#{vf_name}"
  #     end
  #   end
  # end

  # desc "Destroy worker VM's, logs and etc."
  # task :clean_up do
  #   ps = %x[ ps aux | grep VBox | grep -v grep | awk '{ print $2 }' ].
  #     split("\n").join(' ')
  #   system "sudo kill -9 #{ps}" unless ps.empty?
    
  #   vms = %x[ VBoxManage list vms | awk '{ print $2 }' | sed -e 's/[{}]//g' ].split("\n")
  #   vms.each{ |vm_id| system "VBoxManage unregistervm #{vm_id} --delete" } unless vms.empty?

  #   system "rm -f logs/*.log"
  #   system "rm -rf #{APP_CONFIG['tmp_path']}"
  # end

  desc "Destroy worker VM's, logs and etc."
  task :clean_up do
    system "rm -rf ~/.vagrant.d/boxes/*"
    system "rm -rf #{APP_CONFIG['tmp_path']}"
    system "rm -rf #{ROOT}/log/*"
    %x[ lxc-ls -1 | grep vagrant ].split("\n").each do |name|
      system "sudo lxc-destroy -f -n #{name}"
    end
  end

end