# frozen_string_literal: true

require "json"

module Agentilda
  # Default option overrides, read from `~/.local/config/agentilda.json`.
  #
  # The file is keyed by command, so it can grow without every command
  # seeing every key:
  #
  #   {
  #     "run": { "timeout": 1800, "jobs": 4 }
  #   }
  #
  # Precedence is: an option passed on the command line, then this file,
  # then the built-in default. The file supplies *defaults*, never
  # mandates — nothing here can force `--commit`, which stays a flag a
  # person types.
  #
  # An unreadable file is an error, not a shrug: a config silently ignored
  # is how a timeout somebody set stops applying with no signal anywhere.
  class Config
    PATH = File.join(Dir.home, ".local", "config", "agentilda.json")

    # @param command [Symbol, String] the command whose section to read
    # @param path [String] the config file
    # @return [Hash{Symbol => Object}] that command's overrides, {} when the
    #   file or the section is absent
    # @raise [Agentilda::Error] when the file exists and cannot be used
    def self.for(command, path: PATH)
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      raise Error, "#{path}: expected a JSON object keyed by command" unless data.is_a?(Hash)

      section = data.fetch(command.to_s, {})
      raise Error, "#{path}: \"#{command}\" must be a JSON object" unless section.is_a?(Hash)

      section.transform_keys(&:to_sym)
    rescue JSON::ParserError => e
      raise Error, "#{path} is not valid JSON: #{e.message.lines.first.to_s.strip}"
    end
  end
end
