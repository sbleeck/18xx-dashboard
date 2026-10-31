# frozen_string_literal: true

require 'fileutils'
require 'json'

require_relative '../../assets/app/view/game/dashboard/dashboard_ai_player'
require_relative 'checkpoint'

module AiAutoplay
  class Runner
    attr_reader :game

    def initialize(
      game,
      checkpoint_file: nil,
      live_fixture_file: nil
    )
      @game = game
      @checkpoint_file = checkpoint_file
      @live_fixture_file = live_fixture_file
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

      if @checkpoint_file
        Checkpoint.write(
          @game,
          @checkpoint_file
        )
      end

      write_live_fixture if @live_fixture_file

      selected_action
    end

    def play(max_moves:)
      moves_completed = 0

      started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      while !@game.finished &&
            moves_completed < max_moves
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
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) - started_at

      moves_per_second =
        if elapsed.positive?
          moves_completed / elapsed
        else
          0.0
        end

      {
        moves_completed: moves_completed,
        action_count: @game.raw_actions.size,
        finished: @game.finished,
        elapsed_seconds: elapsed,
        moves_per_second: moves_per_second,
      }
    end

    private

    def write_live_fixture
      file = File.expand_path(@live_fixture_file)

      FileUtils.mkdir_p(
        File.dirname(file)
      )

      players = @game.players.map do |player|
        {
          'id' => player.id,
          'name' => player.name,
        }
      end

      settings = {
        'seed' => @game.seed,
        'optional_rules' =>
          if @game.respond_to?(:optional_rules)
            Array(@game.optional_rules)
          else
            []
          end,
      }

      now = Time.now.to_i

      data = {
        'id' =>
          File.basename(
            File.dirname(file)
          ),

        'description' =>
          "AI autoplay #{@game.class.title}",

        'user' => {
          'id' => 0,
          'name' => 'You',
        },

        'players' => players,
        'min_players' => players.size,
        'max_players' => players.size,

        'title' => @game.class.title,
        'settings' => settings,
        'user_settings' => {},

        # Marking the fixture as finished prevents the dashboard from
        # attempting server-side game interaction. The engine position
        # itself is reconstructed from the action history below.
        'status' => 'finished',

        'turn' =>
          (@game.turn if @game.respond_to?(:turn)),

        'round' =>
          @game.round&.class&.name,

        'acting' => [],

        'result' => {},

        'actions' =>
          Array(@game.raw_actions),

        'loaded' => true,

        'created_at' => now,
        'updated_at' => now,

        'finished_at' =>
          @game.finished ? now : nil,
      }

      temporary =
        "#{file}.tmp.#{$PROCESS_ID || Process.pid}"

      File.write(
        temporary,
        JSON.generate(data)
      )

      File.rename(
        temporary,
        file
      )
    rescue StandardError => e
      warn(
        '[LIVE FIXTURE] ' \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
