# frozen_string_literal: true

require "json"
require "time"

module Agentilda
  # A folder of markdown files standing in for GitHub.
  #
  # `resync prs --fake-github-path DIR` reads pull requests from `DIR/*.md`
  # instead of `gh`, and writes retitles back into the same files. It exists
  # so the whole command can run offline against a fixture whose right
  # answers are known — the evals in plan 003.00 — and the fixture doubles
  # as a readable example of what the tool expects a pull request to carry.
  #
  # One file per pull request:
  #
  #   ---
  #   number: 12
  #   title: Add the DSL printer
  #   branch: kig/003.00-dsl-printer
  #   state: merged            # open, merged, closed or draft
  #   created_at: 2026-08-01T10:00:00Z
  #   merged_at: 2026-08-03T16:20:00Z
  #   head_sha: 0123abcd
  #   files:
  #     - path: lib/printer.rb
  #       additions: 120
  #       deletions: 4
  #   ---
  #   The description, as it would read on GitHub.
  #
  # The interface is {GitHub}'s, and every reader of a pull request hash
  # sees exactly the keys {GitHub.normalize} produces.
  class FakeGitHub
    # @param dir [String] the folder of pull request files
    def initialize(dir:)
      @dir = File.expand_path(dir)
    end

    # @return [String]
    attr_reader :dir

    # @param state [String] "open", "closed", "merged" or "all"
    # @return [Array<Hash>] see {GitHub#pulls}
    def pulls(state: "all")
      raise Error, "no pull request folder at #{dir}" unless File.directory?(dir)

      all = paths.map { |path| read(path) }.sort_by { |pr| pr[:number].to_i }
      return all if state == "all"

      all.select { |pr| matches_state?(pr, state) }
    end

    # @param ref [String] a number, `#`-prefixed or bare
    # @return [Hash] `{number:, title:, url:, state:, body:}`
    # @raise [Agentilda::Error]
    def pull_request(ref)
      number = ref.to_s[/\d+\z/].to_i
      pr = pulls.find { |p| p[:number] == number } or
        raise Error, "no pull request ##{number} under #{dir}"

      pr.slice(:number, :title, :url, :state, :body)
    end

    # @param refs [Array<String>]
    # @return [Array<Hash>]
    def pull_requests(refs) = refs.map { |ref| pull_request(ref) }

    # Rewrite the `title:` line of the file, and nothing else in it.
    #
    # @param number [Integer]
    # @param title [String]
    # @return [void]
    # @raise [Agentilda::Error] when no file carries that number
    def retitle(number:, title:)
      path = path_for(number) or raise Error, "no pull request ##{number} under #{dir}"
      content = File.read(path, encoding: "UTF-8")
      updated = content.sub(/^title:.*$/) { "title: #{title.to_json}" }
      raise Error, "#{File.basename(path)} has no title: line to rewrite" if updated == content && !content.match?(/^title:/)

      File.write(path, updated)
    end

    # @return [String] a cache key, from the folder's name
    def slug = "fake-#{File.basename(dir).delete_prefix(".")}"

    # @return [Boolean]
    def available? = File.directory?(dir)

    private

    # @return [Array<String>]
    def paths = Dir.glob(File.join(dir, "*.md")).sort

    # @param number [Integer]
    # @return [String, nil]
    def path_for(number)
      paths.find { |path| read(path)[:number] == number.to_i }
    end

    # @param path [String]
    # @return [Hash]
    def read(path)
      meta, body = Frontmatter.split(File.read(path, encoding: "UTF-8"))
      number = meta["number"] || File.basename(path, ".md")[/\d+/]
      state = meta["state"].to_s.downcase
      merged_at = meta["merged_at"]
      GitHub.normalize(
        "number" => number.to_i,
        "title" => meta["title"],
        "url" => meta["url"] || "https://github.com/example/repo/pull/#{number.to_i}",
        "headRefName" => meta["branch"],
        "files" => Array(meta["files"]).map { |f| f.is_a?(Hash) ? f : {"path" => f.to_s} },
        "state" => (state == "merged" || state == "closed") ? "CLOSED" : "OPEN",
        "isDraft" => state == "draft",
        "createdAt" => meta["created_at"],
        "mergedAt" => merged_at || ((state == "merged") ? meta["created_at"] : nil),
        "headRefOid" => meta["head_sha"],
        "body" => body.to_s.strip
      )
    rescue Psych::Exception => e
      raise Error, "#{path}: #{e.message.lines.first.to_s.strip}"
    end

    # @param pr [Hash]
    # @param state [String]
    # @return [Boolean]
    def matches_state?(pr, state)
      case state
      when "open" then pr[:open]
      when "merged" then !pr[:merged_at].nil?
      when "closed" then !pr[:open]
      else true
      end
    end
  end
end
