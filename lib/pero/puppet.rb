require 'net/ssh'

Specinfra::Configuration.error_on_missing_backend_type = false
Specinfra.configuration.backend = :ssh
module Specinfra
  module Configuration
    def self.sudo_password
      return ENV['SUDO_PASSWORD'] if ENV['SUDO_PASSWORD']
      return @sudo_password if defined?(@sudo_password)

      # TODO: Fix this dirty hack
      return nil unless caller.any? {|call| call.include?('channel_data') }

      print "sudo password: "
      @sudo_password = STDIN.noecho(&:gets).strip
      print "\n"
      @sudo_password
    end
  end
end

module Pero
  class Puppet
    extend Pero::SshExecutable
    attr_reader :specinfra
    def initialize(host, options, mutex)
      @options = options.dup
      @mutex = mutex

      @options[:host] = host
      so = ssh_options

      if !Net::SSH::VALID_OPTIONS.include?(:strict_host_key_checking)
        so.delete(:strict_host_key_checking)
      end

      @specinfra = Specinfra::Backend::Ssh.new(
        request_pty: true,
        host: so[:host_name],
        ssh_options: so,
        disable_sudo: false,
      )
    end

    # refs: github.com/itamae-kitchen/itamae
    def ssh_options
      opts = {}
      opts[:host_name] = @options[:host]

      # from ssh-config
      ssh_config_files = @options["ssh_config"] ? [@options["ssh_config"]] : Net::SSH::Config.default_files
      opts.merge!(Net::SSH::Config.for(@options["host"], ssh_config_files))
      opts[:user] = @options["user"] || opts[:user] || Etc.getlogin
      opts[:password] = @options["password"] if @options["password"]
      opts[:keys] = [@options["key"]] if @options["key"]
      opts[:port] = @options["port"] if @options["port"]
      opts[:timeout] = @options["timeout"] if @options["timeout"]

      if @options["vagrant"]
        config = Tempfile.new('', Dir.tmpdir)
        hostname = opts[:host_name] || 'default'
        vagrant_cmd = "vagrant ssh-config #{hostname} > #{config.path}"
        if defined?(Bundler)
          Bundler.with_clean_env do
            `#{vagrant_cmd}`
          end
        else
          `#{vagrant_cmd}`
        end
        opts.merge!(Net::SSH::Config.for(hostname, [config.path]))
      end

      if @options["ask_password"]
        print "password: "
        password = STDIN.noecho(&:gets).strip
        print "\n"
        opts.merge!(password: password)
      end
      opts
    end

    def install
      osi = specinfra.os_info
      os = case osi[:family]
      when "redhat"
        Redhat.new(specinfra, osi)
      else
          raise "sorry unsupport os, please pull request!!!"
      end
      os.install(@options["agent-version"]) if @options["agent-version"]
      Pero::History::Attribute.new(specinfra, @options).save
    end

    def stop_master
      run_container.kill if docker.alerady_run?
    end

    def serve_master
        container = run_container
        begin
          yield container
        rescue => e
          Pero.log.error e.inspect
          raise e
        end
    end

    def docker
      Pero::Docker.new(@options["server-version"], @options["image-name"], @options["environment"], @options["volumes"])
    end

    def run_container
      begin
        @mutex.lock
        docker.alerady_run? || docker.run
      ensure
        @mutex.unlock
      end
    end

    def apply
      serve_master do |container|
        port = container.info["Ports"].first["PublicPort"]
        begin
          tmpdir=container.info["id"][0..5]
          in_ssh_forwarding(port) do |host, ssh|
            Pero.log.info "#{host}:puppet cmd[#{puppet_cmd}]"
            cmd = "mkdir -p /tmp/puppet/#{tmpdir} && unshare -m -- /bin/bash -c 'export PATH=$PATH:/opt/puppetlabs/bin/ && \
                           mkdir -p `puppet config print ssldir` && mount --bind /tmp/puppet/#{tmpdir} `puppet config print ssldir` && \
                           #{puppet_cmd}'"
            Pero.log.debug "run cmd:#{cmd}"
            ssh_exec(ssh, host, cmd)

            if @options["one-shot"]
              cmd = "/bin/rm -rf /tmp/puppet/#{tmpdir}"
              ssh_exec(ssh, host, cmd)
            end

            ssh.loop {true} if ENV['PERO_DEBUG']
          end
        rescue => e
          Pero.log.error "puppet apply error:#{e.inspect}"
        end
      end

      Pero::History::Attribute.new(specinfra, @options).save
    end

    def ssh_exec(ssh, host, cmd)
      ssh.open_channel do |ch|
        ch.request_pty
        ch.on_data do |ch,data|
          Pero.log.info "#{host}:#{data.chomp}"
        end

        ch.on_extended_data do |c,type,data|
          Pero.log.error "#{host}:#{data.chomp}"
        end

        ch.exec specinfra.build_command(cmd) do |ch, success|
          raise "could not execute #{cmd}" unless success
        end
      end
      ssh.loop
    end

    def puppet_cmd
        if Gem::Version.new("5.0.0") > Gem::Version.new(@options["agent-version"])
            "puppet agent --no-daemonize --onetime #{parse_puppet_option(@options)} --ca_port 8140 --ca_server localhost --masterport 8140 --server localhost"
        else
            "/opt/puppetlabs/bin/puppet agent --no-daemonize --onetime #{parse_puppet_option(@options)} --ca_server localhost --masterport 8140 --server localhost"
        end
    end

    def parse_puppet_option(options)
      ret = ""
      %w(noop verbose test debug show_diff).each do |n|
        ret << " --#{n}" if options[n]
      end
      ret << " --tags #{options["tags"].join(",")}" if options["tags"]
      ret << " --environment #{options["environment"]}" if options["environment"]
      ret
    end

    def in_ssh_forwarding(port)
      options = specinfra.get_config(:ssh_options)

      if !Net::SSH::VALID_OPTIONS.include?(:strict_host_key_checking)
        options.delete(:strict_host_key_checking)
      end

      Pero.log.info "start forwarding #{specinfra.get_config(:host)}:8140 => localhost:#{port}"
      Net::SSH.start(
        specinfra.get_config(:host),
        options[:user],
        options
      ) do |ssh|
        ssh.forward.remote(port, 'localhost', 8140)
        yield specinfra.get_config(:host), ssh
      end
    end
  end
end
