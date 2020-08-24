require "pero"
require "thor"
require "parallel"

module Pero
  class CLI < Thor
    class << self
      def exit_on_failure?
        true
      end
    end

    def initialize(*)
      super
      Pero.log.level = ::Logger.const_get(options[:log_level].upcase) if options[:log_level]
    end

    def self.shared_options
      option :log_level, type: :string, aliases: ['-l'], default: 'info'
      option :user, type: :string, aliases: ['-x'], desc: "ssh user"
      option :key, type: :string, aliases: ['-i'], desc: "ssh private key"
      option :port, type: :numeric, aliases: ['-p'], desc: "ssh port"
      option :ssh_config, type: :string, desc: "ssh config path"
      option :environment, type: :string, desc: "puppet environment"
      option :ask_password, type: :boolean, default: false, desc: "ask ssh or sudo password"
      option :vagrant, type: :boolean, default: false, desc: "use vagrarant"
      option :sudo, type: :boolean, default: true, desc: "use sudo"
      option "concurrent", aliases: '-N',default: 3, type: :numeric, desc: "running concurrent"
    end

    desc "versions", "show support version"
    def versions
      Pero::Puppet::Redhat.show_versions
    end

    desc "apply", "puppet apply"
    shared_options
    option "server-version", type: :string, default: "6.12.0"
    option :noop, aliases: '-n', default: false, type: :boolean
    option :verbose, aliases: '-v', default: true, type: :boolean
    option :tags, default: nil, type: :array
    option "one-shot", default: false, type: :boolean, desc: "stop puppet server after run"
    def apply(name_regexp)
      nodes = Pero::History.search(name_regexp)
      return unless nodes
      Parallel.each(nodes, in_process: options["concurrent"]) do |n|
        opt = n["last_options"].merge(options)
        puppet = Pero::Puppet.new(opt["host"], opt)
        puppet.apply
      end
    end

    desc "install", "install puppet"
    shared_options
    option "agent-version", default: "6.17.0", type: :string
    option "node-name", aliases: '-N', default: "", type: :string, desc: "json node name(default hostname)"
    def install(*hosts)
      Parallel.each(hosts, in_process: options["concurrent"]) do |host|
        next if host =~ /^-/
        puppet = Pero::Puppet.new(host, options)
        puppet.install
      end
    end
  end
end
