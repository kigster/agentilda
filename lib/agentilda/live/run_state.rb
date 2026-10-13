# frozen_string_literal: true

module Agentilda
  module Live
    # What a person has said about the run that the plan folders do not
    # record: the questions they are holding, the agents they asked to hold,
    # and the models chosen for agents' next rounds.
    #
    # Held in the engine for the run's lifetime. A model choice also lives
    # in the executor, which is what applies it; this copy is what the page
    # is shown.
    class RunState
      def initialize
        @mutex = Mutex.new
        @held_questions = []
        @held_cars = []
        @models = {}
      end

      # @param id [String] `"<ordinal>/B<n>"`
      # @param held [Boolean]
      # @return [void]
      def hold_question(id, held: true) = toggle(@held_questions, id, held)

      # @param id [String]
      # @return [Boolean]
      def question_held?(id) = @mutex.synchronize { @held_questions.include?(id) }

      # @param key [String] `"<ordinal>/<agent>"`
      # @param held [Boolean]
      # @return [void]
      def hold_car(key, held: true) = toggle(@held_cars, key, held)

      # @param key [String]
      # @return [Boolean]
      def car_held?(key) = @mutex.synchronize { @held_cars.include?(key) }

      # @param key [String] `"<ordinal>/<agent>"`
      # @param model [String, nil] nil forgets the choice
      # @return [void]
      def choose_model(key, model) = @mutex.synchronize { model ? @models[key] = model : @models.delete(key) }

      # @param key [String]
      # @return [String, nil] the model queued for that agent's next round
      def model_for(key) = @mutex.synchronize { @models[key] }

      private

      # @return [void]
      def toggle(list, item, on)
        @mutex.synchronize { on ? list.push(item).uniq! : list.delete(item) }
      end
    end
  end
end
