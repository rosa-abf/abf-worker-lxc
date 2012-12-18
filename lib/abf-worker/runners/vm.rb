require 'forwardable'

module AbfWorker
  module Runners
    class Vm
      extend Forwardable

      TWO_IN_THE_TWENTIETH = 2**20

      ROOT_PATH = File.dirname(__FILE__).to_s << '/../../../'
      LOG_FOLDER = ROOT_PATH + 'log'
      FILE_STORE = 'http://file-store.rosalinux.ru/api/v1/file_stores.json'
      FILE_STORE_CREATE_PATH = 'http://file-store.rosalinux.ru/api/v1/upload'
      FILE_STORE_CONFIG = ROOT_PATH + 'config/file-store.yml'

      attr_accessor :vagrant_env,
                    :vm_name,
                    :os,
                    :arch,
                    :share_folder

      def_delegators :@worker, :logger

      def initialize(worker, os, arch)
        @worker = worker
        @os = os
        @arch = arch
        @vm_name = "#{@os}.#{can_use_x86_64_for_x86? ? 'x86_64' : @arch}_#{@worker.worker_id}"
        @share_folder = nil
        # @vm_name = "#{@os}.#{@arch}_#{@worker.worker_id}"
      end

      def initialize_vagrant_env(update_share_folder = false)
        vagrantfile = "#{vagrantfiles_folder}/#{@vm_name}"
        first_run = false
        unless File.exist?(vagrantfile)
          begin
            file = File.open(vagrantfile, 'w')
            port = 2000 + (@worker.build_id % 63000)
            arch = can_use_x86_64_for_x86? ? 'x86_64' : @arch
            str = "
              Vagrant::Config.run do |config|
                config.vm.define '#{@vm_name}' do |vm_config|
                  #{share_folder_config}
                  vm_config.vm.box = '#{@os}.#{arch}'
                  vm_config.vm.forward_port 22, #{port}
                  vm_config.ssh.port = #{port}
                end
              end"
            file.write(str)
            first_run = true
          rescue IOError => e
            logger.error e.message
          ensure
            file.close unless file.nil?
          end
        end
        if !first_run && update_share_folder
          system "sed \"4s|.*|#{share_folder_config}|\" #{vagrantfile} > #{vagrantfile}_tmp"
          system "mv #{vagrantfile}_tmp #{vagrantfile}"
        end

        @vagrant_env = Vagrant::Environment.new(
          :cwd => vagrantfiles_folder,
          :vagrantfile_name => @vm_name
        )
        # Hook for fix:
        # ERROR warden: Error occurred: uninitialized constant VagrantPlugins::ProviderVirtualBox::Action::Customize::Errors
        # on vm_config.vm.customizations << ['modifyvm', :id, '--memory',  '#{memory}']
        # and config.vm.customize ['modifyvm', '#{@vm_name}', '--memory', '#{memory}']
        if first_run

          File.open("#{@worker.tmp_dir}/../vm.synchro", File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            logger.info '==> Up VM at first time...'
            @vagrant_env.cli 'up', @vm_name
            sleep 1
          end
          sleep 30

          logger.info '==> Configure VM...'
          # Halt, because: The machine 'abf-worker_...' is already locked for a session (or being unlocked)
          @vagrant_env.cli 'halt', @vm_name
          sleep 20
          vm_id = get_vm.id
          # see: #initialize_vagrant_env: 37
          memory = arch == 'x86_64' ? 8192 : 4096
          # memory = @arch == 'i586' ? 512 : 1024
          # see: http://code.google.com/p/phpvirtualbox/wiki/AdvancedSettings
          ["--memory #{memory}", '--cpus 2', '--hwvirtex on', '--nestedpaging on', '--largepages on'].each do |c|
            system "VBoxManage modifyvm #{vm_id} #{c}"
          end

          sleep 10
          @vagrant_env.cli 'up', @vm_name
          sleep 30
          if @os == 'mdv'
            execute_command('urpmi.update -a', {:sudo => true})
            execute_command('urpmi  --auto  mock-urpm', {:sudo => true})
            execute_command('urpmi --update genhdlist2', {:sudo => true})
          end
          # VM should be exist before using sandbox
          logger.info '==> Enable save mode...'
          Sahara::Session.on(@vm_name, @vagrant_env)
        end # first_run
      end

      def get_vm
        @vagrant_env.vms[@vm_name.to_sym]
      end

      def start_vm
        logger.info "==> Up VM..."
        @vagrant_env.cli 'up', @vm_name
        rollback_vm
      end

      def rollback_and_halt_vm
        rollback_vm
        logger.info '==> Halt VM...'
        @vagrant_env.cli 'halt', @vm_name
        logger.info '==> Done.'
        yield if block_given?
      end

      def clean(destroy_all = false)
        files = []
        Dir.new(vagrantfiles_folder).entries.each do |f|
          if File.file?(vagrantfiles_folder + "/#{f}") &&
              (f =~ /#{@worker.worker_id}/ || destroy_all) && !(f =~ /^\./)
            files << f
          end
        end
        files.each do |f|
          env = Vagrant::Environment.new(
            :vagrantfile_name => f,
            :cwd => vagrantfiles_folder,
            :ui => false
          )
          logger.info '==> Halt VM...'
          env.cli 'halt', '-f'

          logger.info '==> Disable save mode...'
          Sahara::Session.off(f, env)

          logger.info '==> Destroy VM...'
          env.cli 'destroy', '--force'

          File.delete(vagrantfiles_folder + "/#{f}")
        end
        yield if block_given?
      end

      def execute_command(command, opts = nil)
        opts = {
          :sudo => false,
          :error_class => AbfWorker::Exceptions::ScriptError
        }.merge(opts || {})
        filtered_command = command.gsub /\:\/\/.*\:\@/, '://[FILTERED]@'
        logger.info "--> execute command with sudo = #{opts[:sudo]}: #{filtered_command}"
        if communicator.ready?
          communicator.execute command, opts do |channel, data|
            logger.info data 
          end
        end
      end

      def upload_results_to_file_store
        uploaded = []
        if File.exists?(results_folder) && File.directory?(results_folder)
          # Dir.new(results_folder).entries.each do |f|
          Dir[results_folder + '/**/'].each do |folder|
            Dir.new(folder).entries.each do |f|
              uploaded << upload_file(folder, f)
            end
          end
          system "rm -rf #{results_folder}"
        end
        uploaded << upload_file(LOG_FOLDER, "#{@worker.logger_name}.log")
        uploaded.compact
      end

      def communicator
        @communicator ||= get_vm.communicate
      end

      def results_folder
        return @results_folder if @results_folder
        @results_folder = @worker.tmp_dir + '/results'
        Dir.mkdir(@results_folder) unless File.exists?(@results_folder)
        @results_folder << "/build-#{@worker.build_id}"
        Dir.rmdir(@results_folder) if File.exists?(@results_folder)
        Dir.mkdir(@results_folder)
        @results_folder
      end

      def rollback_vm
        # machine state should be (Running, Paused or Stuck)
        logger.info '==> Rollback activity'
        Sahara::Session.rollback(@vm_name, @vagrant_env)
      end

      def define_packager_command(user)
        mock_command = @os == 'mdv' ? 'mock-urpm' : 'mock'
        "#{mock_command} --define='packager #{user['uname']} #{user['email']}'"
      end

      private

      def share_folder_config
        if @share_folder
          logger.info "==> Share folder: #{@share_folder}"
          "vm_config.vm.share_folder('v-root', '/home/vagrant/share_folder', '#{@share_folder}')"
        else
          "vm_config.vm.share_folder('v-root', nil, nil)"
        end
      end

      def can_use_x86_64_for_x86?
        # Override @arch, and up x86_64 for all workers
        true
      end

      def upload_file(path, file_name)
        path_to_file = path + '/' + file_name
        return unless File.file?(path_to_file)

        # Compress the log when file size more than 10MB
        file_size = (File.size(path_to_file).to_f / TWO_IN_THE_TWENTIETH).round(2)
        if path == LOG_FOLDER && file_size >= 10
          system "tar -zcvf #{path_to_file}.tar.gz #{path_to_file}"
          File.delete path_to_file
          path_to_file << '.tar.gz'
          file_name << '.tar.gz'
        end

        logger.info "==> Uploading file '#{file_name}'...."
        sha1 = Digest::SHA1.file(path_to_file).hexdigest

        # curl --user myuser@gmail.com:mypass -POST -F "file_store[file]=@files/archive.zip" http://file-store.rosalinux.ru/api/v1/file_stores.json
        if %x[ curl #{FILE_STORE}?hash=#{sha1} ] == '[]'
          command = 'curl --user '
          command << file_store_token
          command << ': -POST -F "file_store[file]=@'
          command << path_to_file
          command << '" '
          command << FILE_STORE_CREATE_PATH
          system command
        end

        File.delete path_to_file
        logger.info "Done."
        {:sha1 => sha1, :file_name => file_name, :size => file_size}
      end

      def vagrantfiles_folder
        return @vagrantfiles_folder if @vagrantfiles_folder
        @vagrantfiles_folder = @worker.tmp_dir + '/vagrantfiles'
        Dir.mkdir(@vagrantfiles_folder) unless File.exists?(@vagrantfiles_folder)
        @vagrantfiles_folder 
      end

      def file_store_token
        return @file_store_token if @file_store_token
        fs_config = YAML.load_file(FILE_STORE_CONFIG)
        @file_store_token = fs_config["server_#{@worker.server_id}"]
        @file_store_token
      end

    end
  end
end