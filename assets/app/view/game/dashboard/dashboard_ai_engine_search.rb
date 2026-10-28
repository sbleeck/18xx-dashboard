# frozen_string_literal: true

# backtick_javascript: true

# Engine-backed asynchronous planning for DashboardAiPlayer.
# Load this file after dashboard_ai_player.rb.

module View
  module Game
    module Dashboard
      class DashboardAiPlayer
        ENGINE_SEARCH_TIMEOUT_MS = 5_000 unless const_defined?(:ENGINE_SEARCH_TIMEOUT_MS)

        class << self
          def engine_search_locks
            @engine_search_locks ||= {}
          end

          # Separate entry point. Do not alias or replace DashboardAiPlayer.play;
          # Opal cannot reliably alias the singleton method while loading this file.
          def engine_play(game, routes = [], &process_block)
            player = new(game, routes, &process_block)
            step = game.round&.active_step
            entity = step ? player.current_acting_entity(step) : nil
            actions = step && entity ? player.generate_legal_actions(step, entity) : []
            use_engine_search = actions.any? do |action|
              action.is_a?(Engine::Action::LayTile) || action.is_a?(Engine::Action::PlaceToken)
            end
            return play(game, routes, &process_block) unless use_engine_search

            key = game.object_id
            return false if engine_search_locks[key]

            engine_search_locks[key] = true
            player.instance_variable_set(:@engine_search_key, key)
            result = player.engine_search_play
            engine_search_locks.delete(key) unless result == :async
            result
          rescue StandardError => e
            engine_search_locks.delete(key) if key
            LOGGER.error("[AI ENGINE SEARCH] startup failed: #{e.message}")
            false
          end

          def complete_engine_search!(key)
            engine_search_locks.delete(key)
          end

          def reset!(game = nil)
            engine_search_locks.clear
            super if defined?(super)
          end
        end

        def engine_search_play
          step = @game.round&.active_step
          return false unless step

          entity = current_acting_entity(step)
          return false unless entity

          actions = generate_legal_actions(step, entity)
          tiles = actions.select { |action| action.is_a?(Engine::Action::LayTile) }
          tokens = actions.select { |action| action.is_a?(Engine::Action::PlaceToken) }

          if tiles.any?
            start_engine_tile_search(tiles, entity, @game.round, step)
            return :async
          end

          if tokens.any?
            start_engine_token_search(tokens, actions, entity, @game.round, step)
            return :async
          end

          false
        rescue StandardError => e
          LOGGER.error("[AI ENGINE SEARCH] dispatch failed: #{e.message}")
          false
        end

        private

        def engine_now_ms
          (Time.now.to_f * 1000.0)
        end

        def clone_and_process(source_game, action)
          trial = source_game.clone(Array(source_game.raw_actions))
          mapped = Engine::Action::Base.action_from_h(action.to_h, trial)
          trial.process_action(mapped, add_auto_actions: true).maybe_raise!
          trial
        end

        def matching_entity(game, entity)
          return game.corporation_by_id(entity.id) if entity.respond_to?(:corporation?) && entity.corporation?
          return game.minor_by_id(entity.id) if entity.respond_to?(:minor?) && entity.minor?
          return game.company_by_id(entity.id) if entity.respond_to?(:company?) && entity.company?
          return game.player_by_id(entity.id) if game.respond_to?(:player_by_id)

          game.current_entity
        end

        def engine_route_revenue(game, entity, deadline_ms, label)
          remaining_seconds = (deadline_ms - engine_now_ms) / 1000.0
          return yield(nil) unless remaining_seconds.positive?

          trial_entity = matching_entity(game, entity)
          return yield(nil) unless trial_entity

          borrowed_train = nil
          borrowed_train_owner = nil

          if game.route_trains(trial_entity).empty?
            borrowed_train = game.depot.min_depot_train

            unless borrowed_train
              LOGGER.warn("[AI ENGINE REVENUE] #{label} no trial train available")
              return yield(nil)
            end

            borrowed_train_owner = borrowed_train.owner
            borrowed_train.owner = trial_entity
            trial_entity.trains << borrowed_train

            LOGGER.info(
              "[AI ENGINE TRAIN] #{label} temporarily using " \
              "#{borrowed_train.name}"
            )
          end

          router = Engine::AutoRouter.new(
            game,
            ->(message) { LOGGER.warn("[AI ROUTER] #{message}") },
          )
          best_revenue = nil
          completed = false

          callback = lambda do |routes|
            revenue = begin
              game.routes_revenue(Array(routes)).to_i
            rescue StandardError
              Array(routes).sum do |route|
                route.respond_to?(:chains) && route.chains.any? ? route.revenue.to_i : 0
              rescue StandardError
                0
              end
            end
            best_revenue = revenue if best_revenue.nil? || revenue > best_revenue

            # AutoRouter can publish improving intermediate results. Only the callback
            # after running=false is final and may advance the candidate state machine.
            next if router.running || completed

            completed = true

            if borrowed_train
              trial_entity.trains.delete(borrowed_train)
              borrowed_train.owner = borrowed_train_owner
              LOGGER.info(
                "[AI ENGINE TRAIN] #{label} returned " \
                "#{borrowed_train.name}"
              )
            end

            log = "[AI ENGINE REVENUE] #{label} revenue=#{best_revenue.to_i}"
            LOGGER.info(log)
            yield(best_revenue.to_i)
          end

          # AutoRouter#route is already asynchronous. The state machine continues
          # from callback, so no JavaScript setTimeout wrapper is needed here.
          begin
            router.compute(
              trial_entity,
              routes: [],
              path_timeout: remaining_seconds,
              route_timeout: remaining_seconds,
              callback: callback,
            )
          rescue StandardError => e
            unless completed
              completed = true

              if borrowed_train
                trial_entity.trains.delete(borrowed_train)
                borrowed_train.owner = borrowed_train_owner
                LOGGER.info(
                  "[AI ENGINE TRAIN] #{label} returned after error " \
                  "#{borrowed_train.name}"
                )
              end

              LOGGER.warn(
                "[AI ROUTER ERROR] #{label} #{e.class}: #{e.message}\n" \
                "#{Array(e.backtrace).first(15).join("\n")}"
              )
              yield(nil)
            end
          end
        end

        def engine_finish(action, round_before, step_before, entity)
          if action && execution_context_unchanged?(round_before, step_before, entity)
            # action still references the live game because only trial actions were
            # reconstructed against clones.
            @process_block.call(action)
          end
        rescue StandardError => e
          LOGGER.error("[AI ENGINE SEARCH] final action failed: #{e.message}")
        ensure
          `document.body.style.cursor = ''`
          self.class.complete_engine_search!(@engine_search_key)
        end

        def start_engine_tile_search(actions, entity, round_before, step_before)
          `document.body.style.cursor = 'progress'`
          state = {
            deadline: engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS,
            first_actions: actions,
            first_index: 0,
            results: [],
          }
          engine_next_first_tile(state, entity, round_before, step_before)
        end

        def engine_next_first_tile(state, entity, round_before, step_before)
          if engine_now_ms >= state[:deadline] || state[:first_index] >= state[:first_actions].size
            return engine_finish_tile_search(state, entity, round_before, step_before)
          end

          action = state[:first_actions][state[:first_index]]
          state[:first_index] += 1
          begin
            first_game = clone_and_process(@game, action)
          rescue StandardError => e
            LOGGER.warn("[AI TILE INVALID] #{action.to_h} #{e.message}")
            return engine_next_first_tile(state, entity, round_before, step_before)
          end

          label = "first hex=#{action.hex.id} tile=#{action.tile.id} rotation=#{action.rotation}"
          engine_route_revenue(first_game, entity, state[:deadline], label) do |first_revenue|
            unless first_revenue
              engine_next_first_tile(state, entity, round_before, step_before)
              next
            end

            topology_metrics = @tile_eval_cache && @tile_eval_cache[action]
            topology_revenue = if topology_metrics
                                 topology_metrics[:projected_revenue].to_i
                               else
                                 0
                               end

            result = {
              action: action,
              first_revenue: first_revenue,
              best_revenue: first_revenue,
              topology_revenue: topology_revenue,
              best_second: nil,
            }

            # Retain the valid first build immediately. The result hash is
            # subsequently updated in place if a better second build is found.
            state[:results] << result

            first_player = self.class.allocate

            first_player.send(:initialize, first_game, []) { |_action| }
            second_actions = first_player.generate_legal_actions.select do |candidate|
              candidate.is_a?(Engine::Action::LayTile)
            end
            engine_next_second_tile(
              state,
              result,
              first_game,
              second_actions,
              0,
              entity,
              round_before,
              step_before,
            )
          end
        end

        def engine_next_second_tile(state, result, first_game, actions, index, entity, round_before, step_before)
          if engine_now_ms >= state[:deadline] || index >= actions.size
            log = "[AI TILE RESULT] hex=#{result[:action].hex.id} tile=#{result[:action].tile.id} " \
                  "rotation=#{result[:action].rotation} first=#{result[:first_revenue]} " \
                  "engine_two=#{result[:best_revenue]} " \
                  "topology_two=#{result[:topology_revenue]} " \
                  "second=#{result[:best_second]}"
            LOGGER.info(log)
            engine_next_first_tile(state, entity, round_before, step_before)
            return
          end

          second_action = actions[index]
          begin
            second_game = clone_and_process(first_game, second_action)
          rescue StandardError
            engine_next_second_tile(
              state, result, first_game, actions, index + 1,
              entity, round_before, step_before,
            )
            return
          end

          label = "second hex=#{second_action.hex.id} tile=#{second_action.tile.id} rotation=#{second_action.rotation}"
          engine_route_revenue(second_game, entity, state[:deadline], label) do |revenue|
            if revenue && revenue > result[:best_revenue]
              result[:best_revenue] = revenue
              result[:best_second] = "#{second_action.hex.id}/#{second_action.tile.id}/#{second_action.rotation}"
            end
            engine_next_second_tile(
              state, result, first_game, actions, index + 1,
              entity, round_before, step_before,
            )
          end
        end

        def engine_finish_tile_search(state, entity, round_before, step_before)
          completed = state[:results]
          if completed.empty?
            LOGGER.warn('[AI TILE SEARCH] no candidate completed before deadline')
            return engine_finish(nil, round_before, step_before, entity)
          end

          best_engine_revenue = completed.map do |result|
            result[:best_revenue].to_i
          end.max

          if best_engine_revenue.positive?
            engine_tied = completed.select do |result|
              result[:best_revenue].to_i == best_engine_revenue
            end

            best_topology_revenue = engine_tied.map do |result|
              result[:topology_revenue].to_i
            end.max

            tied = engine_tied.select do |result|
              result[:topology_revenue].to_i == best_topology_revenue
            end

            selection_source = 'engine_then_topology'
          else
            best_topology_revenue = completed.map do |result|
              result[:topology_revenue].to_i
            end.max

            tied = completed.select do |result|
              result[:topology_revenue].to_i == best_topology_revenue
            end

            selection_source = 'topology_fallback'
          end

          winner = tied.sample
          log = "[AI TILE CHOSEN] hex=#{winner[:action].hex.id} tile=#{winner[:action].tile.id} " \
                "rotation=#{winner[:action].rotation} " \
                "selection_source=#{selection_source} " \
                "engine_revenue=#{winner[:best_revenue]} " \
                "topology_revenue=#{winner[:topology_revenue]} " \
                "ties=#{tied.size} best_second=#{winner[:best_second]}"
          LOGGER.info(log)
          engine_finish(winner[:action], round_before, step_before, entity)
        end

        def start_engine_token_search(actions, all_actions, entity, round_before, step_before)
          deadline = engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS
          baseline_game = @game.clone(Array(@game.raw_actions))
          engine_route_revenue(baseline_game, entity, deadline, 'token baseline') do |baseline|
            state = {
              deadline: deadline,
              baseline: baseline.to_i,
              actions: actions,
              all_actions: all_actions,
              index: 0,
              results: [],
            }
            engine_next_token(state, entity, round_before, step_before)
          end
        end

        def engine_next_token(state, entity, round_before, step_before)
          if engine_now_ms >= state[:deadline] || state[:index] >= state[:actions].size
            return engine_finish_token_search(state, entity, round_before, step_before)
          end

          action = state[:actions][state[:index]]
          state[:index] += 1
          begin
            trial_game = clone_and_process(@game, action)
          rescue StandardError
            return engine_next_token(state, entity, round_before, step_before)
          end

          label = "token city=#{action.city.id} slot=#{action.slot}"
          engine_route_revenue(trial_game, entity, state[:deadline], label) do |revenue|
            state[:results] << { action: action, revenue: revenue } if revenue
            engine_next_token(state, entity, round_before, step_before)
          end
        end

        def engine_finish_token_search(state, entity, round_before, step_before)
          profitable = state[:results].select do |result|
            result[:revenue].to_i > state[:baseline]
          end
          if profitable.any?
            best = profitable.map { |result| result[:revenue] }.max
            tied = profitable.select { |result| result[:revenue] == best }
            winner = tied.sample
            log = "[AI TOKEN CHOSEN] city=#{winner[:action].city.id} slot=#{winner[:action].slot} " \
                  "revenue=#{best} baseline=#{state[:baseline]} ties=#{tied.size}"
            LOGGER.info(log)
            return engine_finish(winner[:action], round_before, step_before, entity)
          end

          pass_action = state[:all_actions].find { |action| action.is_a?(Engine::Action::Pass) }
          LOGGER.info('[AI TOKEN] no placement increases engine revenue')
          engine_finish(pass_action, round_before, step_before, entity)
        end
      end
    end
  end
end
