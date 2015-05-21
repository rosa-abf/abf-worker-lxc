require 'forwardable'

module AbfWorker::Runners
  class Iso
    extend Forwardable

    attr_accessor :script_runner,
                  :can_run,
                  :exit_status

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
            @exit_status   = e.message.match(/exit_status=>[\d]+/)
            @exit_status   = @exit_status[0].gsub(/[^\d]/, '') if @exit_status
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
      logger.log "Done."
    end

    def prepare_script
      logger.log 'Prepare script...'
      file_name = @srcpath.match(/archive\/.*/)[0].gsub(/^archive\//, '')
      folder_name = file_name.gsub(/\.tar\.gz$/, '')

      # wget -O #{file_name} --content-disposition #{@srcpath} --no-check-certificate
      %(
        mkdir results
        mkdir archives
        curl -O -L #{@srcpath}
        tar -xzf #{file_name}
        mv #{folder_name} iso_builder
        rm -rf #{file_name}
        ls -la /dev | grep loop || echo No
	for (( i=0; i<16; i=i+1 )); do [[ `ls -la /dev/ | grep loop | wc -l` -eq "$i" ]] && sudo mknod -m660 /dev/loop$i b 7 $i && sudo chown root.disk /dev/loop$i && sudo chmod 666 /dev/loop$i && echo "/dev/loop$i created"; done
        ls -la /dev | grep loop || echo No
      ).split("\n").each{ |c| @worker.vm.execute_command(c) }
    end

  end
end
