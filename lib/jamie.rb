# -*- encoding: utf-8 -*-

require 'base64'
require 'delegate'
require 'digest'
require 'fileutils'
require 'json'
require 'mixlib/shellout'
require 'net/https'
require 'net/scp'
require 'net/ssh'
require 'socket'
require 'stringio'
require 'yaml'
require 'vendor/hash_recursive_merge'

require 'jamie/version'

module Jamie

  # Returns the root path of the Jamie gem source code.
  #
  # @return [Pathname] root path of gem
  def self.source_root
    @source_root ||= Pathname.new(File.expand_path('../../', __FILE__))
  end

  # Base configuration class for Jamie. This class exposes configuration such
  # as the location of the Jamie YAML file, instances, log_levels, etc.
  class Config

    attr_writer :yaml_file
    attr_writer :platforms
    attr_writer :suites
    attr_writer :log_level
    attr_writer :test_base_path

    # Default path to the Jamie YAML file
    DEFAULT_YAML_FILE = File.join(Dir.pwd, '.jamie.yml').freeze

    # Default log level verbosity
    DEFAULT_LOG_LEVEL = :info

    # Default driver plugin to use
    DEFAULT_DRIVER_PLUGIN = "vagrant".freeze

    # Default base path which may contain `data_bags/` directories
    DEFAULT_TEST_BASE_PATH = File.join(Dir.pwd, 'test/integration').freeze

    # Creates a new configuration.
    #
    # @param yaml_file [String] optional path to Jamie YAML file
    def initialize(yaml_file = nil)
      @yaml_file = yaml_file
    end

    # @return [Array<Platform>] all defined platforms which will be used in
    #   convergence integration
    def platforms
      @platforms ||= Collection.new(
        Array(yaml["platforms"]).map { |hash| new_platform(hash) })
    end

    # @return [Array<Suite>] all defined suites which will be used in
    #   convergence integration
    def suites
      @suites ||= Collection.new(
        Array(yaml["suites"]).map { |hash| new_suite(hash) })
    end

    # @return [Array<Instance>] all instances, resulting from all platform and
    #   suite combinations
    def instances
      @instances ||= Collection.new(suites.map { |suite|
        platforms.map { |platform| Instance.new(suite, platform) }
      }.flatten)
    end

    # @return [String] path to the Jamie YAML file
    def yaml_file
      @yaml_file ||= DEFAULT_YAML_FILE
    end

    # @return [Symbol] log level verbosity
    def log_level
      @log_level ||= DEFAULT_LOG_LEVEL
    end

    # @return [String] base path that may contain a common `data_bags/`
    #   directory or an instance's `data_bags/` directory
    def test_base_path
      @test_base_path ||= DEFAULT_TEST_BASE_PATH
    end

    # Delegate class which adds the ability to find single and multiple
    # objects by their #name in an Array. Hey, it's better than monkey-patching
    # Array, right?
    class Collection < SimpleDelegator

      # Returns a single object by its name, or nil if none are found.
      #
      # @param name [String] name of object
      # @return [Object] first match by name, or nil if none are found
      def get(name)
        __getobj__.find { |i| i.name == name }
      end

      # Returns a Collection of all objects whose #name is matched by the
      # regular expression.
      #
      # @param regexp [Regexp] a regular expression pattern
      # @return [Jamie::Config::Collection<Object>] a new collection of
      #   matched objects
      def get_all(regexp)
        Jamie::Config::Collection.new(
          __getobj__.find_all { |i| i.name =~ regexp }
        )
      end

      # Returns an Array of names from the collection as strings.
      #
      # @return [Array<String>] array of name strings
      def as_names
        __getobj__.map { |i| i.name }
      end
    end

    private

    def new_suite(hash)
      data_bags_path = calculate_data_bags_path(hash['name'])
      roles_path = calculate_roles_path(hash['name'])
      path_hash = {
        'data_bags_path' => data_bags_path,
        'roles_path'     => roles_path
      }
      Suite.new(hash.rmerge(path_hash))
    end

    def new_platform(hash)
      mpc = merge_platform_config(hash)
      mpc['driver_config']['jamie_root'] = File.dirname(yaml_file)
      mpc['driver'] = new_driver(mpc['driver_plugin'], mpc['driver_config'])
      Platform.new(mpc)
    end

    def new_driver(plugin, config)
      Driver.for_plugin(plugin, config)
    end

    def yaml
      @yaml ||= YAML.load_file(File.expand_path(yaml_file)).rmerge(local_yaml)
    end

    def local_yaml_file
      std = File.expand_path(yaml_file)
      std.sub(/(#{File.extname(std)})$/, '.local\1')
    end

    def local_yaml
      @local_yaml ||= begin
        if File.exists?(local_yaml_file)
          YAML.load_file(local_yaml_file)
        else
          Hash.new
        end
      end
    end

    def merge_platform_config(platform_config)
      default_driver_config.rmerge(common_driver_config.rmerge(platform_config))
    end

    def calculate_roles_path(suite_name)
      suite_roles_path = File.join(test_base_path, suite_name, "roles")
      common_roles_path = File.join(test_base_path, "roles")
      top_level_roles_path = File.join(Dir.pwd, "roles")

      if File.directory?(suite_roles_path)
        suite_roles_path
      elsif File.directory?(common_roles_path)
        common_roles_path
      elsif File.directory?(top_level_roles_path)
        top_level_roles_path
      else
        nil
      end
    end

    def calculate_data_bags_path(suite_name)
      suite_data_bags_path = File.join(test_base_path, suite_name, "data_bags")
      common_data_bags_path = File.join(test_base_path, "data_bags")
      top_level_data_bags_path = File.join(Dir.pwd, "data_bags")

      if File.directory?(suite_data_bags_path)
        suite_data_bags_path
      elsif File.directory?(common_data_bags_path)
        common_data_bags_path
      elsif File.directory?(top_level_data_bags_path)
        top_level_data_bags_path
      else
        nil
      end
    end

    def default_driver_config
      { 'driver_plugin' => DEFAULT_DRIVER_PLUGIN }
    end

    def common_driver_config
      yaml.select { |key, value| %w(driver_plugin driver_config).include?(key) }
    end
  end

  # A Chef run_list and attribute hash that will be used in a convergence
  # integration.
  class Suite

    # @return [String] logical name of this suite
    attr_reader :name

    # @return [Array] Array of Chef run_list items
    attr_reader :run_list

    # @return [Hash] Hash of Chef node attributes
    attr_reader :attributes

    # @return [String] local path to the suite's data bags, or nil if one does
    #   not exist
    attr_reader :data_bags_path

    # @return [String] local path to the suite's roles, or nil if one does
    #   not exist
    attr_reader :roles_path

    # Constructs a new suite.
    #
    # @param [Hash] options configuration for a new suite
    # @option options [String] :name logical name of this suit (**Required**)
    # @option options [String] :run_list Array of Chef run_list items
    #   (**Required**)
    # @option options [Hash] :attributes Hash of Chef node attributes
    # @option options [String] :data_bags_path path to data bags
    def initialize(options = {})
      validate_options(options)

      @name = options['name']
      @run_list = options['run_list']
      @attributes = options['attributes'] || Hash.new
      @data_bags_path = options['data_bags_path']
      @roles_path = options['roles_path']
    end

    private

    def validate_options(opts)
      %w(name run_list).each do |k|
        raise ArgumentError, "Attribute '#{attr}' is required." if opts[k].nil?
      end
    end
  end

  # A target operating system environment in which convergence integration
  # will take place. This may represent a specific operating system, version,
  # and machine architecture.
  class Platform

    # @return [String] logical name of this platform
    attr_reader :name

    # @return [Driver::Base] driver object which will manage this platform's
    #   lifecycle actions
    attr_reader :driver

    # @return [Array] Array of Chef run_list items
    attr_reader :run_list

    # @return [Hash] Hash of Chef node attributes
    attr_reader :attributes

    # Constructs a new platform.
    #
    # @param [Hash] options configuration for a new platform
    # @option options [String] :name logical name of this platform
    #   (**Required**)
    # @option options [Driver::Base] :driver subclass of Driver::Base which
    #   will manage this platform's lifecycle actions (**Required**)
    # @option options [Array<String>] :run_list Array of Chef run_list
    #   items
    # @option options [Hash] :attributes Hash of Chef node attributes
    def initialize(options = {})
      validate_options(options)

      @name = options['name']
      @driver = options['driver']
      @run_list = Array(options['run_list'])
      @attributes = options['attributes'] || Hash.new
    end

    private

    def validate_options(opts)
      %w(name driver).each do |k|
        raise ArgumentError, "Attribute '#{attr}' is required." if opts[k].nil?
      end
    end
  end

  # An instance of a suite running on a platform. A created instance may be a
  # local virtual machine, cloud instance, container, or even a bare metal
  # server, which is determined by the platform's driver.
  class Instance

    # @return [Suite] the test suite configuration
    attr_reader :suite

    # @return [Platform] the target platform configuration
    attr_reader :platform

    # @return [Jr] jr command string generator
    attr_reader :jr

    # Creates a new instance, given a suite and a platform.
    #
    # @param suite [Suite] a suite
    # @param platform [Platform] a platform
    def initialize(suite, platform)
      @suite = suite
      @platform = platform
      @jr = Jr.new(@suite.name)
    end

    # @return [String] name of this instance
    def name
      "#{suite.name}-#{platform.name}".gsub(/_/, '-').gsub(/\./, '')
    end

    # Returns a combined run_list starting with the platform's run_list
    # followed by the suite's run_list.
    #
    # @return [Array] combined run_list from suite and platform
    def run_list
      Array(platform.run_list) + Array(suite.run_list)
    end

    # Returns a merged hash of Chef node attributes with values from the
    # suite overriding values from the platform.
    #
    # @return [Hash] merged hash of Chef node attributes
    def attributes
      platform.attributes.rmerge(suite.attributes)
    end

    def dna
      attributes.rmerge({ 'run_list' => run_list })
    end

    # Creates this instance.
    #
    # @see Driver::Base#create
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def create
      puts "-----> Creating instance #{name}"
      platform.driver.create(self)
      puts "       Creation of instance #{name} complete."
      self
    end

    # Converges this running instance.
    #
    # @see Driver::Base#converge
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def converge
      puts "-----> Converging instance #{name}"
      platform.driver.converge(self)
      puts "       Convergence of instance #{name} complete."
      self
    end

    # Sets up this converged instance for suite tests.
    #
    # @see Driver::Base#setup
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def setup
      puts "-----> Setting up instance #{name}"
      platform.driver.setup(self)
      puts "       Setup of instance #{name} complete."
      self
    end

    # Verifies this set up instance by executing suite tests.
    #
    # @see Driver::Base#verify
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def verify
      puts "-----> Verifying instance #{name}"
      platform.driver.verify(self)
      puts "       Verification of instance #{name} complete."
      self
    end

    # Destroys this instance.
    #
    # @see Driver::Base#destroy
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def destroy
      puts "-----> Destroying instance #{name}"
      platform.driver.destroy(self)
      puts "       Destruction of instance #{name} complete."
      self
    end

    # Tests this instance by creating, converging and verifying. If this
    # instance is running, it will be pre-emptively destroyed to ensure a
    # clean slate. The instance will be left post-verify in a running state.
    #
    # @see #destroy
    # @see #create
    # @see #converge
    # @see #setup
    # @see #verify
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def test
      puts "-----> Cleaning up any prior instances of #{name}"
      destroy
      puts "-----> Testing instance #{name}"
      create
      converge
      setup
      verify
      puts "       Testing of instance #{name} complete."
      self
    end
  end

  # Command string generator to interface with Jamie Runner (jr). The
  # commands that are generated are safe to pass to an SSH command or as an
  # unix command argument (escaped in single quotes).
  class Jr

    # Constructs a new jr command generator, given a suite name.
    #
    # @param [String] suite_name name of suite on which to operate
    #   (**Required**)
    # @param [Hash] opts optional configuration
    # @option opts [TrueClass, FalseClass] :use_sudo whether or not to invoke
    #   sudo before commands requiring root access (default: `true`)
    def initialize(suite_name, opts = {:use_sudo => true})
      validate_options(suite_name)

      @suite_name = suite_name
      @use_sudo = opts[:use_sudo]
    end

    # Returns a command string which installs the Jamie Runner (jr), installs
    # all required jr plugins for the suite.
    #
    # If no work needs to be performed, for example if there are no tests for
    # the given suite, then `nil` will be returned.
    #
    # @return [String] a command string to setup the test suite, or nil if no
    #   work needs to be performed
    def setup_cmd
      @setup_cmd ||= if local_suite_files.empty?
        nil
      else
        <<-INSTALL_CMD.gsub(/ {10}/, '')
          #{sudo}#{ruby_bin} -e "$(cat <<"EOF"
          #{install_script}
          EOF
          )"
          #{sudo}#{jr_bin} install #{plugins.join(' ')}
        INSTALL_CMD
      end
    end

    # Returns a command string which transfers all suite test files to the
    # instance.
    #
    # If no work needs to be performed, for example if there are no tests for
    # the given suite, then `nil` will be returned.
    #
    # @return [String] a command string to transfer all suite test files, or
    #   nil if no work needs to be performed.
    def sync_cmd
      @sync_cmd ||= if local_suite_files.empty?
        nil
      else
        <<-INSTALL_CMD.gsub(/ {10}/, '')
          #{sudo}#{jr_bin} cleanup-suites
          #{local_suite_files.map { |f| stream_file(f, remote_file(f)) }.join}
        INSTALL_CMD
      end
    end

    # Returns a command string which runs all jr suite tests for the suite.
    #
    # If no work needs to be performed, for example if there are no tests for
    # the given suite, then `nil` will be returned.
    #
    # @return [String] a command string to run the test suites, or nil if no
    #   work needs to be performed
    def run_cmd
      @run_cmd ||= local_suite_files.empty? ? nil : "#{sudo}#{jr_bin} test"
    end

    private

    INSTALL_URL = "https://raw.github.com/jamie-ci/jr/go".freeze
    DEFAULT_RUBY_BINPATH = "/opt/chef/embedded/bin".freeze
    DEFAULT_JR_ROOT = "/opt/jr".freeze
    DEFAULT_TEST_ROOT = File.join(Dir.pwd, "test/integration").freeze

    def validate_options(suite_name)
      raise ArgumentError, "'suite_name' is required." if suite_name.nil?
    end

    def install_script
      @install_script ||= begin
        uri = URI.parse(INSTALL_URL)
        http = Net::HTTP.new(uri.host, 443)
        http.use_ssl = true
        response = http.request(Net::HTTP::Get.new(uri.path))
        response.body
      end
    end

    def plugins
      Dir.glob(File.join(test_root, @suite_name, "*")).select { |d|
        File.directory?(d) && File.basename(d) != "data_bags"
      }.map { |d| File.basename(d) }.sort.uniq
    end

    def local_suite_files
      Dir.glob(File.join(test_root, @suite_name, "*/**/*")).reject do |f|
        f["data_bags"] || File.directory?(f)
      end
    end

    def remote_file(file)
      local_prefix = File.join(test_root, @suite_name)
      "$(#{jr_bin} suitepath)/".concat(file.sub(%r{^#{local_prefix}/}, ''))
    end

    def stream_file(local_path, remote_path)
      local_file = IO.read(local_path)
      md5 = Digest::MD5.hexdigest(local_file)
      perms = sprintf("%o", File.stat(local_path).mode)[3,3]
      jr_stream_file = "#{jr_bin} stream-file #{remote_path} #{md5} #{perms}"

      <<-STREAMFILE.gsub(/^ {8}/, '')
        echo "       Uploading #{remote_path} (mode=#{perms})"
        cat <<"__EOFSTREAM__" | #{sudo}#{jr_stream_file}
        #{Base64.encode64(local_file)}
        __EOFSTREAM__
      STREAMFILE
    end

    def sudo
      @use_sudo ? "sudo " : ""
    end

    def ruby_bin
      File.join(DEFAULT_RUBY_BINPATH, "ruby")
    end

    def jr_bin
      File.join(DEFAULT_JR_ROOT, "bin/jr")
    end

    def test_root
      DEFAULT_TEST_ROOT
    end
  end

  # Stateless utility methods used in different contexts. Essentially a mini
  # PassiveSupport library.
  module Util

    def self.to_camel_case(str)
      str.split('_').map { |w| w.capitalize }.join
    end

    def self.to_snake_case(str)
      str.split('::').
        last.
        gsub(/([A-Z+])([A-Z][a-z])/, '\1_\2').
        gsub(/([a-z\d])([A-Z])/, '\1_\2').
        downcase
    end
  end

  # Mixin that wraps a command shell out invocation, providing a #run_command
  # method.
  module ShellOut

    # Wrapped exception for any interally raised shell out commands.
    class ShellCommandFailed < StandardError ; end

    # Executes a command in a subshell on the local running system.
    #
    # @param cmd [String] command to be executed locally
    # @param use_sudo [TrueClass, FalseClass] whether or not to use sudo
    # @param log_subject [String] used in the output or log header for clarity
    #   and context
    def run_command(cmd, use_sudo = false, log_subject = "local")
      cmd = "sudo #{cmd}" if use_sudo
      subject = "       [#{log_subject} command]"

      $stdout.puts "#{subject} (#{display_cmd(cmd)})"
      sh = Mixlib::ShellOut.new(cmd, :live_stream => $stdout, :timeout => 60000)
      sh.run_command
      puts "#{subject} ran in #{sh.execution_time} seconds."
      sh.error!
    rescue Mixlib::ShellOut::ShellCommandFailed => ex
      raise ShellCommandFailed, ex.message
    end

    private

    def display_cmd(cmd)
      first_line, newline, rest = cmd.partition("\n")
      last_char = cmd[cmd.size - 1]

      newline == "\n" ? "#{first_line}\\n...#{last_char}" : cmd
    end
  end

  module Driver

    # Wrapped exception for any internally raised driver exceptions.
    class ActionFailed < StandardError ; end

    # Returns an instance of a driver given a plugin type string.
    #
    # @param plugin [String] a driver plugin type, which will be constantized
    # @return [Driver::Base] a driver instance
    def self.for_plugin(plugin, config)
      require "jamie/driver/#{plugin}"

      klass = self.const_get(Util.to_camel_case(plugin))
      klass.new(config)
    end

    # Base class for a driver. A driver is responsible for carrying out the
    # lifecycle activities of an instance, such as creating, converging, and
    # destroying an instance.
    class Base

      include ShellOut

      def initialize(config)
        @config = config
        self.class.defaults.each do |attr, value|
          @config[attr] = value unless @config[attr]
        end
      end

      # Provides hash-like access to configuration keys.
      #
      # @param attr [Object] configuration key
      # @return [Object] value at configuration key
      def [](attr)
        config[attr]
      end

      # Creates an instance.
      #
      # @param instance [Instance] an instance
      # @raise [ActionFailed] if the action could not be completed
      def create(instance)
        action(:create, instance)
      end

      # Converges a running instance.
      #
      # @param instance [Instance] an instance
      # @raise [ActionFailed] if the action could not be completed
      def converge(instance)
        action(:converge, instance)
      end

      # Sets up an instance.
      #
      # @param instance [Instance] an instance
      # @raise [ActionFailed] if the action could not be completed
      def setup(instance)
        action(:setup, instance)
      end

      # Verifies a converged instance.
      #
      # @param instance [Instance] an instance
      # @raise [ActionFailed] if the action could not be completed
      def verify(instance)
        action(:verify, instance)
      end

      # Destroys an instance.
      #
      # @param instance [Instance] an instance
      # @raise [ActionFailed] if the action could not be completed
      def destroy(instance)
        action(:destroy, instance)
        destroy_state(instance)
      end

      protected

      attr_reader :config

      def action(what, instance)
        state = load_state(instance)
        public_send("perform_#{what}", instance, state)
        state['last_action'] = what.to_s
      ensure
        dump_state(instance, state)
      end

      def load_state(instance)
        statefile = state_filepath(instance)

        if File.exists?(statefile)
          YAML.load_file(statefile)
        else
          { 'name' => instance.name }
        end
      end

      def dump_state(instance, state)
        statefile = state_filepath(instance)
        dir = File.dirname(statefile)

        FileUtils.mkdir_p(dir) if !File.directory?(dir)
        File.open(statefile, "wb") { |f| f.write(YAML.dump(state)) }
      end

      def destroy_state(instance)
        statefile = state_filepath(instance)
        FileUtils.rm(statefile) if File.exists?(statefile)
      end

      def state_filepath(instance)
        File.expand_path(File.join(
          config['jamie_root'], ".jamie", "#{instance.name}.yml"
        ))
      end

      def run_command(cmd, use_sudo = nil, log_subject = nil)
        use_sudo = config['use_sudo'] if use_sudo.nil?
        log_subject = Util.to_snake_case(self.class.to_s)

        super(cmd, use_sudo, log_subject)
      end

      def self.defaults
        @defaults ||= Hash.new
      end

      def self.default_config(attr, value)
        defaults[attr] = value
      end
    end

    # Base class for a driver that uses SSH to communication with an instance.
    # A subclass must implement the following methods:
    # * #perform_create(instance, state)
    # * #perform_destroy(instance, state)
    class SSHBase < Base

      def perform_converge(instance, state)
        ssh_args = generate_ssh_args(state)

        install_omnibus(ssh_args) if config['require_chef_omnibus']
        prepare_chef_home(ssh_args)
        upload_chef_data(ssh_args, instance)
        run_chef_solo(ssh_args)
      end

      def perform_setup(instance, state)
        ssh_args = generate_ssh_args(state)

        if instance.jr.setup_cmd
          ssh(ssh_args, instance.jr.setup_cmd)
        end
      end

      def perform_verify(instance, state)
        ssh_args = generate_ssh_args(state)

        if instance.jr.run_cmd
          ssh(ssh_args, instance.jr.sync_cmd)
          ssh(ssh_args, instance.jr.run_cmd)
        end
      end

      protected

      def generate_ssh_args(state)
        [ state['hostname'],
          config['username'],
          { :password => config['password'] }
        ]
      end

      def chef_home
        "/tmp/jamie-chef-solo".freeze
      end

      def install_omnibus(ssh_args)
        ssh(ssh_args, <<-INSTALL)
          if [ ! -d "/opt/chef" ] ; then
            curl -L https://www.opscode.com/chef/install.sh | sudo bash
          fi
        INSTALL
      end

      def prepare_chef_home(ssh_args)
        ssh(ssh_args, "sudo rm -rf #{chef_home} && mkdir -p #{chef_home}")
      end

      def upload_chef_data(ssh_args, instance)
        Jamie::ChefDataUploader.new(
          instance, ssh_args, config['jamie_root'], chef_home
        ).upload
      end

      def run_chef_solo(ssh_args)
        ssh(ssh_args, <<-RUN_SOLO)
          sudo chef-solo -c #{chef_home}/solo.rb -j #{chef_home}/dna.json
        RUN_SOLO
      end

      def ssh(ssh_args, cmd)
        Net::SSH.start(*ssh_args) do |ssh|
          exit_code = ssh_exec_with_exit!(ssh, cmd)

          if exit_code != 0
            shorter_cmd = cmd.squeeze(" ").strip
            raise ActionFailed,
              "SSH exited (#{exit_code}) for command: [#{shorter_cmd}]"
          end
        end
      rescue Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      def ssh_exec_with_exit!(ssh, cmd)
        exit_code = nil
        ssh.open_channel do |channel|
          channel.exec(cmd) do |ch, success|

            channel.on_data do |ch, data|
              $stdout.print data
            end

            channel.on_extended_data do |ch, type, data|
              $stderr.print data
            end

            channel.on_request("exit-status") do |ch, data|
              exit_code = data.read_long
            end
          end
        end
        ssh.loop
        exit_code
      end

      def wait_for_sshd(hostname)
        print "." until test_ssh(hostname)
      end

      def test_ssh(hostname)
        socket = TCPSocket.new(hostname, config['port'])
        IO.select([socket], nil, nil, 5)
      rescue SocketError, Errno::ECONNREFUSED,
          Errno::EHOSTUNREACH, Errno::ENETUNREACH, IOError
        sleep 2
        false
      rescue Errno::EPERM, Errno::ETIMEDOUT
        false
      ensure
        socket && socket.close
      end
    end
  end

  # Uploads Chef asset files such as dna.json, data bags, and cookbooks to an
  # instance over SSH.
  class ChefDataUploader

    include ShellOut

    def initialize(instance, ssh_args, jamie_root, chef_home)
      @instance = instance
      @ssh_args = ssh_args
      @jamie_root = jamie_root
      @chef_home = chef_home
    end

    def upload
      Net::SCP.start(*ssh_args) do |scp|
        upload_json       scp
        upload_solo_rb    scp
        upload_cookbooks  scp
        upload_data_bags  scp if instance.suite.data_bags_path
        upload_roles      scp if instance.suite.roles_path
      end
    end

    private

    attr_reader :instance, :ssh_args, :jamie_root, :chef_home

    def upload_json(scp)
      json_file = StringIO.new(instance.dna.to_json)
      scp.upload!(json_file, "#{chef_home}/dna.json")
    end

    def upload_solo_rb(scp)
      solo_rb_file = StringIO.new(solo_rb_contents)
      scp.upload!(solo_rb_file, "#{chef_home}/solo.rb")
    end

    def upload_cookbooks(scp)
      cookbooks_dir = local_cookbooks
      scp.upload!(cookbooks_dir, "#{chef_home}/cookbooks",
        :recursive => true
      ) do |ch, name, sent, total|
        file = name.sub(%r{^#{cookbooks_dir}/}, '')
        puts "       #{file}: #{sent}/#{total}"
      end
    ensure
      FileUtils.rmtree(cookbooks_dir)
    end

    def upload_data_bags(scp)
      data_bags_dir = instance.suite.data_bags_path
      scp.upload!(data_bags_dir, "#{chef_home}/data_bags",
        :recursive => true
      ) do |ch, name, sent, total|
        file = name.sub(%r{^#{data_bags_dir}/}, '')
        puts "       #{file}: #{sent}/#{total}"
      end
    end

    def upload_roles(scp)
      roles_dir = instance.suite.roles_path
      scp.upload!(roles_dir, "#{chef_home}/roles",
        :recursive => true
      ) do |ch, name, sent, total|
        file = name.sub(%r{^#{roles_dir}/}, '')
        puts "       #{file}: #{sent}/#{total}"
      end
    end

    def solo_rb_contents
      solo = []
      solo << %{node_name "#{instance.name}"}
      solo << %{file_cache_path "#{chef_home}/cache"}
      solo << %{cookbook_path "#{chef_home}/cookbooks"}
      solo << %{role_path "#{chef_home}/roles"}
      if instance.suite.data_bags_path
        solo << %{data_bag_path "#{chef_home}/data_bags"}
      end
      solo << %{log_level :info}
      solo.join("\n")
    end

    def local_cookbooks
      if File.exists?(File.join(jamie_root, "Berksfile"))
        tmpdir = Dir.mktmpdir(instance.name)
        run_berks(tmpdir)
        tmpdir
      elsif File.exists?(File.join(jamie_root, "Cheffile"))
        tmpdir = Dir.mktmpdir(instance.name)
        run_librarian(tmpdir)
        tmpdir
      else
        abort "Berksfile or Cheffile must exist in #{jamie_root}"
      end
    end

    def run_berks(tmpdir)
      begin
        run_command "if ! command -v berks >/dev/null; then exit 1; fi"
      rescue Mixlib::ShellOut::ShellCommandFailed
        abort ">>>>>> Berkshelf must be installed, add it to your Gemfile."
      end
      run_command "berks install --path #{tmpdir}"
    end

    def run_librarian(tmpdir)
      begin
        run_command "if ! command -v librarian-chef >/dev/null; then exit 1; fi"
      rescue Mixlib::ShellOut::ShellCommandFailed
        abort ">>>>>> Librarian must be installed, add it to your Gemfile."
      end
      run_command "librarian-chef install --path #{tmpdir}"
    end
  end

end
