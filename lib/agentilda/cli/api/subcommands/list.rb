# frozen_string_literal: true

module Agentilda
  module CLI
    module API
      # `agentilda api list` — which plans carry an OpenAPI document, and
      # whether each one is usable.
      #
      # The check is shallow on purpose: it parses, and it has the two keys
      # that make it an OpenAPI document. That catches the failure an agent
      # actually produces — a file written before it was finished — without
      # another dependency.
      class List < Base
        include Collecting

        desc "List the OpenAPI documents plans carry, and any that are unusable"

        example [
          "                 # every plan that has one",
          "--dir .plans     # in a tree somewhere else"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          documents = documents_for(options)
          if documents.empty?
            UI.line("No plan carries an #{Agentilda::OpenAPI::FILENAME}.") unless quiet?(options)
            return
          end

          puts(documents.map { |document| line_for(document) })
          refuse("#{documents.count { |d| !d.usable? }} unusable.", 65) unless documents.all?(&:usable?)
        end

        private

        # @param document [Agentilda::OpenAPI::Document]
        # @return [String]
        def line_for(document)
          return "#{document.ordinal}  #{document.title}" if document.usable?

          "#{document.ordinal}  #{document.title} - #{document.problems.join(", ")}"
        end
      end
    end
  end
end
