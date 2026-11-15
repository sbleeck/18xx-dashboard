# frozen_string_literal: true

require 'view/game/dashboard/dashboard_chess_clock'

module View
  module Game
    module Dashboard
      module ChessClock
        # Converts the authoritative top-level server action history into the
        # post-action Transition objects consumed by ChessClock::Ledger.
        #
        # The adapter never mutates the live game. It creates an isolated game,
        # advances ordinary actions once, and reloads on undo/redo so engine
        # filtered_actions remains the sole authority on effective game state.
        class ReplayAdapter
          class ReplayError < Error; end
          class UnsupportedLoader < ReplayError; end
          class AmbiguousPhase < ReplayError; end

          MESSAGE_ACTION = 'message'
          PHASE_COLOURS = %w[yellow green brown grey].freeze

          attr_reader :game_data, :loader, :warnings

          def initialize(game_data:, loader: nil)
            @game_data = deep_stringify_keys(game_data || {})
            @loader = loader
            @warnings = []
            validate_game_data!
          end

          def transitions
            @warnings = []
            actions = raw_actions
            game = load_isolated_game(prefix_data(actions, 0))
            output = []
            last_timestamp = nil

            actions.each_with_index do |raw_action, index|
              action = deep_stringify_keys(raw_action)
              action_id = action['id']
              action_type = action['type'].to_s
              timestamp = parse_timestamp(action['created_at'])
              unless timestamp.positive?
                raise ReplayError, "Missing authoritative timestamp for action #{action_id || (index + 1)}"
              end
              if last_timestamp && timestamp < last_timestamp
                raise ReplayError, "Non-monotonic timestamp at action #{action_id || (index + 1)}"
              end

              last_timestamp = timestamp

              if %w[undo redo].include?(action_type)
                game = load_isolated_game(prefix_data(actions, index + 1))
              else
                game = game.process_action(action)
                check_engine_exception!(game, action_id)
              end

              # Messages are replayed but do not form independent clock anchors.
              next if action_type == MESSAGE_ACTION

              output << transition_for(game, action, index + 1, timestamp)
            rescue Error
              raise
            rescue StandardError => e
              raise ReplayError, "Could not replay action #{action_id || (index + 1)}: #{e.class}: #{e.message}"
            end
            output
          end

          def ledger(config: Config.default)
            player_ids = raw_players.map { |player| value(player, 'id') }.compact
            Ledger.new(player_ids: player_ids, config: config).reconstruct(transitions)
          end

          private

          def transition_for(game, action, sequence, timestamp)
            round = game.respond_to?(:round) ? game.round : nil
            round_kind = identify_round_kind(round, game)
            operating_entity = round_kind == :operating ? identify_operating_entity(round, game) : nil
            responsible_entity = identify_responsible_entity(round, game, operating_entity)
            responsible_player = controlling_player(responsible_entity, game)

            Transition.new(
              sequence: sequence,
              action_id: action['id'] || sequence,
              timestamp: timestamp,
              action_type: action['type'],
              responsible_player_id: entity_id(responsible_player),
              round_kind: round_kind,
              round_key: round_key(round, game, round_kind),
              operating_entity_id: entity_id(operating_entity),
              phase_color: round_kind == :operating ? phase_color(game) : nil,
              finished: game.respond_to?(:finished?) && game.finished?
            )
          end

          # Use the post-action active step first. During company abilities this
          # may be a company, whose owner chain is followed back to a player.
          def identify_responsible_entity(round, game, operating_entity)
            step_entity = safe_call(round&.active_step, :current_entity)
            round_entity = safe_call(round, :current_entity)
            game_entity = safe_call(game, :current_entity)
            step_entity || round_entity || game_entity || operating_entity
          end

          # The operating allowance belongs to the round's operating entity,
          # not a private company temporarily exposed by an active step.
          def identify_operating_entity(round, game)
            entity = safe_call(round, :current_entity)
            entity ||= safe_call(game, :current_entity)
            return entity if corporation_or_minor?(entity)

            entities = safe_call(round, :entities)
            index = safe_call(round, :entity_index)
            candidate = Array(entities)[index.to_i] if entities && index
            corporation_or_minor?(candidate) ? candidate : nil
          end

          def controlling_player(entity, game)
            seen = {}
            current = entity
            8.times do
              return nil unless current

              key = current.object_id
              return nil if seen[key]

              seen[key] = true
              return current if player?(current, game)

              current = safe_call(current, :owner) || safe_call(current, :player)
            end
            nil
          end

          def player?(entity, game)
            return entity.player? if entity.respond_to?(:player?)

            Array(safe_call(game, :players)).any? { |player| entity_id(player) == entity_id(entity) }
          end

          def corporation_or_minor?(entity)
            return false unless entity
            return true if entity.respond_to?(:corporation?) && entity.corporation?
            return true if entity.respond_to?(:minor?) && entity.minor?

            name = entity.class.name.to_s
            name.include?('Corporation') || name.include?('Minor')
          end

          def identify_round_kind(round, game)
            return :finished if game.respond_to?(:finished?) && game.finished?
            return :stock if predicate?(round, :stock?)
            return :operating if predicate?(round, :operating?)

            name = round&.class&.name.to_s.downcase
            return :stock if name.include?('stock')
            return :operating if name.include?('operating')
            return :auction if name.include?('auction') || name.include?('initial')

            :other
          end

          def round_key(round, game, kind)
            round_number = first_value(round, :round_num, :round_number, :number)
            turn = first_value(game, :turn, :turn_num)
            id = first_value(round, :id)

            identity = id || [turn, round_number].compact.join('.')
            raise ReplayError, "Cannot identify #{kind} round" if identity.to_s.empty?

            identity.to_s
          end

          def phase_color(game)
            phase = safe_call(game, :phase)
            direct = first_value(phase, :color, :colour)
            direct = normalize_phase_color(direct)
            return direct if direct

            tiles = first_value(phase, :tiles, :tile_colors, :tile_colours)
            colors = Array(tiles).map { |tile| normalize_phase_color(tile) }.compact
            return colors.last if colors.any?

            statuses = first_value(phase, :status)
            colors = Array(statuses).map { |status| normalize_phase_color(status) }.compact
            return colors.last if colors.any?

            raise AmbiguousPhase, "Cannot determine phase colour from #{phase.inspect}"
          end

          def normalize_phase_color(value)
            text = value.to_s.downcase
            text = 'grey' if text == 'gray'
            PHASE_COLOURS.find { |color| text == color || text.include?(color) }
          end

          def load_isolated_game(data)
            game = if @loader
                     @loader.call(data)
                   else
                     unless defined?(Engine::Game) && Engine::Game.respond_to?(:load)
                       raise UnsupportedLoader, 'Engine::Game.load is unavailable'
                     end

                     Engine::Game.load(data)
                   end
            raise ReplayError, 'Replay loader returned no game' unless game

            check_engine_exception!(game, 'load')
            game
          end

          def check_engine_exception!(game, action_id)
            exception = safe_call(game, :exception)
            raise ReplayError, "Engine rejected action #{action_id}: #{exception.class}: #{exception.message}" if exception

            broken = safe_call(game, :broken_action)
            raise ReplayError, "Engine reported broken action #{action_id}" if broken
          end

          def prefix_data(actions, length)
            copy = deep_dup(game_data)
            copy['actions'] = deep_dup(actions.first(length))
            copy
          end

          def raw_actions
            Array(game_data['actions'])
          end

          def raw_players
            Array(game_data['players'])
          end

          def validate_game_data!
            raise ArgumentError, 'game_data must contain players' if raw_players.empty?
            raise ArgumentError, 'game_data must contain actions' if raw_actions.empty?
            raise ArgumentError, 'Every player must have a stable id' if raw_players.any? { |player| value(player, 'id').nil? }
          end

          def parse_timestamp(raw)
            return raw.to_i if raw.is_a?(Numeric)

            text = raw.to_s.strip
            return text.to_i if /^\d+$/.match?(text)

            0 # Require numeric Unix seconds; no browser-specific Date.parse
          end

          def predicate?(object, method_name)
            object && object.respond_to?(method_name) && object.public_send(method_name)
          rescue StandardError
            false
          end

          def safe_call(object, method_name)
            object.public_send(method_name) if object && object.respond_to?(method_name)
          rescue NotImplementedError
            nil
          end

          def first_value(object, *method_names)
            method_names.each do |method_name|
              result = safe_call(object, method_name)
              return result unless result.nil?
            end
            nil
          end

          def entity_id(entity)
            return nil unless entity

            entity.respond_to?(:id) ? entity.id.to_s : entity.to_s
          end

          def value(hash, key)
            hash[key] || hash[key.to_sym]
          end

          def deep_stringify_keys(value)
            case value
            when Hash
              value.each_with_object({}) { |(key, child), result| result[key.to_s] = deep_stringify_keys(child) }
            when Array
              value.map { |child| deep_stringify_keys(child) }
            else
              value
            end
          end

          def deep_dup(value)
            case value
            when Hash
              value.each_with_object({}) { |(key, child), result| result[key] = deep_dup(child) }
            when Array
              value.map { |child| deep_dup(child) }
            else
              value
            end
          end
        end
      end
    end
  end
end
