require 'yaml'
require 'etc'
#require 'ohai'
require 'erb'
require 'deep_merge'
require 'securerandom'
# Used for data bag stuff
require 'json'

module Kitchenplan

  class Config

    attr_reader :platform
    attr_reader :default_config
    attr_reader :people_config
    attr_reader :system_config
    attr_reader :group_configs

    def initialize
      self.detect_platform
      self.parse_default_config
      self.parse_people_config
      self.parse_system_config
      self.parse_group_configs
    end

    def detect_platform
      #ohai = Ohai::System.new
      #ohai.require_plugin('os')
      #ohai.require_plugin('platform')
      #@platform = ohai[:platform_family]
      @platform = 'mac_os_x' # We only support osx at the moment, and it ves a large dependency
    end

    def hardware_model
      `sysctl -n hw.model | tr -d '\n'`
    end

    def parse_default_config
      default_config_path = 'config/default.yml'
      @default_config = (YAML.load(ERB.new(File.read(default_config_path)).result) if File.exist?(default_config_path)) || {}
    end

    def parse_people_config
      people_config_path = "config/people/#{Etc.getlogin}.yml"
      @people_config = (YAML.load(ERB.new(File.read(people_config_path)).result) if File.exist?(people_config_path)) || {}
    end

    def parse_system_config
      system_config_path = "config/system/#{hardware_model}.yml"
      @system_config = (YAML.load(ERB.new(File.read(system_config_path)).result) if File.exist?(system_config_path)) || {}
    end

    def parse_group_configs(group = (( @default_config['groups'] || [] ) | ( @people_config['groups'] || [] )))
      @group_configs = @group_configs || {}
      defined_groups = group || []
      defined_groups.each do |group|
        self.parse_group_config(group)
      end
    end

    def parse_group_config(group)
      unless @group_configs[group]
        group_config_path = "config/groups/#{group}.yml"
        @group_configs[group] = (YAML.load(ERB.new(File.read(group_config_path)).result) if File.exist?(group_config_path)) || {}
        defined_groups = @group_configs[group]['groups']
        if defined_groups
          self.parse_group_configs(defined_groups)
        end
      end
    end

    def config
      config = {}
      config['recipes'] = []
      config['recipes'] |= hash_path(@default_config, 'recipes', 'global') || []
      config['recipes'] |= hash_path(@default_config, 'recipes', @platform) || []
      @group_configs.each do |group_name, group_config|
        config['recipes'] |= hash_path(group_config, 'recipes', 'global') || []
        config['recipes'] |= hash_path(group_config, 'recipes', @platform) || []
      end
      people_recipes = @people_config['recipes'] || {}
      config['recipes'] |= people_recipes['global'] || []
      config['recipes'] |= people_recipes[@platform] || []

      system_recipes = @system_config['recipes'] || {}
      config['recipes'] |= system_recipes['global'] || []
      config['recipes'] |= system_recipes[@platform] || []

      set_overridden_config(config, 'attributes')

      # TODO how should these attributes interact with those defined in normal attribute section? order of overriding?
      set_overridden_config(config, 'input_attributes')
      # Special thing
      set_overridden_config(config, 'input_secret_attributes')

      # now set the collected user attributes into the attributes hash
      #TODO delte this, or make it inherit from the attributes in some logical precedence
      #deep_merge_configs(config['input_attributes'], config['attributes'])
      #deep_merge_configs(config['input_secret_attributes'], config['attributes'])

      config
    end

    private

    def set_overridden_config(config, config_key)
      # First take the values from default.yml
      config[config_key] = {} unless config[config_key]

      Config.deep_merge_configs(@default_config[config_key], config[config_key])

      # then override and extend them with the group values
      @group_configs.each do |group_name, group_config|
        config[config_key].deep_merge!(group_config[config_key]) { |key, old, new| Array.wrap(old) + Array.wrap(new) } unless group_config[config_key].nil?
      end

      # then override and extend them with the people values
      Config.deep_merge_configs(@people_config[config_key], config[config_key])
      # lastly override from the system files
      Config.deep_merge_configs(@system_config[config_key], config[config_key])
    end

    def self.create_key_with_data_bag(src)
      unless src.nil?
        # Create a user in knife. For some reason it didn't want to accept one that i made externally
        puts("Running Command: sudo knife user create devadmin -f /Users/#{ENV['USER']}/.chef/#{ENV['USER']}.pem -a -p password -z")
        system("sudo knife user delete #{ENV['USER']}")
        system("sudo knife user create #{ENV['USER']} -f /Users/#{ENV['USER']}/.chef/#{ENV['USER']}.pem -a -p password -z")     

        # Actaully create the vault that is used :D
        puts("Running Command: knife vault create secret_vault secret_attributes '#{src.to_json}' -z")
        system("knife vault delete secret_vault secret_attributes -z")
        system("knife vault create secret_vault secret_attributes '#{src.to_json}' -z -A #{ENV['USER']}")
        puts("Test")

        src.each do |key, array|
          array.each do |key2, array2|
            src[key][key2] = ""
          end
        end

        # Return just the keys since that is all we care about.
        puts src
      end

      return src
    end

    def self.deep_merge_configs(src, dest)
      src = src || {}
      dest.deep_merge!(src) { |key, old, new| Array.wrap(old) + Array.wrap(new) }
    end

    # Creates a key and stores it in the attributes json file
    def self.deep_merge_secret_configs(src, dest)
      src = create_key_with_data_bag(src) || {}
      dest.deep_merge!(src) { |key, old, new| Array.wrap(old) + Array.wrap(new) }
      puts src
    end 

    # Fetches the value at a path in a nested hash or nil if the path is not present.
    def hash_path(hash, *path)
      path.inject(hash) { |hash, key| hash[key] if hash }
    end

  end

end
