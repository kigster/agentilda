# frozen_string_literal: true

module Agentilda
  module Web
    # One store per Puma thread. {Live::Store} holds a single Redis
    # connection, which two threads must not share: an event stream polling
    # on one thread and a command posted on another would interleave their
    # replies on the wire.
    #
    # Puma's threads are pooled, so the map is bounded by the pool's size.
    class Stores
      # Every thread gets the same store: {Live::MemoryStore}, which lives in
      # this process and is already synchronised.
      #
      # @param store [Agentilda::Live::MemoryStore]
      # @return [Agentilda::Web::Stores]
      def self.shared(store) = new { store }

      # @yieldreturn [Agentilda::Live::Store] a new store
      def initialize(&factory)
        @factory = factory
        @mutex = Mutex.new
        @by_thread = {}
      end

      # @return [Agentilda::Live::Store, Agentilda::Live::MemoryStore]
      def current = @mutex.synchronize { @by_thread[Thread.current] ||= @factory.call }

      # @return [void]
      def close
        stores = @mutex.synchronize { @by_thread.values.uniq.tap { @by_thread.clear } }
        stores.each(&:close)
      end
    end
  end
end
