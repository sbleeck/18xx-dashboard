# frozen_string_literal: true

require 'fileutils'
require 'optparse'

require_relative 'game_factory'
require_relative 'runner'
require_relative 'checkpoint'
require_relative 'diagnostics'

module AiAutoplay
  class CLI
    DEFAULT_PLAYERS = 3
    DEFAULT_MAX_MOVES = 1_000

    def self.run(argv)
      options = {
        players: DEFAULT_PLAYERS,
        max_moves: DEFAULT_MAX_MOVES,
      }

      parser = OptionParser.new do |opts|
        opts.banner = <<~TEXT
          Usage:

            Start a new game:
              bundle exec ruby scripts/ai_autoplay/autoplay.rb \
                --new TITLE \
                --players 3 \
                --seed 12345

            Continue a saved game:
              bundle exec ruby scripts/ai_autoplay/autoplay.rb \
                --continue PATH/TO/current.json

            Continuously update a browser fixture:
              bundle exec ruby scripts/ai_autoplay/autoplay.rb \
                --continue PATH/TO/current.json \
                --live-fixture public/fixtures/ai_catalogue/GAME/current.json
        TEXT

        opts.on(
          '--new TITLE',
          'Start a fresh game'
        ) do |title|
          options[:title] = title
        end

        opts.on(
          '--continue FILE',
          'Continue an existing checkpoint'
        ) do |file|
          options[:continue] = file
        end

        opts.on(
          '--players NUMBER',
          Integer,
          'Number of AI players (default: 3)'
        ) do |number|
          options[:players] = number
        end

        opts.on(
          '--seed NUMBER',
          Integer,
          'Deterministic game seed'
        ) do |seed|
          options[:seed] = seed
        end

        opts.on(
          '--max-moves NUMBER',
          Integer,
          'Maximum AI moves this run (default: 1000)'
        ) do |number|
          options[:max_moves] = number
        end

        opts.on(
          '--output DIRECTORY',
          'Output directory for a new game'
        ) do |directory|
          options[:output] = directory
        end

        opts.on(
          '--live-fixture FILE',
          'Continuously update a browser fixture after every move'
        ) do |file|
          options[:live_fixture] = file
        end

        opts.on(
          '-h',
          '--help',
          'Show this help'
        ) do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)

      if options[:title] && options[:continue]
        raise OptionParser::InvalidArgument,
              'use either --new or --continue, not both'
      end

      unless options[:title] || options[:continue]
        raise OptionParser::MissingArgument,
              '--new TITLE or --continue FILE is required'
      end

      unless options[:max_moves].positive?
        raise OptionParser::InvalidArgument,
              '--max-moves must be positive'
      end

      if options[:continue]
        run_existing(options)
      else
        run_new(options)
      end
    rescue OptionParser::ParseError => e
      warn "CLI error: #{e.message}"
      warn
      warn parser
      2
    rescue StandardError => e
      warn
      warn "AUTOPLAY STOPPED: #{e.class}: #{e.message}"
      warn Array(e.backtrace).first(15).join("\n")
      1
    end

    def self.run_new(options)
      unless options[:players].positive?
        raise OptionParser::InvalidArgument,
              '--players must be positive'
      end

      options[:seed] ||= Random.new_seed

      safe_title = options[:title]
        .downcase
        .gsub(/[^a-z0-9_-]+/, '_')
        .gsub(/\A_+|_+\z/, '')

      output_directory =
        options[:output] ||
        File.join(
          'tmp',
          'ai_autoplay',
          "#{safe_title}-seed-#{options[:seed]}"
        )

      FileUtils.mkdir_p(output_directory)

      checkpoint_file =
        File.join(
          output_directory,
          'current.json'
        )

      game = GameFactory.create(
        title: options[:title],
        player_count: options[:players],
        seed: options[:seed],
      )

      Checkpoint.write(
        game,
        checkpoint_file
      )

      puts "Starting #{options[:title]}"
      puts "Players: #{game.players.map(&:name).join(', ')}"
      puts "Seed: #{options[:seed]}"
      puts "Checkpoint: #{checkpoint_file}"

      puts "Live fixture: #{options[:live_fixture]}" if options[:live_fixture]

      puts

      run_game(
        game,
        checkpoint_file,
        options[:max_moves],
        options[:live_fixture],
      )
    end

    def self.run_existing(options)
      checkpoint_file =
        File.expand_path(
          options[:continue]
        )

      unless File.file?(checkpoint_file)
        raise ArgumentError,
              "Checkpoint not found: #{checkpoint_file}"
      end

      game =
        Checkpoint.load(
          checkpoint_file
        )

      puts "Continuing #{game.class.title}"
      puts "Players: #{game.players.map(&:name).join(', ')}"
      puts "Seed: #{game.seed}"
      puts "Existing actions: #{game.raw_actions.size}"
      puts "Checkpoint: #{checkpoint_file}"

      puts "Live fixture: #{options[:live_fixture]}" if options[:live_fixture]

      puts

      if game.finished
        puts 'This game is already finished.'
        return 0
      end

      run_game(
        game,
        checkpoint_file,
        options[:max_moves],
        options[:live_fixture],
      )
    end

    def self.run_game(
      game,
      checkpoint_file,
      max_moves,
      live_fixture_file = nil
    )
      runner = Runner.new(
        game,
        checkpoint_file: checkpoint_file,
        live_fixture_file: live_fixture_file,
      )

      result =
        runner.play(
          max_moves: max_moves
        )

      puts
      puts "Finished: #{result[:finished]}"
      puts "Moves completed this run: #{result[:moves_completed]}"
      puts "Total actions: #{result[:action_count]}"

      puts format(
        'Elapsed time: %.2f seconds',
        result[:elapsed_seconds]
      )

      puts format(
        'Speed: %.2f moves/second',
        result[:moves_per_second]
      )

      puts "Checkpoint: #{checkpoint_file}"

      puts "Live fixture: #{live_fixture_file}" if live_fixture_file

      result[:finished] ? 0 : 1
    rescue StandardError => e
      report =
        Diagnostics.write(
          game: game,
          exception: e,
          checkpoint_file: checkpoint_file,
        )

      warn
      warn "AUTOPLAY STUCK at action #{game.raw_actions.size + 1}"
      warn "#{e.class}: #{e.message}"
      warn
      warn "Failure report: #{report[:text]}"
      warn "JSON report: #{report[:json]}"
      warn
      warn 'Resume with:'
      warn "  #{report[:resume_command]}"

      1
    end
  end
end

exit AiAutoplay::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
