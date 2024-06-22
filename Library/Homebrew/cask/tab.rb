# typed: true
# frozen_string_literal: true

module Cask
  class Tab
    extend Cachable

    FILENAME = "INSTALL_RECEIPT.json"

    attr_accessor :homebrew_version, :tabfile, :loaded_from_api, :installed_as_dependency, :installed_on_request,
                  :time, :dependencies, :arch, :source, :installed_on, :artifacts

    # Instantiates a {Tab} for a new installation of a cask.
    sig { params(cask: Cask).returns(Tab) }
    def self.create(cask)
      attributes = {
        "homebrew_version"        => HOMEBREW_VERSION,
        "tabfile"                 => cask.metadata_main_container_path/FILENAME,
        "loaded_from_api"         => cask.loaded_from_api?,
        "installed_as_dependency" => false,
        "installed_on_request"    => false,
        "time"                    => Time.now.to_i,
        "dependencies"            => Tab.runtime_deps_hash(cask, cask.depends_on),
        "arch"                    => Hardware::CPU.arch,
        "source"                  => {
          "path"         => cask.sourcefile_path.to_s,
          "tap"          => cask.tap&.name,
          "tap_git_head" => nil, # Filled in later if possible
          "version"      => cask.version.to_s,
        },
        "installed_on"            => DevelopmentTools.build_system_info,
        "artifacts"               => cask.to_h["artifacts"],
      }

      # We can only get `tap_git_head` if the tap is installed locally
      attributes["source"]["tap_git_head"] = cask.tap.git_head if cask.tap&.installed?

      new(attributes)
    end

    # Returns the {Tab} for an install receipt at `path`.
    #
    # NOTE: Results are cached.
    sig { params(path: Pathname).returns(Tab) }
    def self.from_file(path)
      cache.fetch(path) do |p|
        content = File.read(p)
        return empty if content.blank?

        cache[p] = from_file_content(content, p)
      end
    end

    # Like {from_file}, but bypass the cache.
    sig { params(content: String, path: Pathname).returns(Tab) }
    def self.from_file_content(content, path)
      attributes = begin
        JSON.parse(content)
      rescue JSON::ParserError => e
        raise e, "Cannot parse #{path}: #{e}", e.backtrace
      end
      attributes["tabfile"] = path

      new(attributes)
    end

    sig { params(cask: Cask).returns(Tab) }
    def self.for_cask(cask)
      path = cask.metadata_main_container_path/FILENAME

      return from_file(path) if path.exist?

      tab = empty
      tab.source = {
        "path"         => cask.sourcefile_path.to_s,
        "tap"          => cask.tap&.name,
        "tap_git_head" => nil,
        "version"      => cask.version.to_s,
      }
      tab.artifacts = cask.to_h["artifacts"]
      tab.source["tap_git_head"] = cask.tap.git_head if cask.tap&.installed?

      tab
    end

    sig { returns(Tab) }
    def self.empty
      attributes = {
        "homebrew_version"        => HOMEBREW_VERSION,
        "loaded_from_api"         => false,
        "installed_as_dependency" => false,
        "installed_on_request"    => false,
        "time"                    => nil,
        "dependencies"            => nil,
        "arch"                    => nil,
        "source"                  => {
          "path"         => nil,
          "tap"          => nil,
          "tap_git_head" => nil,
          "version"      => nil,
        },
        "installed_on"            => DevelopmentTools.generic_build_system_info,
        "artifacts"               => [],
      }

      new(attributes)
    end

    def self.runtime_deps_hash(cask, depends_on)
      mappable_types = [:cask, :formula]
      depends_on.to_h do |type, deps|
        next [type, deps] unless mappable_types.include? type

        deps = deps.map do |dep|
          if type == :cask
            c = CaskLoader.load(dep)
            {
              "full_name"         => c.full_name,
              "version"           => c.version.to_s,
              "declared_directly" => cask.depends_on.cask.include?(dep),
            }
          elsif type == :formula
            f = Formulary.factory(dep, warn: false)
            {
              "full_name"         => f.full_name,
              "version"           => f.version.to_s,
              "revision"          => f.revision,
              "pkg_version"       => f.pkg_version.to_s,
              "declared_directly" => cask.depends_on.formula.include?(dep),
            }
          else
            dep
          end
        end

        [type, deps]
      end
    end

    def initialize(attributes = {})
      attributes.each { |key, value| instance_variable_set(:"@#{key}", value) }
    end

    sig { returns(T.nilable(Tap)) }
    def tap
      tap_name = source["tap"]
      Tap.fetch(tap_name) if tap_name
    end

    sig { params(_args: T::Array[T.untyped]).returns(String) }
    def to_json(*_args)
      attributes = {
        "homebrew_version"        => homebrew_version,
        "loaded_from_api"         => loaded_from_api,
        "installed_as_dependency" => installed_as_dependency,
        "installed_on_request"    => installed_on_request,
        "time"                    => time,
        "dependencies"            => dependencies,
        "arch"                    => arch,
        "source"                  => source,
        "installed_on"            => installed_on,
        "artifacts"               => artifacts,
      }

      JSON.pretty_generate(attributes)
    end

    sig { void }
    def write
      self.class.cache[tabfile] = self
      tabfile.atomic_write(to_json)
    end

    sig { returns(String) }
    def to_s
      s = ["Installed"]

      s << "using the formulae.brew.sh API" if loaded_from_api
      s << Time.at(time).strftime("on %Y-%m-%d at %H:%M:%S") if time

      s.join(" ")
    end
  end
end
