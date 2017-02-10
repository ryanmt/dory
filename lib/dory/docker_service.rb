require 'shellwords'
require 'ostruct'

module Dory
  module DockerService
    def self.docker_installed?
      Sh.run_command('which docker').success?
    end

    def docker_installed?
      Dory::DockerService.docker_installed?
    end

    def run_preconditions
      # Override if preconditions are needed
      return true
    end

    def run_postconditions
      # Override if postconditions are needed
      return true
    end

    def handle_error(command_output)
      # Override to provide error handling
      return false
    end

    def start(handle_error: true)
      if self.running?
        if Dory::Config.debug?
          puts "[DEBUG] Container '#{self.container_name}' is already running. Doing nothing"
        end
      else
        if docker_installed?
          self.delete_container_if_exists
          self.run_preconditions
          self.execute_run_command(handle_error)
          self.run_postconditions
        else
          err_msg = "Docker does not appear to be installed /o\\\n" \
            "Docker is required for DNS and Nginx proxy.  These can be " \
            "disabled in the config file if you don't need them."
          puts err_msg.red
        end
      end
      self.running?
    end

    def running?(container_name = self.container_name)
      return false unless docker_installed?
      !!(self.ps =~ /#{container_name}/)
    end

    def container_exists?(container_name = self.container_name)
      !!(self.ps(all: true) =~ /#{container_name}/)
    end

    def ps(all: false)
      cmd = "docker ps#{all ? ' -a' : ''}"
      ret = Sh.run_command(cmd)
      if ret.success?
        return ret.stdout
      else
        raise RuntimeError.new("Failure running command '#{cmd}'")
      end
    end

    def stop(container_name = self.container_name)
      Sh.run_command("docker kill #{Shellwords.escape(container_name)}") if self.running?
      !self.running?
    end

    def delete(container_name = self.container_name)
      if self.container_exists?
        self.stop if self.running?
        Sh.run_command("docker rm #{Shellwords.escape(container_name)}")
      end
      !self.container_exists?
    end

    def start_cmd
      "docker start #{Shellwords.escape(self.container_name)}"
    end

    def delete_container_if_exists
      if self.container_exists?
        puts "[DEBUG] Container '#{self.container_name}' exists.  Deleting" if Dory::Config.debug?
        self.delete
      end
    end

    def execute_run_command(handle_error:)
      begin
        if Dory::Config.debug?
          puts "[DEBUG] '#{self.container_name}' does not exist.  Creating/starting " \
               "'#{self.container_name}' with '#{self.run_command}'"
        end
        status = Sh.run_command(self.run_command)
        unless status.success?
          if !handle_error || !self.handle_error(status)
            puts "Failed to start docker container '#{self.container_name}' " \
                 ".  Command '#{self.run_command}' failed".red
          end
        end
      rescue Dory::Dinghy::DinghyError => e
        puts e.message.red
      end
      status
    end
  end
end
