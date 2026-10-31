# frozen_string_literal: true

require_relative '../../lib/engine'

module AiAutoplay
  class GameFactory
    def self.create(title:, player_count:, seed:)
      game_class = Engine.game_by_title(title)
      raise "Unknown game: #{title}" unless game_class

      players = (1..player_count).to_h do |id|
        [id, "AI #{id}"]
      end

      game_class.new(
        players,
        id: 1,
        seed: seed,
        optional_rules: [],
        use_engine_v2: false,
      )
    end
  end
end
