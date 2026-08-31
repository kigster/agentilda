# frozen_string_literal: true

require "dry/cli/program_name"
require "pastel"

module Dry
  class CLI
    # Utility module for wrapping text to a given width
    module WordWrap
      def wrap_description(text, width: 55, prefix: "  ")
        text.split("\n", -1).map { |para|
          para.scan(/\S.{0,#{width - 1}}(?=\s|\z)|\S{#{width},}/).join("\n#{prefix}")
        }.join("\n")
      end
    end

    # Command banner
    #
    # @since 0.1.0
    # @api private
    module Banner
      extend WordWrap

      @color_enabled = true

      module ColorMethods
        @pastel = nil

        COLOR_METHODS = %i[
          yellow
          green
          red
          blue
          magenta
          cyan
          white
          black
          gray
          bright_white
          bright_black
          bright_red
          bright_green
          bright_blue
          bright_magenta
          bright_cyan
          bright_gray
        ].freeze

        # Pastel answers a colour two ways: `yellow("text")` decorates in one
        # call, `yellow.bold("text")` returns a chain to decorate further. The
        # colourless stand-in has to answer both shapes, so given text it hands
        # the text straight back and given nothing it hands back itself.
        DECORATIONS = %i[bold dim italic underline inverse strikethrough blink].freeze

        class NoColorPastel
          (COLOR_METHODS + DECORATIONS).each do |name|
            define_method(name) { |*args| args.empty? ? self : args.join }
          end
        end

        def pastel
          @pastel ||= if Banner.color_enabled?
            Pastel.new
          else
            NoColorPastel.new
          end
        end

        extend Forwardable

        def_delegators :pastel, *COLOR_METHODS
      end

      extend ColorMethods

      def self.color_enabled?
        @color_enabled
      end

      def self.enable_color!
        @pastel = nil
        @color_enabled = true
      end

      def self.disable_color!
        @pastel = nil
        @color_enabled = false
      end

      def self.color_header(string)
        color_enabled? ? bright_blue.bold(string.upcase) : string.upcase
      end

      def self.color_command(string)
        color_enabled? ? green.bold(string) : string
      end

      def self.color_arguments(string)
        color_enabled? ? yellow.italic(string) : string
      end

      # Prints command banner
      #
      # @param command [Dry::CLI::Command] the command
      # @param out [IO] standard output
      #
      # @since 0.1.0
      # @api private
      def self.call(command, name)
        [
          command_name(name),
          command_name_and_arguments(command, name),
          command_description(command),
          command_subcommands(command),
          command_arguments(command),
          command_options(command),
          command_examples(command, name)
        ].compact.join("\n")
      end

      # @since 0.1.0
      # @api private
      def self.command_name(name)
        color_header("Command:\n") + "  #{yellow(name)}"
      end

      # @since 0.1.0
      # @api private
      def self.command_name_and_arguments(command, name)
        usage = "\n#{color_header("Usage")}:\n  #{color_command(name)}#{color_arguments(arguments(command))}"

        return usage + " | #{name} SUBCOMMAND" if command.subcommands.any?

        usage
      end

      # @since 0.1.0
      # @api private
      def self.command_examples(command, name)
        return if command.examples.empty?

        "\n#{color_header("Examples")}:\n" + command.examples.map do |example|
          args, desc = example.split("#")
          comment_line = (desc.nil? || desc.empty?) ? "" : "  #{bright_black("##{desc}")}\n"
          comment_line + "  #{color_command(name)} #{color_arguments(args)}"
        end.join("\n\n")
      end

      # @since 0.1.0
      # @api private
      def self.command_description(command)
        return if command.description.nil?

        "\n#{color_header("Description")}:\n  #{command.description}"
      end

      def self.command_subcommands(command)
        return if command.subcommands.empty?

        "\n#{color_header("Subcommands")}:\n#{build_subcommands_list(command.subcommands)}"
      end

      # @since 0.1.0
      # @api private
      def self.command_arguments(command)
        return if command.arguments.empty?

        "\n#{color_header("Arguments")}:\n#{extended_command_arguments(command)}"
      end

      # @since 0.1.0
      # @api private
      def self.command_options(command)
        "\n#{color_header("Options")}:\n#{extended_command_options(command)}"
      end

      # @since 0.1.0
      # @api private
      def self.arguments(command)
        required_arguments = command.required_arguments
        optional_arguments = command.optional_arguments

        required = required_arguments.map { |arg| arg.name.upcase }.join(" ") if required_arguments.any?
        optional = optional_arguments.map { |arg| "[#{arg.name.upcase}]" }.join(" ") if optional_arguments.any?
        result = [required, optional].compact

        " #{result.join(" ")}" unless result.empty?
      end

      DESCRIPTION_START = 25

      # @since 0.1.0
      # @api private
      def self.extended_command_arguments(command)
        command.arguments.map do |argument|
          "    #{argument.name.to_s.upcase.ljust(DESCRIPTION_START)}  # #{"REQUIRED " if argument.required?}#{wrap_description(argument.desc, prefix: " " * 31 + "# ")}"
        end.join("\n")
      end

      # @since 0.1.0
      # @api private
      #
      def self.extended_command_options(command)
        result = command.options.map do |option|
          name = Inflector.dasherize(option.name)
          name = if option.boolean?
            "[no-]#{name}"
          elsif option.flag?
            name
          elsif option.array?
            "#{name}=VALUE1,VALUE2,.."
          else
            "#{name}=VALUE"
          end
          name = "#{name}, #{option.alias_names.join(", ")}" if option.aliases.any?
          name = "  --#{name.ljust(DESCRIPTION_START)}"
          name = "#{name}  # #{wrap_description(option.desc, prefix: " " * 31 + "# ")}"
          name = "#{name}, default: #{option.default.inspect}" unless option.default.nil?
          name
        end

        result << "  --#{"help, -h".ljust(DESCRIPTION_START)}  # Print this help"
        result.join("\n")
      end

      def self.build_subcommands_list(subcommands)
        subcommands.map do |subcommand_name, subcommand|
          "  #{yellow(subcommand_name.ljust(12))}  # #{red(wrap_description(subcommand.command.description))}`"
        end.join("\n")
      end
    end
  end
end
