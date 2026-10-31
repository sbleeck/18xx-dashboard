# frozen_string_literal: true

require 'json'

module AiAutoplay
  class Checkpoint
    def self.data(game)
      {
        'title' => game.class.title,
        'id' => game.id,
        'players' => game.players.sort_by { |player| player.id.to_i }.map do |player|
                       {
                         'id' => player.id,
                         'name' => player.name,
                       }
                     end,
        'settings' => {
          'seed' => game.seed,
          'optional_rules' => game.optional_rules,
          'use_engine_v2' => game.use_engine_v2,
        },
        'actions' => game.raw_actions,
      }
    end

    def self.write(game, filename)
      File.write(
        filename,
        JSON.pretty_generate(data(game))
      )
    end

    def self.load(filename)
      Engine::Game.load(filename).maybe_raise!
    end
  end
end
