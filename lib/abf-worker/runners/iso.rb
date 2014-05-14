require 'forwardable'

module AbfWorker::Runners
  class Iso
    extend Forwardable

    attr_accessor :script_runner,
                  :can_run

    def_delegators :@worker, :logger

    def initialize(worker, options)
      @worker       = worker
      @srcpath      = options['srcpath']
      @params       = options['params']
      @main_script  = options['main_script']
      @user         = options['user']
      @can_run      = true
    end

    def run_script
      @script_runner = Thread.new do
        if @worker.vm.communicator.ready?
          prepare_script
          logger.log 'Run script...'

          command = "cd iso_builder/; #{@params} /bin/bash #{@main_script}"
          begin
            @worker.vm.download_main_script
            # @worker.vm.execute_command command
            @worker.vm.execute_command(command, { sudo: true })
            logger.log 'Script done with exit_status = 0'
            @worker.status = AbfWorker::BaseWorker::BUILD_COMPLETED
          rescue AbfWorker::Exceptions::ScriptError => e
            logger.log "Script done with exit_status != 0. Error message: #{e.message}"
            @worker.status = AbfWorker::BaseWorker::BUILD_FAILED
          rescue => e
            @worker.print_error e
            @worker.status = AbfWorker::BaseWorker::VM_ERROR
          end
          save_results
        end
      end
      @script_runner.join if @can_run
    end

    private

    def save_results
      # Download ISOs and etc.
      logger.log 'Saving results....'

      ['tar -zcvf results/archives.tar.gz archives', 'rm -rf archives'].each do |command|
        @worker.vm.execute_command command
      end

      logger.log 'Downloading results....'
      @worker.vm.download_folder '/home/vagrant/results', @worker.vm.results_folder
      # Umount tmpfs
      # @worker.vm.execute_command 'umount /home/vagrant/iso_builder', {:sudo => true}
      logger.log "Done."
    end

    def prepare_script
      logger.log 'Prepare script...'
      # @worker.vm.execute_command 'mkdir /home/vagrant/iso_builder'
      # Create tmpfs, not for LXC
      # @worker.vm.execute_command(
      #   'mount -t tmpfs tmpfs -o size=30000M,nr_inodes=10M  /home/vagrant/iso_builder',
      #   {:sudo => true}
      # )

      # commands = []
      # commands << 'mkdir results'
      # commands << 'mkdir archives'
      # commands << "curl -O -L #{@srcpath}"
      # # TODO: revert changes when ABF will be working.
      # # file_name = @srcpath.match(/945501\/.*/)[0].gsub(/^945501\//, '')
      file_name = @srcpath.match(/archive\/.*/)[0].gsub(/^archive\//, '')
      # commands << "tar -xzf #{file_name}"
      folder_name = file_name.gsub(/\.tar\.gz$/, '')

      # commands << "mv #{folder_name}/* iso_builder/"
      # commands << "rm -rf #{folder_name}"
      # commands.each{ |c| @worker.vm.execute_command(c) }

      %(
        mkdir results
        mkdir archives
        wget -O #{file_name} --content-disposition #{@srcpath} --no-check-certificate
        tar -xzf #{file_name}
        mv #{folder_name} iso_builder
        rm -rf #{file_name}
        ls -la /dev | grep loop || echo No
        [[ `ls -la /dev/ | grep loop | wc -l` -eq '0'  ]] && sudo mknod -m660 /dev/loop0 b 7 0 && sudo chown root.disk /dev/loop0 && sudo chmod 666 /dev/loop0 && echo '/dev/loop0 created'
        [[ `ls -la /dev/ | grep loop | wc -l` -eq '1'  ]] && sudo mknod -m660 /dev/loop1 b 7 1 && sudo chown root.disk /dev/loop1 && sudo chmod 666 /dev/loop1 && echo '/dev/loop1 created'
        [[ `ls -la /dev/ | grep loop | wc -l` -eq '2'  ]] && sudo mknod -m660 /dev/loop2 b 7 2 && sudo chown root.disk /dev/loop2 && sudo chmod 666 /dev/loop2 && echo '/dev/loop2 created'
        [[ `ls -la /dev/ | grep loop | wc -l` -eq '3'  ]] && sudo mknod -m660 /dev/loop3 b 7 3 && sudo chown root.disk /dev/loop3 && sudo chmod 666 /dev/loop3 && echo '/dev/loop3 created'
        ls -la /dev | grep loop || echo No
      ).split("\n").each{ |c| @worker.vm.execute_command(c) }

    end

  end
end