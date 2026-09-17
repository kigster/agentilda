# frozen_string_literal: true

require "yaml"

module Agentilda
  # The optional half of the contract between the two halves of building.
  #
  # `contract.md` is the contract: the interfaces `rey-frontend` calls,
  # their shapes and their errors, which files each half owns, which units
  # may run concurrently, and the one test that proves the halves are
  # joined. Most of that has no OpenAPI slot, and most splits are not HTTP
  # at all — the interface between the halves is as often a service object,
  # a GraphQL schema or a TypeScript module. This gem, the thing it is
  # dogfooded on, has no HTTP surface whatsoever.
  #
  # So OpenAPI is a companion, never the contract. A plan that does expose
  # HTTP endpoints gets an `openapi.yaml` beside `contract.md`, which
  # `contract.md` links to, and which {Documentation} can then collect
  # across the whole tree for Redoc to render.
  #
  # Validation is deliberately shallow: it parses, and it has the two keys
  # that make it an OpenAPI document rather than some other YAML. A real
  # validator is another dependency, and is worth adding only if agents
  # turn out to produce documents that are broken in subtler ways than
  # this catches.
  module OpenAPI
    FILENAME = "openapi.yaml"

    # The keys a document is not one without. `openapi` carries the version
    # of the specification; `paths` is what Redoc renders.
    REQUIRED = %w[openapi paths].freeze

    # One plan's document.
    #
    # @!attribute [r] ordinal
    #   @return [String]
    # @!attribute [r] title
    #   @return [String] `info.title`, or the plan's own slug
    # @!attribute [r] path
    #   @return [String] absolute
    # @!attribute [r] problems
    #   @return [Array<String>] empty when the document is usable
    Document = Data.define(:ordinal, :title, :path, :problems) do
      # @return [Boolean]
      def usable? = problems.empty?
    end

    class << self
      # Every plan that carries one, in tree order.
      #
      # @param tree [Agentilda::Tree]
      # @return [Array<Agentilda::OpenAPI::Document>]
      def documents(tree)
        tree.features.filter_map do |feature|
          path = File.join(feature.path, FILENAME)
          next unless File.file?(path)

          read(feature, path)
        end
      end

      # @param feature [Agentilda::Feature]
      # @param path [String]
      # @return [Agentilda::OpenAPI::Document]
      def read(feature, path)
        parsed = YAML.safe_load_file(path)
        Document.new(ordinal:  feature.ordinal.to_s,
          title:    title_of(parsed, feature),
          path:,
          problems: problems_with(parsed))
      rescue Psych::Exception => e
        Document.new(ordinal: feature.ordinal.to_s,
          title: feature.slug.to_s,
          path:,
          problems: ["is not YAML: #{e.message.lines.first.to_s.strip}"])
      end

      private

      # @param parsed [Object]
      # @return [Array<String>]
      def problems_with(parsed)
        return ["is not a mapping, so it holds no OpenAPI document"] unless parsed.is_a?(Hash)

        REQUIRED.reject { |key| parsed.key?(key) }.map { |key| "has no `#{key}:` key" }
      end

      # @param parsed [Object]
      # @param feature [Agentilda::Feature]
      # @return [String]
      def title_of(parsed, feature)
        found = parsed.is_a?(Hash) ? parsed.dig("info", "title") : nil
        found.to_s.empty? ? feature.slug.to_s : found.to_s
      end
    end
  end
end
