require 'forwardable'
require 'json'
require 'tempfile'

module AbfWorker::Runners
  class Rpm
    extend Forwardable

    attr_accessor :script_runner,
                  :can_run,
                  :packages,
                  :exit_status

    def_delegators :@worker, :logger

    def initialize(worker, options)
      @worker               = worker
      @cmd_params           = options['cmd_params']
      @git_project_address  = options['git_project_address']
      @commit_hash          = options['commit_hash']
      @build_requires       = options['build_requires']
      @include_repos        = options['include_repos']
      @user                 = options['user']
      @rerun_tests          = options['rerun_tests'].to_s
      @can_run              = true
      @packages             = []
    end

    def run_script
      @script_runner = Thread.new do
        if @worker.vm.communicator.ready?
          init_mock_configs
          init_external_script
          logger.log 'Run script...'

          command = [
            'cd scripts/build-packages/;',
            @cmd_params,
            "ARCH=#{@worker.vm.arch}",
            "PLATFORM_NAME=#{@worker.vm.platform}",
            "UNAME=#{@user['uname']}",
            "EMAIL=#{@user['email']}",
            '/bin/bash build.sh'
          ]
          # "BUILD_REQUIRES=#{@build_requires}"
          # "INCLUDE_REPOS='#{@include_repos}'"
          begin

            @worker.vm.download_main_script

            @worker.vm.execute_command command.join(' ')
            logger.log 'Script done with exit_status = 0'
            @worker.status = AbfWorker::BaseWorker::BUILD_COMPLETED
          rescue AbfWorker::Exceptions::ScriptError => e
            logger.log "Script done with exit_status != 0. Error message: #{e.message}"
            if e.message =~ /exit_status=>#{AbfWorker::BaseWorker::TESTS_FAILED}/ # 5
              @worker.status = AbfWorker::BaseWorker::TESTS_FAILED
            else
              @worker.status = AbfWorker::BaseWorker::BUILD_FAILED
            end
            @exit_status = e.message.match(/exit_status=>[\d]+/)
            @exit_status = @exit_status[0].gsub(/[^\d]/, '') if @exit_status
          rescue => e
            @worker.print_error e
            @worker.status = AbfWorker::BaseWorker::VM_ERROR
          end
          save_results
        end
      end
      Thread.current[:subthreads] << @script_runner
      @script_runner.join if @can_run
    end

    private

    def save_results
      logger.log "Downloading results...."
      @worker.vm.download_folder '/home/vagrant/results', @worker.vm.results_folder

      container_data = "#{@worker.vm.results_folder}/results/container_data.json"
      if File.exists?(container_data)
        @packages = JSON.parse(IO.read(container_data)).select{ |p| p['name'] }
        File.delete container_data
      end

      if @rerun_tests != 'true' && @packages.size < 2
        @worker.status = AbfWorker::BaseWorker::BUILD_FAILED
      end
      logger.log "Done."
    end

    def init_external_script
      script = APP_CONFIG['scripts'][@worker.vm.type]['external_script']
      return unless script && script.size > 0
      return unless File.exists?(script)
      @worker.vm.upload_file script, '/home/vagrant/container/external_script'
    end

    def init_mock_configs
      @worker.vm.execute_command 'rm -rf container && mkdir container'
      file = Tempfile.new("media-#{@worker.build_id}.list", @worker.tmp_dir)
      begin
        @include_repos.each do |name, url|
          # Checks that repositoy exist
          if %x[ curl --write-out %{http_code} --silent --output /dev/null #{url} ] == '404'
            logger.log "Repository does not exist: #{url}"
          else
            file.puts "#{name} #{url}"
          end
        end
        file.close
        @worker.vm.upload_file file.path, '/home/vagrant/container/media.list'
      ensure
        file.close
        file.unlink
      end
    end

  end
end