# frozen_string_literal: true

require_relative '../../assets/app/view/game/dashboard/dashboard_ai_player'
require_relative 'checkpoint'

module AiAutoplay
  class Runner
    attr_reader :game

    def initialize(game, checkpoint_file: nil)
      @game = game
      @checkpoint_file = checkpoint_file
    end

    def play_one
      return :finished if @game.finished

      before = @game.raw_actions.size
      selected_action = nil

      ai = View::Game::Dashboard::DashboardAiPlayer.new(@game, []) do |action|
        selected_action = action

        @game
          .process_action(action, add_auto_actions: true)
          .maybe_raise!
      end

      result = ai.play
      after = @game.raw_actions.size

      raise 'AI did not select an action' unless result
      raise 'AI reported success but selected no action' unless selected_action

      raise "Expected exactly one new action, got #{after - before}" unless after == before + 1

      Checkpoint.write(@game, @checkpoint_file) if @checkpoint_file

      selected_action
    end

    def play(max_moves:)
      moves_completed = 0
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      while !@game.finished && moves_completed < max_moves
        action = play_one
        break if action.equal?(:finished)

        moves_completed += 1

        puts(
          "MOVE #{@game.raw_actions.size}: " \
          "#{action.type} " \
          "round=#{@game.round.class} " \
          "step=#{@game.round.active_step&.class}"
        )
      end

      elapsed =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      moves_per_second =
        elapsed.positive? ? moves_completed / elapsed : 0.0

      {
        moves_completed: moves_completed,
        action_count: @game.raw_actions.size,
        finished: @game.finished,
        elapsed_seconds: elapsed,
        moves_per_second: moves_per_second,
      }
    end
  end
end
