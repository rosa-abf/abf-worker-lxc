require 'forwardable'
require 'digest/md5'
require 'abf-worker/inspectors/vm_inspector'
require 'socket'
require 'fileutils'
require 'vagrant'
require 'vagrant-lxc'


module AbfWorker::Runners
  class Vm
    extend Forwardable

    @@semaphore = Mutex.new

    TWO_IN_THE_TWENTIETH = 2**20

    LOG_FOLDER    = File.dirname(__FILE__).to_s << '/../../../log'
    CONFIG_FOLDER = File.dirname(__FILE__).to_s << '/../../../config'

    attr_accessor :vagrant_env,
                  :platform,
                  :arch,
                  :share_folder

    def_delegators :@worker, :logger

    def initialize(worker, options)
      @worker   = worker
      @type     = options['type']
      @platform = options['name']
      @arch     = options['arch']
      init_configs
      @vm_name = "#{@vm_box_name}-#{@worker.worker_id}"
      @share_folder = nil
    end

    def initialize_vagrant_env
      vagrantfile = "#{vagrantfiles_folder}/#{@vm_name}"
      system "rm -rf #{vagrantfile}"
      begin
        file = File.open(vagrantfile, 'w')
        arch = can_use_x86_64_for_x86? ? 'x86_64' : @arch

str = <<VAGRANTFILE

Vagrant.configure('2') do |config|
  # Fix for DNS problems, configure proxy and etc
  config.vm.provision :shell, :inline => <<-SCRIPT
    #{APP_CONFIG['vm_configs'].join("\n")}
  SCRIPT

  config.vm.define("#{@vm_name}") do |lxc_config|
    lxc_config.vm.box       = "#{@vm_box_name}"
    lxc_config.vm.box_url   = "#{APP_CONFIG['vms_path']}/#{@vm_box_sha1}.box"

    lxc_config.vm.network :forwarded_port, guest: 80, host: #{ssh_port}, auto_correct: true
    # lxc_config.vm.hostname = "lxc-#{@vm_name.gsub(/[\W_]/, '-')}"
VAGRANTFILE

str << "    lxc_config.vm.synced_folder '/home/vagrant/share_folder', '#{@share_folder}'\n" if @share_folder
str << "    lxc_config.vm.provider :lxc do |lxc|\n"

if @worker.is_a?(AbfWorker::IsoWorker)
  # See: http://askubuntu.com/questions/376345/allow-loop-mounting-files-inside-lxc-containers
  str << "      lxc.customize 'aa_profile', 'lxc-container-extx-mounts'\n"
  # /dev/loop*
  str << "      lxc.customize 'cgroup.devices.allow', 'b 7:* rwm'\n"
  # /dev/loop-control
  str << "      lxc.customize 'cgroup.devices.allow', 'c 10:237 rwm'\n"
else
  str << "      lxc.customize 'aa_profile', 'unconfined'\n"
end

str << <<VAGRANTFILE
      lxc.customize 'autodev', 1
      lxc.customize 'cgroup.memory.limit_in_bytes', '#{APP_CONFIG['vm']["#{arch}"]}M'
      # assign the first, the second, ..., the last-1 CPU
      lxc.customize 'cgroup.cpuset.cpus', '0-#{APP_CONFIG['max_workers_count'].to_i * 2 - 2}'
    end
  end
