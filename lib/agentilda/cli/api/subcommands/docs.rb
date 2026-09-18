# frozen_string_literal: true

require "fileutils"

module Agentilda
  module CLI
    module API
      # `agentilda api docs` — every plan's OpenAPI document, rendered as a
      # browsable site.
      #
      # This is the payoff for writing the HTTP half of a contract in a
      # standard format rather than prose: one place that shows every
      # endpoint the tree has grown, across plans, without anybody
      # maintaining an index of them.
      #
      # The pages load Redoc from a CDN rather than vendoring it. The output
      # is a throwaway view of documents that live in the plans, regenerated
      # whenever it is wanted, so a build step and a megabyte of JavaScript
      # in the repository would both be worse than a script tag.
      class Docs < Base
        include Collecting

        # Where Redoc comes from, pinned: an unpinned `latest` changes what
        # a page renders without anything in the repository changing.
        REDOC = "https://cdn.jsdelivr.net/npm/redoc@2.1.5/bundles/redoc.standalone.js"

        desc "Render every plan's OpenAPI document as a Redoc site"

        option :output, default: "docs/api", desc: "Where to write the site"

        example [
          "                           # into docs/api",
          "--output tmp/api           # somewhere throwaway"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          usable = documents_for(options).select(&:usable?)
          refuse("No plan carries a usable #{Agentilda::OpenAPI::FILENAME}.", 65) if usable.empty?

          output = File.expand_path(options.fetch(:output, "docs/api"))
          FileUtils.mkdir_p(output)
          usable.each { |document| write_page(output, document) }
          File.write(File.join(output, "index.html"), index(usable))

          return if quiet?(options)

          UI.line("Wrote #{usable.size} #{usable.size == 1 ? "document" : "documents"} to #{output}/index.html")
        end

        private

        # The document is copied in beside its page rather than linked
        # across the filesystem, so the site can be opened, served or moved
        # anywhere as one directory.
        #
        # @return [void]
        def write_page(output, document)
          FileUtils.cp(document.path, File.join(output, "#{document.ordinal}.yaml"))
          File.write(File.join(output, "#{document.ordinal}.html"), page(document))
        end

        # @param document [Agentilda::OpenAPI::Document]
        # @return [String]
        def page(document)
          <<~HTML
            <!doctype html>
            <html lang="en">
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>#{escape(document.title)}</title>
                <style>body { margin: 0; }</style>
              </head>
              <body>
                <redoc spec-url="#{document.ordinal}.yaml"></redoc>
                <script src="#{REDOC}"></script>
              </body>
            </html>
          HTML
        end

        # @param documents [Array<Agentilda::OpenAPI::Document>]
        # @return [String]
        def index(documents)
          items = documents.map { |d|
            %(      <li><a href="#{d.ordinal}.html">#{escape(d.ordinal)} &middot; #{escape(d.title)}</a></li>)
          }.join("\n")
          <<~HTML
            <!doctype html>
            <html lang="en">
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>Plan APIs</title>
                <style>
                  body { font: 16px/1.6 system-ui, sans-serif; margin: 3rem auto; max-width: 42rem; padding: 0 1rem; }
                  li { margin: .35rem 0; }
                </style>
              </head>
              <body>
                <h1>Plan APIs</h1>
                <ul>
            #{items}
                </ul>
              </body>
            </html>
          HTML
        end

        # A title comes out of a plan's own document, so it is not ours to
        # trust with the page it is written into.
        #
        # @param text [String]
        # @return [String]
        def escape(text)
          text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
        end
      end
    end
  end
end
