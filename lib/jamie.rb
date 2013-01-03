# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'base64'
require 'benchmark'
require 'delegate'
require 'digest'
require 'erb'
require 'fileutils'
require 'json'
require 'logger'
require 'mixlib/shellout'
require 'net/https'
require 'net/scp'
require 'net/ssh'
require 'pathname'
require 'socket'
require 'stringio'
require 'yaml'
require 'vendor/hash_recursive_merge'

require 'jamie/version'

module Jamie

  class << self

    attr_accessor :logger

    # Returns the root path of the Jamie gem source code.
    #
    # @return [Pathname] root path of gem
    def source_root
      @source_root ||= Pathname.new(File.expand_path('../../', __FILE__))
    end

    def default_logger
      env_log = ENV['JAMIE_LOG'] && ENV['JAMIE_LOG'].downcase.to_sym

      Logger.new(:console => STDOUT, :level => env_log)
    end
  end

  # Base configuration class for Jamie. This class exposes configuration such
  # as the location of the Jamie YAML file, instances, log_levels, etc.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
  class Config

    attr_writer :yaml_file
    attr_writer :platforms
    attr_writer :suites
    attr_writer :log_level
    attr_writer :test_base_path

    # Default path to the Jamie YAML file
    DEFAULT_YAML_FILE = File.join(Dir.pwd, '.jamie.yml').freeze

    # Default driver plugin to use
    DEFAULT_DRIVER_PLUGIN = "dummy".freeze

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
        platforms.map { |platform| new_instance(suite, platform) }
      }.flatten)
    end

    # @return [String] path to the Jamie YAML file
    def yaml_file
      @yaml_file ||= DEFAULT_YAML_FILE
    end

    # @return [Symbol] log level verbosity
    def log_level
      @log_level ||= begin
        ENV['JAMIE_LOG'] && ENV['JAMIE_LOG'].downcase.to_sym ||
        Jamie::DEFAULT_LOG_LEVEL
      end
    end

    # @return [String] base path that may contain a common `data_bags/`
    #   directory or an instance's `data_bags/` directory
    def test_base_path
      @test_base_path ||= DEFAULT_TEST_BASE_PATH
    end

    # Delegate class which adds the ability to find single and multiple
    # objects by their #name in an Array. Hey, it's better than monkey-patching
    # Array, right?
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
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
      Platform.new(hash)
    end

    def new_driver(hash)
      hash['driver_config'] ||= Hash.new
      hash['driver_config']['jamie_root'] = jamie_root
      Driver.for_plugin(hash['driver_plugin'], hash['driver_config'])
    end

    def new_instance(suite, platform)
      log_root = File.expand_path(File.join(jamie_root, ".jamie", "logs"))
      platform_hash = platform_driver_hash(platform.name)
      driver = new_driver(merge_driver_hash(platform_hash))
      FileUtils.mkdir_p(log_root)

      Instance.new(
        'suite'     => suite,
        'platform'  => platform,
        'driver'    => driver,
        'jr'        => Jr.new(suite.name),
        'logger'    => new_instance_logger(log_root)
      )
    end

    def platform_driver_hash(platform_name)
      h = yaml['platforms'].find { |p| p['name'] == platform_name } || Hash.new

      h.select { |key, value| %w(driver_plugin driver_config).include?(key) }
    end

    def new_instance_logger(log_root)
      level = Util.to_logger_level(self.log_level)

      lambda do |name|
        logfile = File.join(log_root, "#{name}.log")

        Logger.new(:stdout => STDOUT, :logdev => logfile,
          :level => level, :progname => name)
      end
    end

    def yaml
      @yaml ||= YAML.load(yaml_contents).rmerge(local_yaml)
    end

    def yaml_contents
      ERB.new(IO.read(File.expand_path(yaml_file))).result
    end

    def local_yaml_file
      std = File.expand_path(yaml_file)
      std.sub(/(#{File.extname(std)})$/, '.local\1')
    end

    def local_yaml
      @local_yaml ||= begin
        if File.exists?(local_yaml_file)
          YAML.load(ERB.new(IO.read(local_yaml_file)).result)
        else
          Hash.new
        end
      end
    end

    def jamie_root
      File.dirname(yaml_file)
    end

    def merge_driver_hash(driver_hash)
      default_driver_hash.rmerge(common_driver_hash.rmerge(driver_hash))
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

    def default_driver_hash
      { 'driver_plugin' => DEFAULT_DRIVER_PLUGIN, 'driver_config' => {} }
    end

    def common_driver_hash
      yaml.select { |key, value| %w(driver_plugin driver_config).include?(key) }
    end
  end

  # Default log level verbosity
  DEFAULT_LOG_LEVEL = :info

  # Logging implementation for Jamie. By default the console/stdout output will
  # be displayed differently than the file log output. Therefor, this class
  # wraps multiple loggers that conform to the stdlib `Logger` class behavior.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
  class Logger

    include ::Logger::Severity

    def initialize(options = {})
      @loggers = []
      @loggers << logdev_logger(options[:logdev]) if options[:logdev]
      @loggers << stdout_logger(options[:stdout]) if options[:stdout]
      @loggers << stdout_logger(STDOUT) if @loggers.empty?

      self.progname = options[:progname] || "Jamie"
      self.level = options[:level] || default_log_level
    end

    %w{ level progname datetime_format debug? info? error? warn? fatal?
    }.each do |meth|
      define_method(meth) do |*args|
        @loggers.first.public_send(meth, *args)
      end
    end

    %w{ level= progname= datetime_format= add <<
        banner debug info error warn fatal unknown close
    }.map(&:to_sym).each do |meth|
      define_method(meth) do |*args|
        result = nil
        @loggers.each { |l| result = l.public_send(meth, *args) }
        result
      end
    end

    private

    def default_log_level
      Util.to_logger_level(Jamie::DEFAULT_LOG_LEVEL)
    end

    def stdout_logger(stdout)
      logger = StdoutLogger.new(stdout)
      logger.formatter = proc do |severity, datetime, progname, msg|
        "#{msg}\n"
      end
      logger
    end

    def logdev_logger(filepath_or_logdev)
      LogdevLogger.new(logdev(filepath_or_logdev))
    end

    def logdev(filepath_or_logdev)
      if filepath_or_logdev.is_a? String
        file = File.open(File.expand_path(filepath_or_logdev), "ab")
        file.sync = true
        file
      else
        filepath_or_logdev
      end
    end

    # Internal class which adds a #banner method call that displays the
    # message with a callout arrow.
    class LogdevLogger < ::Logger

      alias_method :super_info, :info

      def <<(msg)
        msg =~ /\n/ ? msg.split("\n").each { |l| format_line(l) } : super
      end

      def banner(msg = nil, &block)
        super_info("-----> #{msg}", &block)
      end

      private

      def format_line(line)
        case line
        when %r{^-----> } then banner(line.gsub(%r{^[ >-]{6} }, ''))
        when %r{^>>>>>> } then error(line.gsub(%r{^[ >-]{6} }, ''))
        when %r{^       } then info(line.gsub(%r{^[ >-]{6} }, ''))
        else info(line)
        end
      end
    end

    # Internal class which reformats logging methods for display as console
    # output.
    class StdoutLogger < LogdevLogger

      def debug(msg = nil, &block)
        super("D      #{msg}", &block)
      end

      def info(msg = nil, &block)
        super("       #{msg}", &block)
      end

      def warn(msg = nil, &block)
        super("$$$$$$ #{msg}", &block)
      end

      def error(msg = nil, &block)
        super(">>>>>> #{msg}", &block)
      end

      def fatal(msg = nil, &block)
        super("!!!!!! #{msg}", &block)
      end
    end
  end

  module Logging

    %w{banner debug info warn error fatal}.map(&:to_sym).each do |meth|
      define_method(meth) do |*args|
        logger.public_send(meth, *args)
      end
    end
  end

  # A Chef run_list and attribute hash that will be used in a convergence
  # integration.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
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
        raise ArgumentError, "Attribute '#{k}' is required." if opts[k].nil?
      end
    end
  end

  # A target operating system environment in which convergence integration
  # will take place. This may represent a specific operating system, version,
  # and machine architecture.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
  class Platform

    # @return [String] logical name of this platform
    attr_reader :name

    # @return [Array] Array of Chef run_list items
    attr_reader :run_list

    # @return [Hash] Hash of Chef node attributes
    attr_reader :attributes

    # Constructs a new platform.
    #
    # @param [Hash] options configuration for a new platform
    # @option options [String] :name logical name of this platform
    #   (**Required**)
    # @option options [Array<String>] :run_list Array of Chef run_list
    #   items
    # @option options [Hash] :attributes Hash of Chef node attributes
    def initialize(options = {})
      validate_options(options)

      @name = options['name']
      @run_list = Array(options['run_list'])
      @attributes = options['attributes'] || Hash.new
    end

    private

    def validate_options(opts)
      %w(name).each do |k|
        raise ArgumentError, "Attribute '#{k}' is required." if opts[k].nil?
      end
    end
  end

  # An instance of a suite running on a platform. A created instance may be a
  # local virtual machine, cloud instance, container, or even a bare metal
  # server, which is determined by the platform's driver.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
  class Instance

    include Logging

    # @return [Suite] the test suite configuration
    attr_reader :suite

    # @return [Platform] the target platform configuration
    attr_reader :platform

    # @return [Driver::Base] driver object which will manage this instance's
    #   lifecycle actions
    attr_reader :driver

    # @return [Jr] jr command string generator
    attr_reader :jr

    # @return [Logger] the logger for this instance
    attr_reader :logger

    # Creates a new instance, given a suite and a platform.
    #
    # @param [Hash] options configuration for a new suite
    # @option options [Suite] :suite the suite
    # @option options [Platform] :platform the platform
    # @option options [Driver::Base] :driver the driver
    # @option options [Jr] :jr the jr command string generator
    # @option options [Logger] :logger the instance logger
    def initialize(options = {})
      options = { 'logger' => Jamie.logger }.merge(options)
      validate_options(options)
      logger = options['logger']

      @suite = options['suite']
      @platform = options['platform']
      @driver = options['driver']
      @jr = options['jr']
      @logger = logger.is_a?(Proc) ? logger.call(name) : logger

      @driver.instance = self
    end

    # @return [String] name of this instance
    def name
      "#{suite.name}-#{platform.name}".gsub(/_/, '-').gsub(/\./, '')
    end

    def to_s
      "<#{name}>"
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
      transition_to(:create)
    end

    # Converges this running instance.
    #
    # @see Driver::Base#converge
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def converge
      transition_to(:converge)
    end

    # Sets up this converged instance for suite tests.
    #
    # @see Driver::Base#setup
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def setup
      transition_to(:setup)
    end

    # Verifies this set up instance by executing suite tests.
    #
    # @see Driver::Base#verify
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def verify
      transition_to(:verify)
    end

    # Destroys this instance.
    #
    # @see Driver::Base#destroy
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def destroy
      transition_to(:destroy)
    end

    # Tests this instance by creating, converging and verifying. If this
    # instance is running, it will be pre-emptively destroyed to ensure a
    # clean slate. The instance will be left post-verify in a running state.
    #
    # @param destroy_mode [Symbol] strategy used to cleanup after instance
    #   has finished verifying (default: `:passing`)
    # @return [self] this instance, used to chain actions
    #
    # @todo rescue Driver::ActionFailed and return some kind of null object
    #   to gracfully stop action chaining
    def test(destroy_mode = :passing)
      elapsed = Benchmark.measure do
        banner "Cleaning up any prior instances of #{self}"
        destroy
        banner "Testing #{self}"
        verify
        destroy if destroy_mode == :passing
      end
      info "Testing of #{self} complete (#{elapsed.real} seconds)."
      self
    ensure
      destroy if destroy_mode == :always
    end

    private

    def validate_options(opts)
      %w(suite platform driver jr logger).each do |k|
        raise ArgumentError, "Attribute '#{k}' is required." if opts[k].nil?
      end
    end

    def transition_to(desired)
      result = nil
      FSM.actions(last_action, desired).each do |transition|
        result = send("#{transition}_action")
      end
      result
    end

    def create_action
      banner "Creating #{self}"
      elapsed = action(:create) { |state| driver.create(state) }
      info "Creation of #{self} complete (#{elapsed.real} seconds)."
      self
    end

    def converge_action
      banner "Converging #{self}"
      elapsed = action(:converge) { |state| driver.converge(state) }
      info "Convergence of #{self} complete (#{elapsed.real} seconds)."
      self
    end

    def setup_action
      banner "Setting up #{self}"
      elapsed = action(:setup) { |state| driver.setup(state) }
      info "Setup of #{self} complete (#{elapsed.real} seconds)."
      self
    end

    def verify_action
      banner "Verifying #{self}"
      elapsed = action(:verify) { |state| driver.verify(state) }
      info "Verification of #{self} complete (#{elapsed.real} seconds)."
      self
    end

    def destroy_action
      banner "Destroying #{self}"
      elapsed = action(:destroy) { |state| driver.destroy(state) }
      destroy_state
      info "Destruction of #{self} complete (#{elapsed.real} seconds)."
      self
    end

    def action(what)
      state = load_state
      elapsed = Benchmark.measure do
        yield state if block_given?
      end
      state['last_action'] = what.to_s
      elapsed
    ensure
      dump_state(state)
    end

    def load_state
      File.exists?(statefile) ?  YAML.load_file(statefile) : Hash.new
    end

    def dump_state(state)
      dir = File.dirname(statefile)

      FileUtils.mkdir_p(dir) if !File.directory?(dir)
      File.open(statefile, "wb") { |f| f.write(YAML.dump(state)) }
    end

    def destroy_state
      FileUtils.rm(statefile) if File.exists?(statefile)
    end

    def statefile
      File.expand_path(File.join(
        driver['jamie_root'], ".jamie", "#{name}.yml"
      ))
    end

    def last_action
      load_state['last_action']
    end

    # The simplest finite state machine pseudo-implementation needed to manage
    # an Instance.
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class FSM

      # Returns an Array of all transitions to bring an Instance from its last
      # reported transistioned state into the desired transitioned state.
      #
      # @param last [String,Symbol,nil] the last known transitioned state of
      #   the Instance, defaulting to `nil` (for unknown or no history)
      # @param desired [String,Symbol] the desired transitioned state for the
      #   Instance
      # @return [Array<Symbol>] an Array of transition actions to perform
      def self.actions(last = nil, desired)
        last_index = index(last)
        desired_index = index(desired)

        if last_index == desired_index || last_index > desired_index
          Array(TRANSITIONS[desired_index])
        else
          TRANSITIONS.slice(last_index + 1, desired_index - last_index)
        end
      end

      private

      TRANSITIONS = [ :destroy, :create, :converge, :setup, :verify ]

      def self.index(transition)
        if transition.nil?
          0
        else
          TRANSITIONS.find_index { |t| t == transition.to_sym }
        end
      end
    end
  end

  # Command string generator to interface with Jamie Runner (jr). The
  # commands that are generated are safe to pass to an SSH command or as an
  # unix command argument (escaped in single quotes).
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
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
        echo "Uploading #{remote_path} (mode=#{perms})"
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

    def self.to_logger_level(symbol)
      return nil unless [:debug, :info, :warn, :error, :fatal].include?(symbol)

      Logger.const_get(symbol.to_s.upcase)
    end

    def self.from_logger_level(const)
      case const
      when Logger::DEBUG then :debug
      when Logger::INFO then :info
      when Logger::WARN then :warn
      when Logger::ERROR then :error
      else :fatal
      end
    end
  end

  # Mixin that wraps a command shell out invocation, providing a #run_command
  # method.
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
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
      subject = "[#{log_subject} command]"

      info("#{subject} BEGIN (#{display_cmd(cmd)})")
      sh = Mixlib::ShellOut.new(cmd, :live_stream => logger, :timeout => 60000)
      sh.run_command
      info("#{subject} END (#{sh.execution_time} seconds)")
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
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class Base

      include ShellOut
      include Logging

      attr_writer :instance

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
      # @param state [Hash] mutable instance and driver state
      # @raise [ActionFailed] if the action could not be completed
      def create(state) ; end

      # Converges a running instance.
      #
      # @param state [Hash] mutable instance and driver state
      # @raise [ActionFailed] if the action could not be completed
      def converge(state) ; end

      # Sets up an instance.
      #
      # @param state [Hash] mutable instance and driver state
      # @raise [ActionFailed] if the action could not be completed
      def setup(state) ; end

      # Verifies a converged instance.
      #
      # @param state [Hash] mutable instance and driver state
      # @raise [ActionFailed] if the action could not be completed
      def verify(state) ; end

      # Destroys an instance.
      #
      # @param state [Hash] mutable instance and driver state
      # @raise [ActionFailed] if the action could not be completed
      def destroy(state) ; end

      protected

      attr_reader :config, :instance

      def logger
        instance.logger
      end

      def puts(msg)
        info(msg)
      end

      def print(msg)
        info(msg)
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
    # * #create(state)
    # * #destroy(state)
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class SSHBase < Base

      def create(state)
        raise NotImplementedError, "#create must be implemented by subclass."
      end

      def converge(state)
        ssh_args = build_ssh_args(state)

        install_omnibus(ssh_args) if config['require_chef_omnibus']
        prepare_chef_home(ssh_args)
        upload_chef_data(ssh_args)
        run_chef_solo(ssh_args)
      end

      def setup(state)
        ssh_args = build_ssh_args(state)

        if instance.jr.setup_cmd
          ssh(ssh_args, instance.jr.setup_cmd)
        end
      end

      def verify(state)
        ssh_args = build_ssh_args(state)

        if instance.jr.run_cmd
          ssh(ssh_args, instance.jr.sync_cmd)
          ssh(ssh_args, instance.jr.run_cmd)
        end
      end

      def destroy(state)
        raise NotImplementedError, "#destroy must be implemented by subclass."
      end

      protected

      def build_ssh_args(state)
        opts = Hash.new
        opts[:user_known_hosts_file] = "/dev/null"
        opts[:paranoid] = false
        opts[:password] = config['password'] if config['password']
        opts[:keys] = Array(config['ssh_key']) if config['ssh_key']

        [ state['hostname'], config['username'], opts ]
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
        ssh(ssh_args, "sudo rm -rf #{chef_home} && mkdir -p #{chef_home}/cache")
      end

      def upload_chef_data(ssh_args)
        Jamie::ChefDataUploader.new(
          instance, ssh_args, config['jamie_root'], chef_home
        ).upload
      end

      def run_chef_solo(ssh_args)
        ssh(ssh_args, <<-RUN_SOLO)
          sudo chef-solo -c #{chef_home}/solo.rb -j #{chef_home}/dna.json \
            --log_level #{Util.from_logger_level(logger.level)}
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
              logger << data
            end

            channel.on_extended_data do |ch, type, data|
              logger << data
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
        logger << "." until test_ssh(hostname)
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
  #
  # @author Fletcher Nichol <fnichol@nichol.ca>
  class ChefDataUploader

    include ShellOut
    include Logging

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

    def logger
      instance.logger
    end

    def upload_json(scp)
      json_file = StringIO.new(instance.dna.to_json)
      scp.upload!(json_file, "#{chef_home}/dna.json")
    end

    def upload_solo_rb(scp)
      solo_rb_file = StringIO.new(solo_rb_contents)
      scp.upload!(solo_rb_file, "#{chef_home}/solo.rb")
    end

    def upload_cookbooks(scp)
      ckbks_dir = local_cookbooks
      scp.upload!(ckbks_dir, "#{chef_home}/cookbooks",
        :recursive => true
      ) do |ch, name, sent, total|
        if sent == total
          info("Uploaded #{name.sub(%r{^#{ckbks_dir}/}, '')} (#{total} bytes)")
        end
      end
    ensure
      FileUtils.rmtree(ckbks_dir)
    end

    def upload_data_bags(scp)
      dbags_dir = instance.suite.data_bags_path
      scp.upload!(dbags_dir, "#{chef_home}/data_bags",
        :recursive => true
      ) do |ch, name, sent, total|
        if sent == total
          info("Uploaded #{name.sub(%r{^#{dbags_dir}/}, '')} (#{total} bytes)")
        end
      end
    end

    def upload_roles(scp)
      roles_dir = instance.suite.roles_path
      scp.upload!(roles_dir, "#{chef_home}/roles",
        :recursive => true
      ) do |ch, name, sent, total|
        if sent == total
          info("Uploaded #{name.sub(%r{^#{roles_dir}/}, '')} (#{total} bytes)")
        end
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
      solo.join("\n")
    end

    def local_cookbooks
      tmpdir = Dir.mktmpdir("#{instance.name}-cookbooks")
      prepare_tmpdir(tmpdir)
      tmpdir
    end

    def prepare_tmpdir(tmpdir)
      if File.exists?(File.join(jamie_root, "Berksfile"))
        run_berks(tmpdir)
      elsif File.exists?(File.join(jamie_root, "Cheffile"))
        run_librarian(tmpdir)
      elsif File.directory?(File.join(jamie_root, "cookbooks"))
        cp_cookbooks(tmpdir)
      else
        FileUtils.rmtree(tmpdir)
        abort "Berksfile, Cheffile or cookbooks/ must exist in #{jamie_root}"
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

    def cp_cookbooks(tmpdir)
      metadata_rb = File.join(jamie_root, "metadata.rb")
      cb_name = MetadataChopper.extract(metadata_rb).first
      abort ">>>>>> name attribute must be set in metadata.rb." if cb_name.nil?
      cb_path = File.join(tmpdir, cb_name)
      glob = Dir.glob("#{jamie_root}/{metadata.rb,README.*," +
        "attributes,files,libraries,providers,recipes,resources,templates}")

      FileUtils.cp_r(File.join(jamie_root, "cookbooks", "."), tmpdir)
      FileUtils.mkdir_p(cb_path)
      FileUtils.cp_r(glob, cb_path)
    end
  end

  # A rather insane and questionable class to quickly consume a metadata.rb
  # file and return the cookbook name and version attributes.
  #
  # @see https://twitter.com/fnichol/status/281650077901144064
  # @see https://gist.github.com/4343327
  class MetadataChopper < Hash

    # Return an Array containing the cookbook name and version attributes,
    # or nil values if they could not be parsed.
    #
    # @param metadata_file [String] path to a metadata.rb file
    # @return [Array<String>] array containing the cookbook name and version
    #   attributes or nil values if they could not be determined
    def self.extract(metadata_file)
      mc = new(File.expand_path(metadata_file))
      [ mc[:name], mc[:version] ]
    end

    # Creates a new instances and loads in the contents of the metdata.rb
    # file. If you value your life, you may want to avoid reading the
    # implementation.
    #
    # @param metadata_file [String] path to a metadata.rb file
    def initialize(metadata_file)
      eval(IO.read(metadata_file), nil, metadata_file)
    end

    def method_missing(meth, *args, &block)
      self[meth] = args.first
    end
  end
end

Jamie.logger = Jamie.default_logger
