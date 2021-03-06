require 'fileutils'

class Project
  @@plugin_names = []

  def self.plugin(plugin_name)
    @@plugin_names << plugin_name unless RAILS_ENV == 'test' or @@plugin_names.include? plugin_name
  end

  def self.read(dir, load_config = true)
    @project_in_the_works = Project.new(File.basename(dir))
    begin
      @project_in_the_works.load_config if load_config
      return @project_in_the_works
    ensure
      @project_in_the_works = nil
    end
  end
  
  def self.configure
    raise 'No project is currently being created' unless @project_in_the_works
    yield @project_in_the_works
  end

  attr_reader :name, :plugins, :build_command, :rake_task, :config_tracker, :path, :settings, :config_file_content, :error_message
  attr_accessor :source_control, :scheduler

  def initialize(name, scm = nil)
    @name = name
    @path = File.join(CRUISE_DATA_ROOT, 'projects', @name)
    @scheduler = PollingScheduler.new(self)
    @plugins = []
    @plugins_by_name = {}
    @config_tracker = ProjectConfigTracker.new(self.path)
    @settings = ''
    @config_file_content = ''
    @error_message = ''
    @triggers = [ChangeInSourceControlTrigger.new(self)]
    self.source_control = scm if scm
    instantiate_plugins
  end
  
  def source_control=(scm_adapter)
    scm_adapter.path = local_checkout
    @source_control = scm_adapter
  end

  def source_control
    @source_control || self.source_control = SourceControl.detect(local_checkout)
  end

  def load_and_remember(file)
    return unless File.file?(file)
    @settings << File.read(file) << "\n"
    @config_file_content = @settings
    load file
  end

  def load_config
    begin
      retried_after_update = false
      begin
        load_and_remember config_tracker.central_config_file
      rescue Exception 
        if retried_after_update
          raise
        else
          source_control.update
          retried_after_update = true
          retry
        end
      end
      load_and_remember config_tracker.local_config_file
    rescue Exception => e
      @error_message = "Could not load project configuration: #{e.message} in #{e.backtrace.first}"
      CruiseControl::Log.event(@error_message, :fatal) rescue nil
      @settings = ""
    end
    self
  end

  def path=(value)
    value = File.expand_path(value)
    @config_tracker = ProjectConfigTracker.new(value)
    @path = value
    @source_control.path = local_checkout if @source_control
    @path
  end

  def instantiate_plugins
    @@plugin_names.each do |plugin_name|
      plugin_instance = plugin_name.to_s.camelize.constantize.new(self)
      self.add_plugin(plugin_instance)
    end
  end

  def add_plugin(plugin, plugin_name = plugin.class)
    @plugins << plugin
    plugin_name = plugin_name.to_s.underscore.to_sym
    if self.respond_to?(plugin_name)
      raise "Cannot register an plugin with name #{plugin_name.inspect} " +
            "because another plugin, or a method with the same name already exists"
    end
    @plugins_by_name[plugin_name] = plugin
    plugin
  end

  # access plugins by their names
  def method_missing(method_name, *args, &block)
    @plugins_by_name.key?(method_name) ? @plugins_by_name[method_name] : super
  end
  
  def ==(another)
    another.is_a?(Project) and another.name == self.name
  end
  
  def config_valid?
    @settings == @config_file_content
  end

  def build_command=(value)
    raise 'Cannot set build_command when rake_task is already defined' if value and @rake_task
    @build_command = value
  end

  def rake_task=(value)
    raise 'Cannot set rake_task when build_command is already defined' if value and @build_command
    @rake_task = value
  end

  def local_checkout
    File.join(@path, 'work')
  end

  def builds
    raise "Project #{name.inspect} has no path" unless path

    the_builds = Dir["#{path}/build-*"].collect do |build_dir|
      build_directory = File.basename(build_dir)
      build_label = build_directory.split("-")[1]
      Build.new(self, build_label)
    end
    order_by_label(the_builds)
  end

  def builder_state_and_activity
    BuilderStatus.new(self).status
  end 
  
  def builder_error_message
    BuilderStatus.new(self).error_message
  end
  
  def last_build
    builds.last
  end
  
  def create_build(label)
    build = Build.new(self, label)
    build.artifacts_directory # create the build directory
    build
  end
  
  def previous_build(current_build)  
    all_builds = builds
    index = get_build_index(all_builds, current_build.label)
    
    if index > 0
      return all_builds[index-1]
    else  
      return nil
    end
  end
  
  def next_build(current_build)
    all_builds = builds
    index = get_build_index(all_builds, current_build.label)

    if index == (all_builds.size - 1)
      return nil
    else
      return all_builds[index + 1]
    end
  end
  
  def last_complete_build
    builds.reverse.find { |build| !build.incomplete? }
  end

  def find_build(label)
    # this could be optimized a lot
    builds.find { |build| build.label == label }
  end
    
  def last_complete_build_status
    return "failed" if BuilderStatus.new(self).fatal?
    last_complete_build ? last_complete_build.status : 'never_built'
  end

  # TODO this and last_builds methods are not Project methods, really - they can be inlined somewhere in the controller layer
  def last_five_builds
    last_builds(5)
  end
  
  def last_builds(n)
    result = builds.reverse[0..(n-1)]
  end

  def build_if_necessary
    begin
      if build_necessary?(reasons = [])
        remove_build_requested_flag_file if build_requested?
        return build(source_control.latest_revision, reasons)
      else
        return nil
      end
    rescue => e
      unless e.message.include? "No commit found in the repository."
        notify(:build_loop_failed, e) rescue nil
        @build_loop_failed = true
        raise
      end 
    ensure
      notify(:sleeping) unless @build_loop_failed rescue nil
    end
  end

  #todo - test
  def build_necessary?(reasons)
    if builds.empty?
      reasons << "This is the first build"
      true
    else 
      @triggers.any? {|t| t.build_necessary?(reasons) }
    end
  end
  
  def build_requested?
    File.file?(build_requested_flag_file)
  end
  
  def request_build
    if builder_state_and_activity == 'builder_down'
      BuilderStarter.begin_builder(name)
      10.times do
        sleep 1.second
        break if builder_state_and_activity != 'builder_down' 
      end
    end
    unless build_requested?
      notify :build_requested
      create_build_requested_flag_file
    end
  end
  
  def config_modified?
    if config_tracker.config_modified?
      notify :configuration_modified
      true
    else
      false
    end
  end
  
  def build_if_requested
    if build_requested?
      remove_build_requested_flag_file
      build(source_control.latest_revision, ['Build was manually requested'])
    end
  end
  
  def update_project_to_revision(build, revision)
    if do_clean_checkout?
      File.open(build.artifact('source_control.log'), 'w') do |f| 
        start = Time.now
        f << "checking out build #{build.label}, this could take a while...\n"
        source_control.clean_checkout(revision, f)
        f << "\ntook #{Time.now - start} seconds"
      end
    else
      source_control.update(revision)
    end
  end
  
  def build(revision = source_control.latest_revision, reasons = [])
    if Configuration.serialize_builds
      BuildSerializer.serialize(self) { build_without_serialization(revision, reasons) }
    else
      build_without_serialization(revision, reasons)
    end
  end
        
  def build_without_serialization(revision, reasons)
    return if revision.nil? # this will only happen in the case that there are no revisions yet

    notify(:build_initiated)
    previous_build = last_build    
    
    build = Build.new(self, create_build_label(revision.number))
    
    begin
      log_changeset(build.artifacts_directory, reasons)
      update_project_to_revision(build, revision)

      if config_tracker.config_modified?
        build.abort
        notify(:configuration_modified)
        throw :reload_project
      end
    
      notify(:build_started, build)
      build.run
      notify(:build_finished, build)
    rescue => e
      build.fail!(e.message)
      raise
    end

    if previous_build
      if build.failed? and previous_build.successful?
        notify(:build_broken, build, previous_build)
      elsif build.successful? and previous_build.failed?
        notify(:build_fixed, build, previous_build)
      end
    end

    build
  end

  def notify(event, *event_parameters)
    errors = []
    results = @plugins.collect do |plugin| 
      begin
        plugin.send(event, *event_parameters) if plugin.respond_to?(event)
      rescue => plugin_error
        CruiseControl::Log.error(plugin_error)
        if (event_parameters.first and event_parameters.first.respond_to? :artifacts_directory)
          plugin_errors_log = File.join(event_parameters.first.artifacts_directory, 'plugin_errors.log')
          begin
            File.open(plugin_errors_log, 'a') do |f|
              f << "#{plugin_error.message} at #{plugin_error.backtrace.first}"
            end
          rescue => e
            CruiseControl::Log.error(e)
          end
        end
        errors << "#{plugin.class}: #{plugin_error.message}"
      end
    end
    
    if errors.empty?
      return results.compact
    else
      if errors.size == 1
        error_message = "Error in plugin #{errors.first}"
      else
        error_message = "Errors in plugins:\n" + errors.map { |e| "  #{e}" }.join("\n")
      end
      raise error_message
    end
  end
  
  def log_changeset(artifacts_directory, reasons)
    File.open(File.join(artifacts_directory, 'changeset.log'), 'w') do |f|
      reasons.each { |reason| f << reason.to_s << "\n" }
    end
  end

  def respond_to?(method_name)
    @plugins_by_name.key?(method_name) or super
  end

  def build_requested_flag_file
    File.join(path, 'build_requested')
  end

  def to_param
    self.name
  end
  
  # possible values for this is :never, :always, :every => 1.hour, :every => 2.days, etc
  def do_clean_checkout(how_often = :always)
    unless how_often == :always || how_often == :never || (how_often[:every].is_a?(Integer))
      raise "expected :never, :always, :every => 1.hour, :every => 2.days, etc"
    end
    @clean_checkout_when = how_often
  end
  
  def do_clean_checkout?
    case @clean_checkout_when
    when :always: true
    when nil, :never: false
    else
      timestamp_filename = File.join(self.path, 'last_clean_checkout_timestamp')
      unless File.exist?(timestamp_filename)
        save_timestamp(timestamp_filename)
        return true
      end

      time_since_last_clean_checkout = Time.now - load_timestamp(timestamp_filename)
      if time_since_last_clean_checkout > @clean_checkout_when[:every]
        save_timestamp(timestamp_filename)
        true
      else
        false
      end
    end
  end

  def save_timestamp(file)
    File.open(file, 'w') { |f| f.write Time.now.gmtime.strftime("%Y-%m-%d %H:%M:%SZ") }
  end

  def load_timestamp(file)
    Time.parse(File.read(file))
  end

  def triggered_by(*new_triggers)
    @triggers += new_triggers

    @triggers.map! do |trigger|
      if trigger.is_a?(String) || trigger.is_a?(Symbol)
        SuccessfulBuildTrigger.new(self, trigger)
      else
        trigger
      end
    end
    @triggers
  end

  def triggered_by=(triggers)
    @triggers = [triggers].flatten
  end

  private
  
  # sorts a array of builds in order of revision number and rebuild number 
  def order_by_label(builds)
    if source_control.creates_ordered_build_labels?
      builds.sort_by do |build|
        number, rebuild = build.label.split('.')
        # when a label only has build number, rebuild = nil, nil.to_i = 0, and this code still works
        [number.to_i, rebuild.to_i]
      end
    else
      builds.sort_by(&:time)
    end
  end
    
  def create_build_label(revision_number)
    revision_number = revision_number.to_s
    build_labels = builds.map { |b| b.label }
    related_builds_pattern = Regexp.new("^#{Regexp.escape(revision_number)}(\\.\\d+)?$")
    related_builds = build_labels.select { |label| label =~ related_builds_pattern }

    case related_builds
    when [] then revision_number
    when [revision_number] then "#{revision_number}.1"
    else
      rebuild_numbers = related_builds.map { |label| label.split('.')[1] }.compact
      last_rebuild_number = rebuild_numbers.sort_by { |x| x.to_i }.last 
      "#{revision_number}.#{last_rebuild_number.next}"
    end
  end
  
  def create_build_requested_flag_file
    FileUtils.touch(build_requested_flag_file)
  end

  def remove_build_requested_flag_file
    FileUtils.rm_f(Dir[build_requested_flag_file])
  end
  
  def get_build_index(all_builds, build_label)
    result = 0;
    all_builds.each_with_index {|build, index| result = index if build.label == build_label}
    result 
  end
