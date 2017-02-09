require_relative 'docker_service'

module Dory
  class Dnsmasq
    extend Dory::DockerService

    @@first_attempt_failed = false

    def self.dnsmasq_image_name
      'freedomben/dory-dnsmasq:1.1.0'
    end

    def self.run_preconditions
      puts "[DEBUG] dnsmasq service running preconditions" if Dory::Config.debug?

      # we don't want to hassle the user with checking the port unless necessary
      if @@first_attempt_failed
        handle_systemd_services = self.has_systemd? && self.has_services_that_block_dnsmasq?
        self.down_systemd_services if handle_systemd_services

        puts "[DEBUG] First attempt failed.  Checking port #{self.port}" if Dory::Config.debug?
        listener_list = self.check_port(self.port)
        unless listener_list.empty?
          return self.offer_to_kill(listener_list)
        end

        self.up_systemd_services if handle_systemd_services
        return false
      else
        puts "[DEBUG] Skipping preconditions on first run" if Dory::Config.debug?
        return true
      end
    end

    def self.handle_error(command_output)
      puts "[DEBUG] handling dnsmasq start error" if Dory::Config.debug?
      # If we've already tried to handle failure, prevent infinite recursion
      if @@first_attempt_failed
        puts "[DEBUG] Attempt to kill conflicting service failed" if Dory::Config.debug?
        return false
      else
        if Dory::Config.debug?
          puts "[DEBUG] First attempt to start dnsmasq failed." \
               "There is probably a conflicting service present"
        end
        @@first_attempt_failed = true
        self.start(handle_error: false)
      end
    end

    def self.ip_from_dinghy?
      Dory::Dinghy.match?(self.address(self.old_address)) ||
        self.domains.any?{ |domain| Dory::Dinghy.match?(self.address(domain[:address])) }
    end

    def self.port
      return 53 unless Os.macos?
      p = Dory::Config.settings[:dory][:dnsmasq][:port]
      p.nil? || p == 0 ? 19323 : self.sanitize_port(p)
    end

    def self.sanitize_port(port)
      port.to_s.gsub(/\D/, '').to_i
    end

    def self.container_name
      Dory::Config.settings[:dory][:dnsmasq][:container_name]
    end

    def self.domains
      Dory::Config.settings[:dory][:dnsmasq][:domains]
    end

    def self.old_domain
      Dory::Config.settings[:dory][:dnsmasq][:domain]
    end

    def self.old_address
      Dory::Config.settings[:dory][:dnsmasq][:address]
    end

    def self.address(addr)
      Dory::Dinghy.match?(addr) ? Dory::Dinghy.ip : addr
    end

    def self.domain_addr_arg_string
      if self.old_domain
        "#{Shellwords.escape(self.old_domain)} #{Shellwords.escape(self.address(self.old_address))}"
      else
        self.domains.map do |domain|
          "#{Shellwords.escape(domain[:domain])} #{Shellwords.escape(self.address(domain[:address]))}"
        end.join(" ")
      end
    end

    def self.run_command(domains = self.domains)
      "docker run -d -p #{self.port}:#{self.port}/tcp -p #{self.port}:#{self.port}/udp " \
      "--name=#{Shellwords.escape(self.container_name)} " \
      "--cap-add=NET_ADMIN #{Shellwords.escape(self.dnsmasq_image_name)} " \
      "#{self.domain_addr_arg_string}"
    end

    def self.check_port(port_num)
      puts "Requesting sudo to check if something is bound to port #{self.port}".green
      ret = Sh.run_command("sudo lsof -i :#{self.port}")
      return [] unless ret.success?

      list = ret.stdout.split("\n")
      list.shift  # get rid of the column headers
      list.map! do |process|
        command, pid, user, fd, type, device, size, node, name = process.split(/\s+/)
        OpenStruct.new({
          command: command,
          pid: pid,
          user: user,
          fd: fd,
          type: type,
          device: device,
          size: size,
          node: node,
          name: name
        })
      end
    end

    def self.offer_to_kill(listener_list, answer: nil)
      listener_list.each do |process|
        puts "Process '#{process.command}' with PID '#{process.pid}' is listening on #{process.node} port #{self.port}."
      end
      pids = listener_list.uniq(&:pid).map(&:pid)
      pidstr = pids.join(' and ')
      print "This interferes with Dory's dnsmasq container.  Would you like me to kill PID #{pidstr}? (Y/N): "
      conf = answer ? answer : ENV['DORY_KILL_DNSMASQ']
      conf = STDIN.gets.chomp unless conf
      if conf =~ /y/i
        puts "Requesting sudo to kill PID #{pidstr}"
        return Sh.run_command("sudo kill #{pids.join(' ')}").success?
      else
        puts "OK, not killing PID #{pidstr}.  Please kill manually and try starting dory again.".red
        return false
      end
    end

    def self.has_systemd?
      Sh.run_command('which systemctl').success?
    end

    def self.systemd_service_installed?(service)
      !(Sh.run_command("systemctl status #{service} | head -1").stdout =~ /unit.*not.*found/i)
    end

    def self.services_that_block_dnsmasq
      %w[
        NetworkManager.service
        systemd-resolved.service
      ]
    end

    def self.has_services_that_block_dnsmasq?
      !self.enabled_services_that_block_dnsmasq.empty?
    end

    def self.enabled_services_that_block_dnsmasq
      self.services_that_block_dnsmasq.select do |service|
        self.systemd_service_installed?(service)
      end
    end

    def self.down_systemd_services
      services = self.enabled_services_that_block_dnsmasq
      puts "You have some systemd services running that will race against us \n" \
           "to bind to port 53 (and usually they win): #{services.join(', ')}".yellow
      puts "If we don't stop these services temporarily while putting up the \n" \
           "dnsmasq container, starting it will likely fail.".yellow
      puts "Would you like me to put them down while we start dns \n" \
           "(I'll put them back up when finished)? (Y/N): ".green
      if STDIN.gets.chomp =~ /y/i
        if services.all? { |service|
          self.set_systemd_service(service: service, up: false)
        }
          puts "Putting down services succeeded".green
        else
          puts "One or more services failed to go down".red
        end
      else
        puts 'OK, not putting down the services'.yellow
      end
    end

    def self.up_systemd_services
      services = self.enabled_services_that_block_dnsmasq
      if services.reverse.all? { |service|
        self.set_systemd_service(service: service, up: true)
      }
        puts "#{services.join(', ')} were successfully restarted".green
      else
        puts "#{services.join(', ')} failed to restart".red
      end
    end

    def self.set_systemd_service(service:, up:)
      action = up ? 'start' : 'stop'
      Sh.run_command("sudo systemctl #{action} #{service}").success?
    end
  end
end