end
VAGRANTFILE

        file.write(str)
      rescue IOError => e
        @worker.print_error e
      ensure
        file.close unless file.nil?
      end

      @vagrant_env = Vagrant::Environment.new(
        cwd:              vagrantfiles_folder,
        vagrantfile_name: @vm_name
      )
      # TODO: create link to share folder link 
      `sudo chown -R rosa:rosa #{@share_folder}/../` if @share_folder
      @@semaphore.synchronize do
        @vagrant_env.cli 'up', @vm_name
      end
    end

    def download_main_script
      %(
        rm -rf scripts
        wget -O #{APP_CONFIG['scripts']["#{@type}"]['treeish']}.tar.gz --content-disposition #{APP_CONFIG['scripts']["#{@type}"]['path']}#{APP_CONFIG['scripts']["#{@type}"]['treeish']}.tar.gz --no-check-certificate
        tar -xzf #{APP_CONFIG['scripts']["#{@type}"]['treeish']}.tar.gz
        mv #{APP_CONFIG['scripts']["#{@type}"]['treeish']} scripts
        rm -rf #{APP_CONFIG['scripts']["#{@type}"]['treeish']}.tar.gz
      ).split("\n").each{ |c| execute_command(c) }
      # cd scripts/startup-vm && /bin/bash startup.sh
    end

    def upload_file(from, to)
      # system "scp -o 'StrictHostKeyChecking no' -i keys/vagrant -P #{ssh_port} #{from} vagrant@127.0.0.1:#{to}"
      system "scp -o 'StrictHostKeyChecking no' -i keys/vagrant #{from} vagrant@#{get_vm.ssh_info[:host]}:#{to}"
    end

    def download_folder(from, to)
      system "scp -r -o 'StrictHostKeyChecking no' -i keys/vagrant vagrant@#{get_vm.ssh_info[:host]}:#{from} #{to}"
      # @@semaphore.synchronize do
      # end
    end

    def get_vm
      @vm ||= @vagrant_env.machine(@vm_name.to_sym, :lxc)
    end

    def start_vm
      logger.log "Host name '#{Socket.gethostname}'"
      logger.log "Up VM '#{get_vm.id}'..."
      run_with_vm_inspector {
        @vagrant_env.cli 'up', @vm_name
      }
    end

    def clean
      @@semaphore.synchronize do
        # @vagrant_env.cli 'destroy', @vm_name, '--force' rescue nil
        logger.log "Cleanup LXC node...", '==>'
        system "sudo lxc-destroy -n #{get_vm.id} --force" rescue nil
        ps = %x[ ps aux | grep redir | grep 'lport=#{ssh_port} ' | awk '{ print $2 }' ].
          split("\n").join(' ')
        system "sudo kill -9 #{ps}" unless ps.empty?
      end
      yield if block_given?
    end

    def execute_command(command, opts = nil)
      opts = {
        :sudo => false,
        :error_class => AbfWorker::Exceptions::ScriptError
      }.merge(opts || {})
      logger.log "Execute command with sudo = #{opts[:sudo]}: #{command}", '-->'
      if communicator.ready?
        communicator.execute command, opts do |channel, data|
          logger.log data, '', false
        end
      end
    rescue AbfWorker::Exceptions::ScriptError => e
      raise e # Throws ScriptError with exit_status
    rescue => e
      raise AbfWorker::Exceptions::ScriptError, command
    end

    def upload_results_to_file_store
      uploaded = []
      if File.exists?(results_folder) && File.directory?(results_folder)
        # Dir.new(results_folder).entries.each do |f|
        Dir[results_folder + '/**/'].each do |folder|
          Dir.new(folder).entries.each do |f|
            uploaded << upload_file_to_file_store(folder, f)
          end
        end
        system "rm -rf #{results_folder}"
      end
      uploaded << upload_file_to_file_store(LOG_FOLDER, "#{@worker.logger_name}.log")
      uploaded.compact
    end

    def communicator
      @communicator ||= get_vm.communicate
    end

    def results_folder
      return @results_folder if @results_folder
      @results_folder = "#{@worker.tmp_dir}/results/build-#{@worker.build_id}"
      system "rm -rf #{@results_folder} && mkdir -p #{@results_folder}"
      @results_folder
    end

    def rollback_vm
      # machine state should be (Running, Paused or Stuck)
      logger.log 'Rollback activity'
      run_with_vm_inspector {
        clean
        initialize_vagrant_env
      }
    end

    private

    def can_use_x86_64_for_x86?
      # Override @arch, and up x86_64 for all workers
      true
    end

    def init_configs
      vm_yml = YAML.load_file(CONFIG_FOLDER + '/vm.yml')

      configs = vm_yml[@type]
      if platform = configs.fetch('platforms', {})[@platform]
        @vm_box_sha1 = platform[@arch]
        @vm_box_name = "#{@platform}-#{@arch}" if @vm_box_sha1

        @vm_box_sha1 ||= platform['noarch']
        @vm_box_name ||= "#{@platform}-noarch"
      else
        @vm_box_sha1 = configs['default'][@arch]
        @vm_box_name = "default-#{@arch}" if @vm_box_sha1

        @vm_box_sha1 ||= configs['default']['noarch']
        @vm_box_name ||= "default-noarch"
      end
      @vm_box_name = "#{@type}-#{@vm_box_name}"
    end

    def url_to_build
      return @url_to_build if @url_to_build
      path = @worker.runner.is_a?(AbfWorker::Runners::Iso) ? 'product_build_lists' : 'build_lists'
      @url_to_build = "#{APP_CONFIG['abf_url']}/#{path}/#{@worker.build_id}"
    end

    def upload_file_to_file_store(path, file_name)
      path_to_file = path + '/' + file_name
      return unless File.file?(path_to_file)
      if file_name =~ /.log$/
        tmp_file = "#{path_to_file}.tmp"
        File.open(tmp_file, 'w') do |f|
          f.puts "==> See: '#{url_to_build}'"
          f.puts ''
          File.foreach(path_to_file){ |li| f.puts li }
        end
        File.rename tmp_file, path_to_file
      end

      # Compress the log when file size more than 10MB
      file_size = (File.size(path_to_file).to_f / TWO_IN_THE_TWENTIETH).round(2)
      if path == LOG_FOLDER && file_size >= 10
        system "tar -zcvf #{path_to_file}.tar.gz #{path_to_file}"
        File.delete path_to_file
        path_to_file << '.tar.gz'
        file_name << '.tar.gz'
      end

      logger.log "Uploading file '#{file_name}'...."
      sha1 = Digest::SHA1.file(path_to_file).hexdigest

      # curl --user myuser@gmail.com:mypass -POST -F "file_store[file]=@files/archive.zip" http://file-store.rosalinux.ru/api/v1/file_stores.json
      if %x[ curl #{APP_CONFIG['file_store']['url']}.json?hash=#{sha1} ] == '[]'
        command = 'curl --user '
        command << file_store_token
        command << ': -POST -F "file_store[file]=@'
        command << path_to_file
        command << '" '
        command << APP_CONFIG['file_store']['create_url']
        command << ' --connect-timeout 5 --retry 5'
        logger.log %x[ #{command} ]
      end

      # File.delete path_to_file
      system "sudo rm -rf #{path_to_file}"
      logger.log 'Done.'
      {:sha1 => sha1, :file_name => file_name, :size => file_size}
    end

    def vagrantfiles_folder
      @vagrantfiles_folder ||= FileUtils.mkdir_p(@worker.tmp_dir + '/vagrantfiles').first
    end

    def file_store_token
      @file_store_token ||= APP_CONFIG['file_store']['token']
    end

    def run_with_vm_inspector
      # vm_inspector = AbfWorker::Inspectors::VMInspector.new @worker
      # vm_inspector.run
      yield if block_given?
      # vm_inspector.stop
    end

    def ssh_port
      # @ssh_port ||= get_vm.ssh_info[:port]
      @ssh_port ||= 2000 + (@worker.build_id % 63000)
    end

  end
end