end

# TODO make me pretty, move me to another file, invoke me from environment.rb
# TODO check what happens if loading a plugin raises an error (e.g, SyntaxError in plugin/init.rb)

plugin_loader = Object.new

def plugin_loader.load_plugin(plugin_path)
  plugin_file = File.basename(plugin_path).sub(/\.rb$/, '')
  plugin_is_directory = (plugin_file == 'init')  
  plugin_name = plugin_is_directory ? File.basename(File.dirname(plugin_path)) : plugin_file

  CruiseControl::Log.debug("Loading plugin #{plugin_name}")
  if RAILS_ENV == 'development'
    load plugin_path
  else
    if plugin_is_directory then require "#{plugin_name}/init" else require plugin_name end
  end
end

def plugin_loader.load_all
  plugins = Dir[RAILS_ROOT + "/lib/builder_plugins/*"] + Dir[CRUISE_DATA_ROOT + "/builder_plugins/*"]

  plugins.each do |plugin|
    # ignore hidden files and directories (they should be considered hidden by Dir[], but just in case)
    next if File.basename(plugin)[0, 1] == '.'
    if File.file?(plugin)
      if plugin[-3..-1] == '.rb'
        load_plugin(File.basename(plugin))
      else
        # a file without .rb extension, ignore
      end
    elsif File.directory?(plugin)
      init_path = File.join(plugin, 'init.rb')
      if File.file?(init_path)
        load_plugin(init_path)
      else
        log.error("No init.rb found in plugin directory #{plugin}")
      end
    else
      # a path is neither file nor directory. whatever else it may be, let's ignore it.
      # TODO: find out what happens with symlinks on a Linux here? how about broken symlinks?
    end
  end

end

plugin_loader.load_all