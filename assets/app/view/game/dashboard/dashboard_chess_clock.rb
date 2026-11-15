# frozen_string_literal: true

# Dashboard-only deterministic chess-clock accounting.
#
# This file deliberately has no Snabberb, DOM, storage, or engine mutations.
# It is the production accounting core. A later adapter will replay the game and
# supply one Transition for the state immediately after each server action.
module View
  module Game
    module Dashboard
      module ChessClock
        VERSION = 2

        class Error < StandardError; end
        class InvalidTransition < Error; end
        class NonMonotonicTimestamp < Error; end
        class UnknownPlayer < Error; end

        Config = Struct.new(
          :initial_bank,
          :stock_round_bonus,
          :yellow_or_bonus,
          :green_or_bonus,
          :brown_or_bonus,
          :grey_or_bonus,
          keyword_init: true
        ) do
          def self.default
            new(
              initial_bank: 5 * 60,
              stock_round_bonus: 2 * 60,
              yellow_or_bonus: 30,
              green_or_bonus: 60,
              brown_or_bonus: 30,
              grey_or_bonus: 30
            )
          end

          # The replay adapter must supply the historical phase colour, not
          # the engine's numeric phase name (such as "3" or "4").
          def operating_bonus(phase_color)
            case phase_color.to_s.downcase
            when 'yellow' then yellow_or_bonus
            when 'green' then green_or_bonus
            when 'brown' then brown_or_bonus
            when 'grey', 'gray' then grey_or_bonus
            else
              raise ArgumentError, "Unknown operating phase colour: #{phase_color.inspect}"
            end
          end

          def validate!
            values = [
              initial_bank,
              stock_round_bonus,
              yellow_or_bonus,
              green_or_bonus,
              brown_or_bonus,
              grey_or_bonus,
            ]
            raise ArgumentError, 'Clock values must be non-negative integers' unless values.all? do |v|
                                                                                       v.is_a?(Integer) && v >= 0
                                                                                     end

            self
          end
        end

        # State immediately after one authoritative top-level server action.
        # Nested auto_actions are replayed by the adapter but do not get their
        # own Transition or timestamp.
        Transition = Struct.new(
          :sequence,
          :action_id,
          :timestamp,
          :action_type,
          :responsible_player_id,
          :round_kind,
          :round_key,
          :operating_entity_id,
          :phase_color,
          :finished,
          keyword_init: true
        ) do
          def normalized
            self.class.new(
              sequence: sequence.to_i,
              action_id: action_id.nil? ? nil : action_id.to_s,
              timestamp: timestamp.to_i,
              action_type: action_type.to_s,
              responsible_player_id: blank?(responsible_player_id) ? nil : responsible_player_id.to_s,
              round_kind: normalize_round_kind(round_kind),
              round_key: blank?(round_key) ? nil : round_key.to_s,
              operating_entity_id: blank?(operating_entity_id) ? nil : operating_entity_id.to_s,
              phase_color: phase_color.nil? ? nil : phase_color.to_s.downcase,
              finished: finished == true,
            )
          end

          def clockable?
            timestamp.to_i.positive? && action_type.to_s != 'message'
          end

          private

          def blank?(value)
            value.nil? || value.to_s.empty?
          end

          def normalize_round_kind(value)
            key = value.to_s.downcase
            return :stock if %w[stock sr].include?(key)
            return :operating if %w[operating or].include?(key)
            return :auction if %w[auction initial].include?(key)
            return :finished if key == 'finished'

            key.empty? ? :other : key.to_sym
          end
        end

        Entry = Struct.new(
          :sequence,
          :action_id,
          :timestamp,
          :event,
          :player_id,
          :seconds,
          :round_key,
          :entity_key,
          :reason,
          keyword_init: true
        ) do
          def canonical
            [
              sequence,
              action_id,
              timestamp,
              event,
              player_id,
              seconds,
              round_key,
              entity_key,
              reason,
            ].map { |v| v.nil? ? '-' : v.to_s }.join('|')
          end
        end

        Result = Struct.new(
          :balances,
          :active_player_id,
          :last_action_id,
          :last_server_timestamp,
          :round_key,
          :operating_entity_id,
          :awarded_allowances,
          :entries,
          :finished,
          :warnings,
          :checksum,
          keyword_init: true
        ) do
          def balance_for(player_or_id)
            id = player_or_id.respond_to?(:id) ? player_or_id.id : player_or_id
            balances[id.to_s]
          end

          def projected_balance(player_or_id, elapsed_seconds)
            id = player_or_id.respond_to?(:id) ? player_or_id.id.to_s : player_or_id.to_s
            base = balances[id]
            return nil if base.nil?
            return base unless !finished && active_player_id == id

            base - [elapsed_seconds.to_i, 0].max
          end
        end

        class Ledger
          attr_reader :config, :player_ids

          def initialize(player_ids:, config: Config.default)
            @player_ids = Array(player_ids).map { |id| normalize_id(id) }.uniq.freeze
            raise ArgumentError, 'At least one player is required' if @player_ids.empty?

            @config = config
            @config.validate!
          end

          def reconstruct(transitions)
            reset
            normalized = Array(transitions).filter_map do |transition|
              value = transition.is_a?(Transition) ? transition : Transition.new(**symbolize_keys(transition))
              value.normalized if value.clockable?
            end
            # Preserve the authoritative input order. Never silently sort
            # malformed sequences into a different clock history.
            normalized.each { |transition| consume(transition) }
            build_result
          end

          private

          def reset
            @balances = player_ids.to_h { |player_id| [player_id, config.initial_bank.to_i] }
            @entries = []
            @awarded = {}
            @warnings = []
            @previous = nil
            @finished = false
          end

          def consume(current)
            validate_transition!(current)

            # The interval after the previous action belongs to the player who
            # was responsible in the replayed state after that action.
            charge_interval(@previous, current) if @previous

            # Allowances begin at this authoritative boundary and are applied
            # before the newly responsible player's next interval is charged.
            grant_stock_round_bonus(current)
            grant_operating_bonus(current)

            @finished ||= current.finished || current.round_kind == :finished
            @previous = current
          end

          def validate_transition!(transition)
            raise InvalidTransition, 'Clockable action after game completion' if @finished
            raise InvalidTransition, 'Transition sequence must be positive' unless transition.sequence.positive?

            if @previous && transition.sequence <= @previous.sequence
              raise InvalidTransition,
                    "Action sequence #{transition.sequence} is not strictly increasing after #{@previous.sequence}"
            end
            raise InvalidTransition, 'Transition timestamp must be positive' unless transition.timestamp.positive?

            if @previous && transition.timestamp < @previous.timestamp
              raise NonMonotonicTimestamp,
                    "Action #{transition.action_id} timestamp #{transition.timestamp} precedes #{@previous.timestamp}"
            end

            player_id = transition.responsible_player_id
            raise UnknownPlayer, "Unknown responsible player #{player_id}" if player_id && !@balances.key?(player_id)

            return unless transition.round_kind == :operating && transition.operating_entity_id && !player_id

            @warnings << "No controlling player for #{transition.operating_entity_id} at action #{transition.action_id}"
          end

          def charge_interval(previous, current)
            seconds = current.timestamp - previous.timestamp
            return if seconds.zero? || previous.finished

            player_id = previous.responsible_player_id
            unless player_id
              @warnings << "Uncharged #{seconds}s after action #{previous.action_id}: no responsible player"
              return
            end

            @balances[player_id] -= seconds
            append_entry(
              current,
              event: :charge,
              player_id: player_id,
              seconds: -seconds,
              round_key: previous.round_key,
              entity_key: previous.operating_entity_id,
              reason: "responsibility after action #{previous.action_id}"
            )
          end

          def grant_stock_round_bonus(current)
            return unless current.round_kind == :stock && current.round_key

            key = "SR:#{current.round_key}"
            return if @awarded[key]

            @awarded[key] = true
            player_ids.each do |player_id|
              seconds = config.stock_round_bonus.to_i
              @balances[player_id] += seconds
              append_entry(
                current,
                event: :allowance,
                player_id: player_id,
                seconds: seconds,
                round_key: current.round_key,
                entity_key: nil,
                reason: key
              )
            end
          end

          def grant_operating_bonus(current)
            return unless current.round_kind == :operating
            return unless current.round_key && current.operating_entity_id

            key = "OR:#{current.round_key}:#{current.operating_entity_id}"
            return if @awarded[key]

            # Mark even an ownerless/receivership operation as seen. Undo must
            # never make the same operating turn eligible for a second bonus.
            @awarded[key] = true
            player_id = current.responsible_player_id
            return unless player_id

            seconds = config.operating_bonus(current.phase_color)
            @balances[player_id] += seconds
            append_entry(
              current,
              event: :allowance,
              player_id: player_id,
              seconds: seconds,
              round_key: current.round_key,
              entity_key: current.operating_entity_id,
              reason: key
            )
          end

          def append_entry(current, event:, player_id:, seconds:, round_key:, entity_key:, reason:)
            @entries << Entry.new(
              sequence: current.sequence,
              action_id: current.action_id,
              timestamp: current.timestamp,
              event: event,
              player_id: player_id,
              seconds: seconds,
              round_key: round_key,
              entity_key: entity_key,
              reason: reason
            )
          end

          def build_result
            current = @previous
            Result.new(
              balances: @balances.dup.freeze,
              active_player_id: @finished ? nil : current&.responsible_player_id,
              last_action_id: current&.action_id,
              last_server_timestamp: current&.timestamp.to_i,
              round_key: current&.round_key,
              operating_entity_id: current&.operating_entity_id,
              awarded_allowances: @awarded.keys.sort.freeze,
              entries: @entries.dup.freeze,
              finished: @finished,
              warnings: @warnings.dup.freeze,
              checksum: checksum
            )
          end

          # 32-bit FNV-1a. Deliberately avoids Digest so the same code works in
          # MRI and Opal. This is a diagnostic agreement checksum, not security.
          def checksum
            payload = [
              "v#{VERSION}",
              player_ids.join(','),
              @entries.map(&:canonical).join("\n"),
              @balances.sort.map { |id, value| "#{id}=#{value}" }.join(','),
              @awarded.keys.sort.join(','),
            ].join("\n")
            hash = 2_166_136_261
            payload.each_byte do |byte|
              hash ^= byte
              hash = (hash * 16_777_619) & 0xffff_ffff
            end
            format('%08x', hash)
          end

          def normalize_id(value)
            id = value.respond_to?(:id) ? value.id : value
            raise ArgumentError, 'Player id cannot be blank' if id.nil? || id.to_s.empty?

            id.to_s
          end

          def symbolize_keys(hash)
            hash.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
          end
        end
      end
    end
  end
end
