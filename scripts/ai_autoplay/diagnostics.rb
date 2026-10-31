# frozen_string_literal: true

require 'json'
require 'fileutils'

module AiAutoplay
  class Diagnostics
    def self.write(game:, exception:, checkpoint_file:)
      directory = File.dirname(File.expand_path(checkpoint_file))
      FileUtils.mkdir_p(directory)

      step = game.round&.active_step
      entity = begin
        game.current_entity
      rescue StandardError
        nil
      end

      available_actions = begin
        game.round.actions_for(entity)
      rescue StandardError
        []
      end

      last_action = game.raw_actions.last

      data = {
        'title' => game.class.title,
        'seed' => game.seed,
        'action_count' => game.raw_actions.size,
        'turn' => game.turn,
        'round' => game.round&.class&.name,
        'step' => step&.class&.name,
        'entity_type' => entity&.class&.name,
        'entity_id' => entity&.id,
        'entity_name' => entity&.name,
        'available_actions' => available_actions,
        'last_successful_action' => last_action,
        'exception_class' => exception.class.name,
        'exception_message' => exception.message,
        'backtrace' => Array(exception.backtrace).first(30),
        'checkpoint' => File.expand_path(checkpoint_file),
      }

      json_file = File.join(directory, 'failure.json')
      text_file = File.join(directory, 'failure.txt')

      File.write(
        json_file,
        JSON.pretty_generate(data)
      )

      resume_command =
        "bundle exec ruby scripts/ai_autoplay/autoplay.rb " \
        "--continue #{File.expand_path(checkpoint_file)}"

      text = <<~TEXT
        AI AUTOPLAY FAILURE

        Game: #{data['title']}
        Seed: #{data['seed']}
        Action count: #{data['action_count']}
        Turn: #{data['turn']}

        Round: #{data['round']}
        Step: #{data['step']}

        Acting entity:
          #{data['entity_type']}
          #{data['entity_id']}: #{data['entity_name']}

        Available actions:
          #{data['available_actions'].inspect}

        Last successful action:
          #{data['last_successful_action'].inspect}

        Exception:
          #{data['exception_class']}: #{data['exception_message']}

        Checkpoint:
          #{data['checkpoint']}

        Resume with:

          #{resume_command}

        Backtrace:

        #{data['backtrace'].join("\n")}
      TEXT

      File.write(text_file, text)

      {
        json: json_file,
        text: text_file,
        resume_command: resume_command,
      }
    end
  end
end