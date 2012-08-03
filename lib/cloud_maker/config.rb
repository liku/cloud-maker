module CloudMaker
  class Config
    # Public: Gets/Sets the CloudMaker specific properties. The options hash
    # is formatted as:
    #    {
    #      'key1' => {
    #         'environment': boolean,
    #         'required': boolean,
    #         'value': value
    #      },
    #      'key2' => { ... },
    #      ...
    #    }
    attr_accessor :options
    # Public: Gets/Sets the Hash of Cloud Init properties. See
    # https://help.ubuntu.com/community/CloudInit for valid options
    attr_accessor :cloud_config
    # Public: Gets/Sets an Array of URLs to be included, this corresponds to the
    # list of URLs in a Cloud Init includes file.
    attr_accessor :includes
    # Public: Gets/Sets extra information about the config to be stored for
    # archival purposes.
    attr_accessor :extra_options
    # Internal: Gets/Sets an array of paths to other cloud maker configs to import.
    attr_accessor :imports

    # Internal: A mime header for the Cloud Init config section of the user data
    CLOUD_CONFIG_HEADER = %Q|Content-Type: text/cloud-config; charset="us-ascii"\nMIME-Version: 1.0\nContent-Transfer-Encoding: 7bit\nContent-Disposition: attachment; filename="cloud-config.yaml"\n\n|
    # Internal: A mime header for the includes section of the user data
    INCLUDES_HEADER = %Q|Content-Type: text/x-include-url; charset="us-ascii"\nMIME-Version: 1.0\nContent-Transfer-Encoding: 7bit\nContent-Disposition: attachment; filename="includes.txt"\n\n|
    # Internal: A mime header for the Cloud Boothook section of the user data
    BOOTHOOK_HEADER = %Q|Content-Type: text/cloud-boothook; charset="us-ascii"\nMIME-Version: 1.0\nContent-Transfer-Encoding: 7bit\nContent-Disposition: attachment; filename="boothook.sh"\n\n|
    # Internal: A multipart mime header for describing the entire user data
    # content. It includes a placeholder for the boundary text '___boundary___'
    # that needs to be replaced in the actual mime document.
    MULTIPART_HEADER = %Q|Content-Type: multipart/mixed; boundary="___boundary___"\nMIME-Version: 1.0\n\n|

    # Internal: If you don't specify a property associated with a key in the
    # cloud_maker config file we will use these properties to fill in the blanks
    DEFAULT_KEY_PROPERTIES = {
      "environment" => true,
      "required" => false,
      "value" => nil,
      "default" => nil,
      "description" => nil
    }

    # Public: Initializes a new CloudMaker object.
    #
    # cloud_config - A Hash describing all properties of the CloudMaker config.
    #   'cloud_maker' - The configuration properties for CloudMaker. These can
    #                   be specified either as
    #                      key: value
    #                   or as
    #                      key: {
    #                        environment: boolean,
    #                        required: boolean,
    #                        value: value
    #                      }
    #                   If specified as key: value DEFAULT_KEY_PROPERTIES will
    #                   be used. If the detailed version is used all properties
    #                   are optional and DEFAULT_KEY_PROPERTIES will be used to
    #                   fill in the blanks.
    #
    #   'include'     - An array of URLs or a String containing 1 URL per line
    #                   with optional # prefixed lines as comments.
    #   ...           - All valid properties of a Cloud Init config
    #                   are also valid here. See:
    #                   https://help.ubuntu.com/community/CloudInit
    # extra_options - Extra information about the instantiation. These will not
    #                 be used to launch the instance but will be stored in the
    #                 archive describing the instance.
    #
    # Returns a CloudMaker object
    def initialize(cloud_config, extra_options)
      self.extra_options = extra_options
      cloud_config = cloud_config.dup
      self.options = extract_cloudmaker_config!(cloud_config)
      self.includes = extract_includes!(cloud_config)
      self.imports = extract_imports!(cloud_config)
      self.cloud_config = cloud_config

      self.imports.reverse.each do |import_path|
        self.import(self.class.from_yaml(import_path))
      end
    end

    # Public: Check if the CloudMaker config is in a valid state.
    #
    # Returns true if and only if all required properties have non-nil values
    #   and false otherwise.
    def valid?
      self.options.all? {|key, option| !(option["required"] && option["value"].nil?)}
    end

    # Public: Finds a list of keys in the CloudMaker config that are required to
    # have a value but do not yet have one.
    #
    # Returns an Array of required keys that are missing values.
    def missing_values
      self.options.select {|key, option| (option["required"] || option["default"]) && option["value"].nil?}.map(&:first).map(&:dup)
    end

    # Returns a Hash of all of the CloudMaker specific properties in the configuration.
    def to_hash
      {
        'cloud-maker' => self.options.map {|key, properties| [key, properties["value"]]},
        'cloud-init' => self.cloud_config,
        'include' => self.includes,
        'import' => self.imports,
        'extra-options' => self.extra_options
      }
    end

    # Public: Generates a multipart userdata string suitable for use with Cloud Init on EC2
    #
    # Returns a String containing the mime encoded userdata
    def to_user_data
      # build a multipart document
      parts = []

      parts.push(BOOTHOOK_HEADER + boothook_data)
      parts.push(CLOUD_CONFIG_HEADER + cloud_config_data)
      parts.push(INCLUDES_HEADER + includes_data)

      #not that it's likely but lets make sure that we don't choose a boundary that exists in the document.
      boundary = ''
      while parts.any? {|part| part.index(boundary)}
        boundary = "===============#{rand(8999999999999999999) + 1000000000000000000}=="
      end

      header = MULTIPART_HEADER.sub(/___boundary___/, boundary)

      return [header, *parts].join("\n--#{boundary}\n") + "\n--#{boundary}--"
    end

    # Public: Generates a cloud-init configuration
    #
    # Returns a String containing the cloud init configuration in YAML format
    def cloud_config_data
      return "#cloud-config\n#{self.cloud_config.to_yaml}"
    end

    # Public: Generates a shell script to set environment variables for all
    # CloudMaker config options, will get executed at machine boot.
    #
    # Returns a String containing the shell script
    def boothook_data
      env_run_cmds = []

      self.options.each_pair do |key, properties|
        if properties["environment"] && !properties["value"].nil?
          env_run_cmds.push(set_environment_variable_cmd(key, properties["value"]))
        end
      end

      return "#cloud-boothook\n#!/bin/sh\n#{env_run_cmds.join("\n")}\n"
    end


    # Public: Generates a cloud-init includes list
    #
    # Returns a String containing the cloud init includes list
    def includes_data
      ["#include", *self.includes.map(&:to_s)].join("\n")
    end


    # Public: Access values in the cloudmaker options object
    #
    # key - The key of the property you're accessing
    #
    # Returns the value property for options[key]
    def [](key)
      self.options[key] ? self.options[key]["value"] : nil
    end

    # Public: Sets the value property for key in the cloudmaker options hash
    #
    # key - The key of the property you're accessing
    # val - The value you wish to assign to the key
    #
    # Returns val
    def []=(key, val)
      if (self.options[key])
        self.options[key]["value"] = val
      else
        self.options[key] = DEFAULT_KEY_PROPERTIES.merge('value' => val)
      end
      val
    end

    # Returns a String representation of the CloudMaker config
    def inspect
      "CloudMakerConfig#{self.options.inspect}"
    end

    class << self

      # Public: Takes the path of a YAML file and loads a new Config object
      # from it.
      #
      # instance_config_yaml - The path of the YAML file
      #
      # Returns a new Config
      # Raises: Exception if the file doesn't exist.
      # Raises: SyntaxError if the YAML file is invalid.
      def from_yaml(instance_config_yaml)
        begin
          full_path = File.expand_path(instance_config_yaml)
          cloud_yaml = File.open(full_path, "r") #Right_AWS will base64 encode this for us
        rescue
          raise "ERROR: The path to the CloudMaker config is incorrect"
        end

        CloudMaker::Config.new(YAML::load(cloud_yaml), 'config_path' => full_path)
      end
    end


    # Internal: Takes a CloudMaker config and parses out the CloudMaker
    # specific portions of it. For each key/value it fills in any property
    # blanks from the DEFAULT_KEY_PROPERTIES. It also deletes the cloud_maker
    # property from config.
    #
    # config - A hash that should contain a 'cloud_maker' key storing CloudMaker
    #   configuration properties.
    #
    # Returns a Hash in the format of
    #   {'key1' => {
    #      'environment' => ...,
    #      'value' => ...,
    #      'required' ...
    #   }, 'key2' => ... , ...}
    def extract_cloudmaker_config!(config)
      cloud_maker_config = config.delete('cloud-maker') || {}
      cloud_maker_config.keys.each do |key|
        #if key is set to anything but a hash then we treat it as the value property
        if !advanced_config?(cloud_maker_config[key])
          cloud_maker_config[key] = {
            "value" => cloud_maker_config[key]
          }
        end

        cloud_maker_config[key] = DEFAULT_KEY_PROPERTIES.merge(cloud_maker_config[key])
      end
      cloud_maker_config
    end

    # Internal: Determines if value should be treated as a value or a property
    # configuration hash. A property configuration hash would specify at least
    # one of environment, value, or required.
    #
    # value - The value to evaluate
    #
    # Returns true if value is a property configuration, and false if it's just
    #   a value
    def advanced_config?(value)
      value.kind_of?(Hash) && !(DEFAULT_KEY_PROPERTIES.keys & value.keys).empty?
    end

    # Internal: Takes a CloudMaker config and parses out the includes list. If
    # the list is an array it treats each entry as a URL. If it is a string it
    # treats the string as the contents of a Cloud Init include file.
    #
    # config - A hash that should contain an 'include' key storing the include
    # information.
    #
    # Returns an Array of URLs
    def extract_includes!(config)
      includes = config.delete('include')

      #if we didn't specify it just use a blank array
      if includes.nil?
        includes = []
      #if we passed something other than an array turn it into a string and split it up into urls
      elsif !includes.kind_of?(Array)
        includes = includes.to_s.split("\n")
        includes.reject! {|line| line.strip[0] == "#" || line.strip.empty?}
      end

      includes
    end

    # Internal: Takes a CloudMaker config and parses out the imports list.
    #
    # config - A hash that should contain an 'import' key storing an array
    # of paths to import.
    #
    # Returns an Array of URLs
    def extract_imports!(config)
      config.delete('import') || []
    end

    # Internal: Generates the shell command necessary to set an environment
    # variable. It escapes the value but assumes there are no special characters
    # in the key. If value is an array or a hash it generates an environment
    # variable for each value in the array/hash with the key set to key_index.
    #
    # key   - The key of the environment variable
    # value - The value to set the key to
    #
    # Returns a string that can be executed to globally set the environment variable.
    def set_environment_variable_cmd(key, value)
      if (value.kind_of?(Hash))
        value.keys.map { |hash_key|
          set_environment_variable_cmd("#{key}_#{hash_key}", value[hash_key])
        }.join(';')
      elsif (value.kind_of?(Array))
        strings = []
        value.each_with_index { |arr_val, i|
          strings.push(set_environment_variable_cmd("#{key}_#{i}", arr_val))
        }
        strings.join(';')
      else
        escaped_value = value.to_s.gsub(/"/, '\\\\\\\\\"')
        "echo \"#{key}=\\\"#{escaped_value}\\\"\" >> /etc/environment"
      end
    end

    # Internal: Deep merges another CloudMaker::Config into this one giving
    # precedence to all values set in this one. Arrays will be merged as
    # imported_array.concat(current_array).uniq.
    #
    # It should be noted that this is not reference safe, ie. objects within
    # cloud_maker_config will end up referenced from this config object as well.
    #
    # cloud_maker_config - The CloudMaker::Config to be imported
    #
    # Returns nothing.
    def import(cloud_maker_config)
      self.options = cloud_maker_config.options.deep_merge!(self.options)
      self.includes = cloud_maker_config.includes.concat(self.includes).uniq
      self.cloud_config = cloud_maker_config.cloud_config.deep_merge!(self.cloud_config)
      self.extra_options = cloud_maker_config.extra_options.deep_merge!(self.extra_options)
    end
  end
end
