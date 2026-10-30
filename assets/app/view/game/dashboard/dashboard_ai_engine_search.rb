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

          # To simplify 1846 and other combined track/token steps, evaluate track
          # laying first. This guarantees all potential routes are physically
          # constructed before checking if a token secures them.
          if tiles.any?
            start_engine_tile_search(tiles, actions, entity, @game.round, step)
            return :async
          end

          if tokens.any?
            start_engine_token_search(tokens, [], actions, entity, @game.round, step)
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

        def engine_tile_candidate_key(action)
          tile_name = if action.tile.respond_to?(:name)
                        action.tile.name.to_s
                      else
                        action.tile.id.to_s.sub(/-\d+\z/, '')
                      end
          [action.hex.id.to_s, tile_name, action.rotation.to_i]
        end

        def engine_log_tile_candidate_list(label, actions)
          list = Array(actions).select { |action| action.is_a?(Engine::Action::LayTile) }
          grouped = {}
          list.each do |action|
            hex_id, tile_name, rotation = engine_tile_candidate_key(action)
            grouped[hex_id] ||= {}
            grouped[hex_id][tile_name] ||= []
            grouped[hex_id][tile_name] << rotation
          end

          unique_keys = list.map { |action| engine_tile_candidate_key(action) }.uniq
          LOGGER.info("========== #{label} ==========")
          grouped.keys.sort.each do |hex_id|
            LOGGER.info(hex_id.to_s)
            hex_total = 0
            grouped[hex_id].keys.sort.each do |tile_name|
              rotations = grouped[hex_id][tile_name].sort
              unique_rotations = rotations.uniq
              duplicates = rotations.size - unique_rotations.size
              suffix = duplicates.positive? ? " duplicates=#{duplicates}" : ''
              LOGGER.info(
                "  tile #{tile_name}: rotations #{unique_rotations.join(',')}" \
                " raw=#{rotations.size} unique=#{unique_rotations.size}#{suffix}"
              )
              hex_total += unique_rotations.size
            end
            LOGGER.info("  total unique: #{hex_total}")
          end
          LOGGER.info(
            "SUMMARY raw=#{list.size} unique_hex_tile_rotation=#{unique_keys.size} " \
            "duplicates=#{list.size - unique_keys.size}"
          )
          LOGGER.info("========== END #{label} ==========")
        rescue StandardError => e
          LOGGER.warn("[AI TILE DIAGNOSTIC] #{label} failed: #{e.class}: #{e.message}")
        end

        def start_engine_tile_search(actions, all_actions, entity, round_before, step_before)
          `document.body.style.cursor = 'progress'`
          engine_log_tile_candidate_list('AI TILE RAW CANDIDATES', actions)
          state = {
            legality_deadline: engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS,
            all_actions: all_actions,
            unchecked_actions: actions,
            verification_index: 0,
            legal_actions: [],
            verified_games: {},
            rejected_count: 0,
            rejected_actions: [],
            results: [],
          }
          engine_verify_next_tile(state, entity, round_before, step_before)
        end

        # Phase 1: engine legality only. No route search or revenue evaluation is
        # started until every retained candidate has passed process_action on a clone.
        def engine_verify_next_tile(state, entity, round_before, step_before)
          if engine_now_ms >= state[:legality_deadline] ||
             state[:verification_index] >= state[:unchecked_actions].size
            return engine_begin_legal_tile_search(state, entity, round_before, step_before)
          end

          action = state[:unchecked_actions][state[:verification_index]]
          state[:verification_index] += 1

          begin
            trial = clone_and_process(@game, action)
            state[:legal_actions] << action
            state[:verified_games][action.object_id] = trial
          rescue StandardError => e
            state[:rejected_count] += 1
            state[:rejected_actions] << {
              action: action,
              error_class: e.class.name.to_s,
              error_message: e.message.to_s,
            }
          end

          `setTimeout(function () { #{engine_verify_next_tile(state, entity, round_before, step_before)} }, 0)`
        end

        def engine_begin_legal_tile_search(state, entity, round_before, step_before)
          LOGGER.info(
            "[AI TILE LEGALITY] candidates=#{state[:unchecked_actions].size} " \
            "engine_legal=#{state[:legal_actions].size} rejected=#{state[:rejected_count]}"
          )
          engine_log_tile_candidate_list('AI TILE ENGINE-VERIFIED CANDIDATES', state[:legal_actions])
          unless state[:rejected_actions].empty?
            LOGGER.info('========== AI TILE REJECTED CANDIDATES ==========')
            state[:rejected_actions].sort_by do |item|
              engine_tile_candidate_key(item[:action])
            end.each do |item|
              action = item[:action]
              hex_id, tile_name, rotation = engine_tile_candidate_key(action)
              LOGGER.info(
                "#{hex_id} tile #{tile_name} rotation #{rotation}: " \
                "#{item[:error_class]}: #{item[:error_message]}"
              )
            end
            LOGGER.info('========== END AI TILE REJECTED CANDIDATES ==========')
          end

          if state[:legal_actions].empty?
            pass = Array(state[:all_actions]).find do |candidate|
              candidate.is_a?(Engine::Action::Pass)
            end
            if pass
              LOGGER.info('[AI TILE LEGALITY] no legal tile; using Pass')
              return engine_finish(pass, round_before, step_before, entity)
            end

            LOGGER.warn('[AI TILE LEGALITY] no legal tile and no Pass available')
            return engine_finish(nil, round_before, step_before, entity)
          end

          # Compute topology/revenue hints only after engine legality has been
          # established. Illegal and unaffordable candidates never reach this work.
          @tile_eval_cache ||= {}
          topology_deadline = engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS
          state[:legal_actions].each do |action|
            break if engine_now_ms >= topology_deadline

            cost = calculate_tile_cost(
              step_before,
              entity,
              action.hex,
              action.tile,
            )
            metrics = trial_and_evaluate_tile(
              step_before,
              entity,
              action.hex,
              action.tile,
              action.rotation,
              cost,
              topology_deadline,
            )
            @tile_eval_cache[action] = metrics if metrics
          end

          # Give AutoRouter revenue evaluation its own full budget after legality
          # and topology filtering.
          state[:deadline] = engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS
          state[:first_actions] = state[:legal_actions]
          state[:first_index] = 0
          LOGGER.info(
            "[AI TILE SEARCH] evaluating revenue for #{state[:legal_actions].size} legal candidates"
          )
          engine_next_first_tile(state, entity, round_before, step_before)
        end

        def engine_next_first_tile(state, entity, round_before, step_before)
          if engine_now_ms >= state[:deadline] || state[:first_index] >= state[:first_actions].size
            return engine_finish_tile_search(state, entity, round_before, step_before)
          end

          action = state[:first_actions][state[:first_index]]
          state[:first_index] += 1
          first_game = state[:verified_games][action.object_id]
          return engine_next_first_tile(state, entity, round_before, step_before) unless first_game

          label = "first hex=#{action.hex.id} tile=#{action.tile.id} rotation=#{action.rotation}"
          engine_route_revenue(first_game, entity, state[:deadline], label) do |first_revenue|
            unless first_revenue
              engine_next_first_tile(state, entity, round_before, step_before)
              next
            end

            topology_metrics = @tile_eval_cache && @tile_eval_cache[action]
            topology_revenue = topology_metrics ? topology_metrics[:projected_revenue].to_i : 0
            result = {
              action: action,
              first_revenue: first_revenue,
              best_revenue: first_revenue,
              topology_revenue: topology_revenue,
              best_second: nil,
            }
            state[:results] << result

            LOGGER.info(
              "[AI TILE RESULT] hex=#{action.hex.id} tile=#{action.tile.id} " \
              "rotation=#{action.rotation} first=#{first_revenue} " \
              "engine_two=#{result[:best_revenue]} topology_two=#{topology_revenue} second="
            )

            # Do NOT recursively clone the game for second-tile engine verification.
            # Doing so causes a combinatorial explosion that exhausts the 5-second
            # search budget on the very first candidate, forcing a premature fallback.
            # Rely entirely on the fast topological two-build lookahead (topology_revenue)
            # to break ties among candidates that maintain immediate engine revenue.
            engine_next_first_tile(state, entity, round_before, step_before)

            # begin
            #   # Safely instantiate a new AI player against the cloned game state
            #   # to materialise all legal follow-up tile lays.
            #   first_player = self.class.new(first_game, []) { |_a| }
            #   second_actions = first_player.generate_legal_actions.select do |candidate|
            #     candidate.is_a?(Engine::Action::LayTile)
            #   end

            #   engine_next_second_tile(
            #     state, result, first_game, second_actions, 0,
            #     entity, round_before, step_before
            #   )
            # rescue StandardError => e
            #   LOGGER.warn("[AI TILE SEARCH] Second-tile generation failed: #{e.message}")
            #   engine_next_first_tile(state, entity, round_before, step_before)
            # end
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

        # Shadow two-ply diagnostic stage 1. These methods do not alter
        # production tile selection or submit a second tile action.
        def engine_shadow_track_step(game)
          steps = Array(game.round&.steps)

          LOGGER.info('[AI 2PLY SHADOW STEPS]')
          steps.each do |candidate|
            LOGGER.info(
              "[AI 2PLY SHADOW STEP] class=#{candidate.class.name} " \
              "upgradeable_tiles=#{candidate.respond_to?(:upgradeable_tiles)} " \
              "potential_tiles=#{candidate.respond_to?(:potential_tiles)}"
            )
          end

          track_step = steps.find do |candidate|
            next false if candidate.is_a?(Engine::Step::SpecialTrack)

            candidate.is_a?(Engine::Step::Track)
          end

          if track_step
            LOGGER.info("[AI 2PLY SHADOW TRACK STEP] class=#{track_step.class.name}")
          else
            LOGGER.warn('[AI 2PLY SHADOW TRACK STEP] normal Engine::Step::Track not found')
          end

          track_step
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY SHADOW TRACK STEP] failed: #{e.class}: #{e.message}")
          nil
        end

        def engine_shadow_second_candidates(first_game, original_entity, first_action = nil)
          entity = matching_entity(first_game, original_entity)
          return [] unless entity

          step = engine_shadow_track_step(first_game)
          return [] unless step

          candidates = []
          first_label = if first_action
                          "#{first_action.hex.id}/#{first_action.tile.name}/#{first_action.rotation}"
                        else
                          'unknown'
                        end

          LOGGER.info(
            "[AI 2PLY SHADOW SECOND LIST] after=#{first_label} entity=#{entity.id}"
          )

          Array(first_game.hexes).each do |hex|
            next unless hex

            # Future planning must retain network connectivity and private-company
            # blocking, but bypass get_tile_lay(entity), which is exhausted after
            # the processed first lay. These are the two relevant lower-level
            # checks from Tracker#tracker_available_hex.
            connected = begin
              step.hex_neighbors(entity, hex)
            rescue StandardError => e
              LOGGER.warn(
                '[AI 2PLY SHADOW SECOND] hex_neighbors failed ' \
                "hex=#{hex.id}: #{e.class}: #{e.message}"
              )
              nil
            end
            next unless connected

            blocker = begin
              step.ability_blocking_hex(entity, hex)
            rescue StandardError => e
              LOGGER.warn(
                '[AI 2PLY SHADOW SECOND] ability_blocking_hex failed ' \
                "hex=#{hex.id}: #{e.class}: #{e.message}"
              )
              :unknown
            end
            next if blocker

            tiles = begin
              Array(step.upgradeable_tiles(entity, hex)).compact
            rescue StandardError => e
              LOGGER.warn(
                '[AI 2PLY SHADOW SECOND] upgradeable_tiles failed ' \
                "hex=#{hex.id}: #{e.class}: #{e.message}"
              )
              []
            end
            next if tiles.empty?

            hex_candidates = []
            tiles.each do |tile|
              rotations = Array(tile.legal_rotations).compact.map(&:to_i).uniq.sort
              next if rotations.empty?

              rotations.each do |rotation|
                candidate = {
                  hex_id: hex.id.to_s,
                  tile_name: tile.name.to_s,
                  rotation: rotation.to_i,
                }
                candidates << candidate
                hex_candidates << candidate
              end
            end
            next if hex_candidates.empty?

            LOGGER.info("[AI 2PLY SHADOW SECOND HEX] #{hex.id}")
            hex_candidates.group_by { |candidate| candidate[:tile_name] }
                          .sort_by { |tile_name, _| tile_name }
                          .each do |tile_name, tile_candidates|
              rotations = tile_candidates.map { |candidate| candidate[:rotation] }.uniq.sort
              LOGGER.info(
                "[AI 2PLY SHADOW SECOND TILE] hex=#{hex.id} tile=#{tile_name} " \
                "rotations=#{rotations.join(',')}"
              )
            end
          end

          candidates.uniq! do |candidate|
            [candidate[:hex_id], candidate[:tile_name], candidate[:rotation]]
          end
          candidates.sort_by! do |candidate|
            [candidate[:hex_id], candidate[:tile_name], candidate[:rotation]]
          end

          LOGGER.info(
            "[AI 2PLY SHADOW SECOND SUMMARY] after=#{first_label} " \
            "entity=#{entity.id} candidates=#{candidates.size}"
          )
          candidates
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY SHADOW SECOND] failed: #{e.class}: #{e.message}")
          []
        end

        def engine_shadow_game_with_second_tile(first_game, original_entity, candidate)
          trial_game = first_game.clone(Array(first_game.raw_actions))
          trial_entity = matching_entity(trial_game, original_entity)
          return nil unless trial_entity

          trial_hex = Array(trial_game.hexes).find do |hex|
            hex.id.to_s == candidate[:hex_id].to_s
          end
          return nil unless trial_hex

          supply_tile = Array(trial_game.tiles).find do |tile|
            next false unless tile.name.to_s == candidate[:tile_name].to_s
            next false if tile.respond_to?(:hex) && tile.hex
            next false if trial_game.respond_to?(:tile_available?) && !trial_game.tile_available?(tile)

            true
          end
          return nil unless supply_tile

          trial_tile = clone_tile_for_trial(supply_tile, candidate[:rotation])
          return nil unless trial_tile

          trial_tile.hex = trial_hex if trial_tile.respond_to?(:hex=)
          set_hex_tile_for_trial(trial_hex, trial_tile)

          if trial_game.graph.respond_to?(:clear_graph_for)
            trial_game.graph.clear_graph_for(trial_entity)
          elsif trial_game.graph.respond_to?(:clear)
            trial_game.graph.clear
          end

          trial_game
        rescue StandardError => e
          LOGGER.warn(
            "[AI 2PLY SHADOW APPLY] second=#{candidate[:hex_id]}/" \
            "#{candidate[:tile_name]}/#{candidate[:rotation]} " \
            "failed: #{e.class}: #{e.message}"
          )
          nil
        end

        def engine_shadow_evaluate_next(shadow)
          return engine_shadow_finish_revenue(shadow) if shadow[:index] >= shadow[:jobs].size

          job = shadow[:jobs][shadow[:index]]
          shadow[:index] += 1

          trial_game = engine_shadow_game_with_second_tile(
            job[:first_game],
            shadow[:entity],
            job[:second],
          )

          unless trial_game
            shadow[:complete] = false
            return engine_shadow_evaluate_next(shadow)
          end

          first = job[:first_result][:action]
          second = job[:second]
          label = "shadow first=#{first.hex.id}/#{first.tile.name}/#{first.rotation} " \
                  "second=#{second[:hex_id]}/#{second[:tile_name]}/#{second[:rotation]}"

          engine_route_revenue(
            trial_game,
            shadow[:entity],
            shadow[:deadline],
            label,
          ) do |revenue|
            if revenue.nil?
              shadow[:complete] = false
            else
              pair = {
                first_result: job[:first_result],
                second: second,
                final_revenue: revenue.to_i,
              }
              shadow[:pairs] << pair
              LOGGER.info(
                "[AI 2PLY SHADOW PAIR] first=#{first.hex.id}/#{first.tile.name}/" \
                "#{first.rotation} second=#{second[:hex_id]}/#{second[:tile_name]}/" \
                "#{second[:rotation]} immediate=#{job[:first_result][:best_revenue].to_i} " \
                "final=#{revenue.to_i}"
              )
            end

            engine_shadow_evaluate_next(shadow)
          end
        end

        # T1 diagnostic only: project optional depot-train value on the best
        # post-first and post-second maps. This never changes the buy-train action.
        def engine_train_projection_candidates(game, original_entity)
          entity = matching_entity(game, original_entity)
          return [] unless entity && game.respond_to?(:depot)

          cash = entity.respond_to?(:cash) ? entity.cash.to_i : 0
          limit = game.respond_to?(:train_limit) ? game.train_limit(entity).to_i : 99
          current_count = entity.respond_to?(:trains) ? entity.trains.size : 0
          return [] if current_count >= limit

          trains = if game.depot.respond_to?(:depot_trains)
                     Array(game.depot.depot_trains)
                   elsif game.depot.respond_to?(:upcoming)
                     Array(game.depot.upcoming)
                   else
                     []
                   end

          trains.select do |train|
            train && train.price.to_i <= cash &&
              (train.owner == game.depot ||
               (train.respond_to?(:from_depot?) && train.from_depot?))
          end.uniq { |train| [train.name.to_s, train.price.to_i] }
        rescue StandardError => e
          LOGGER.warn("[AI TRAIN PROJECTION] candidate lookup failed: #{e.class}: #{e.message}")
          []
        end

        def engine_train_projection_game(base_game, original_entity, train_name, train_price)
          game = base_game.clone(Array(base_game.raw_actions))
          entity = matching_entity(game, original_entity)
          return nil unless entity

          train = engine_train_projection_candidates(game, original_entity).find do |candidate|
            candidate.name.to_s == train_name.to_s && candidate.price.to_i == train_price.to_i
          end
          return nil unless train

          train.owner = entity
          entity.trains << train unless entity.trains.include?(train)
          game.graph.clear_graph_for(entity) if game.respond_to?(:graph) && game.graph.respond_to?(:clear_graph_for)
          game
        rescue StandardError => e
          LOGGER.warn(
            "[AI TRAIN PROJECTION] borrow #{train_name} failed: #{e.class}: #{e.message}"
          )
          nil
        end

        def engine_train_projection_next(state)
          if state[:index] >= state[:jobs].size
            LOGGER.info('========== AI TRAIN PROJECTION ==========')
            LOGGER.info(
              "[AI TRAIN PROJECTION BASE] first=#{state[:first_label]} " \
              "post_first=#{state[:first_baseline]} second=#{state[:second_label]} " \
              "post_second=#{state[:second_baseline]}"
            )
            state[:results].sort_by do |result|
              [result[:train_name], result[:price], result[:stage]]
            end.each do |result|
              baseline = result[:baseline].to_i
              gain = result[:revenue].to_i - baseline
              payback = gain.positive? ? (result[:price].to_f / gain).round(2) : nil
              LOGGER.info(
                "[AI TRAIN PROJECTION RESULT] stage=#{result[:stage]} " \
                "train=#{result[:train_name]} price=#{result[:price]} " \
                "baseline=#{baseline} revenue=#{result[:revenue]} gain=#{gain} " \
                "payback_ors=#{payback || 'none'}"
              )
            end
            LOGGER.info('========== END AI TRAIN PROJECTION ==========')
            return engine_finish(
              state[:chosen_action], state[:round_before], state[:step_before], state[:entity],
            )
          end

          job = state[:jobs][state[:index]]
          state[:index] += 1
          trial_game = engine_train_projection_game(
            job[:base_game], state[:entity], job[:train_name], job[:price],
          )
          return engine_train_projection_next(state) unless trial_game

          label = "train_projection stage=#{job[:stage]} train=#{job[:train_name]}"
          engine_route_revenue(trial_game, state[:entity], state[:deadline], label) do |revenue|
            if revenue
              state[:results] << job.merge(revenue: revenue.to_i)
            else
              LOGGER.warn(
                "[AI TRAIN PROJECTION] no revenue stage=#{job[:stage]} " \
                "train=#{job[:train_name]}"
              )
            end
            engine_train_projection_next(state)
          end
        end

        def engine_start_train_projection(shadow, best, chosen_action)
          first_action = best[:first_result][:action]
          first_game = shadow[:jobs].find do |job|
            job[:first_result][:action].equal?(first_action)
          end&.dig(:first_game)
          unless first_game
            return engine_finish(
              chosen_action, shadow[:round_before], shadow[:step_before], shadow[:entity],
            )
          end

          second_game = engine_shadow_game_with_second_tile(
            first_game, shadow[:entity], best[:second],
          )
          unless second_game
            return engine_finish(
              chosen_action, shadow[:round_before], shadow[:step_before], shadow[:entity],
            )
          end

          jobs = []
          [
            ['post_first', first_game, best[:first_result][:best_revenue].to_i],
            ['post_second', second_game, best[:final_revenue].to_i],
          ].each do |stage, game, baseline|
            engine_train_projection_candidates(game, shadow[:entity]).each do |train|
              jobs << {
                stage: stage,
                base_game: game,
                baseline: baseline,
                train_name: train.name.to_s,
                price: train.price.to_i,
              }
            end
          end

          LOGGER.info(
            "[AI TRAIN PROJECTION START] candidates=#{jobs.size} diagnostic_only=true"
          )
          if jobs.empty?
            return engine_finish(
              chosen_action, shadow[:round_before], shadow[:step_before], shadow[:entity],
            )
          end

          engine_train_projection_next(
            jobs: jobs,
            index: 0,
            results: [],
            deadline: engine_now_ms + 20_000,
            chosen_action: chosen_action,
            entity: shadow[:entity],
            round_before: shadow[:round_before],
            step_before: shadow[:step_before],
            first_label: "#{first_action.hex.id}/#{first_action.tile.name}/#{first_action.rotation}",
            second_label: "#{best[:second][:hex_id]}/#{best[:second][:tile_name]}/#{best[:second][:rotation]}",
            first_baseline: best[:first_result][:best_revenue].to_i,
            second_baseline: best[:final_revenue].to_i,
          )
        end

        def engine_shadow_finish_revenue(shadow)
          chosen_action = shadow[:production_action]
          selection_source = 'deterministic_immediate_revenue_fallback'
          best = nil

          if shadow[:pairs].empty?
            LOGGER.warn(
              '[AI 2PLY RESULT] no pair revenue completed; ' \
              "jobs=#{shadow[:jobs].size} complete=#{shadow[:complete]}"
            )
          else
            best = shadow[:pairs].sort_by do |pair|
              first = pair[:first_result][:action]
              second = pair[:second]
              [
                -pair[:final_revenue].to_i,
                -pair[:first_result][:best_revenue].to_i,
                first.hex.id.to_s,
                first.tile.name.to_s,
                first.rotation.to_i,
                second[:hex_id].to_s,
                second[:tile_name].to_s,
                second[:rotation].to_i,
              ]
            end.first

            first = best[:first_result][:action]
            second = best[:second]
            production_revenue = shadow[:production_revenue].to_i
            two_ply_revenue = best[:final_revenue].to_i

            # Promote two-ply only when the full tree completed and it strictly
            # improves on the production single-ply revenue. On a tie, retain the
            # known-good immediate-revenue choice.
            if shadow[:complete] && two_ply_revenue > production_revenue
              chosen_action = first
              selection_source = 'deterministic_two_ply'
            end

            LOGGER.info('========== AI 2PLY REVENUE RESULT ==========')
            LOGGER.info(
              "[AI 2PLY BEST] first=#{first.hex.id}/#{first.tile.name}/" \
              "#{first.rotation} second=#{second[:hex_id]}/#{second[:tile_name]}/" \
              "#{second[:rotation]} immediate=#{best[:first_result][:best_revenue].to_i} " \
              "final=#{two_ply_revenue} complete=#{shadow[:complete]}"
            )
            LOGGER.info(
              "[AI 2PLY DECISION] production=#{shadow[:production_action].hex.id}/" \
              "#{shadow[:production_action].tile.name}/#{shadow[:production_action].rotation} " \
              "production_revenue=#{production_revenue} chosen=#{chosen_action.hex.id}/" \
              "#{chosen_action.tile.name}/#{chosen_action.rotation} " \
              "selection_source=#{selection_source}"
            )
            LOGGER.info('========== END AI 2PLY REVENUE RESULT ==========')
          end

          if best
            engine_start_train_projection(shadow, best, chosen_action)
          else
            engine_finish(
              chosen_action,
              shadow[:round_before],
              shadow[:step_before],
              shadow[:entity],
            )
          end
        end

        def engine_finish_tile_search(state, entity, round_before, step_before)
          completed = state[:results]
          if completed.empty?
            fallback = Array(state[:legal_actions]).sort_by do |action|
              [action.hex.id.to_s, action.tile.name.to_s, action.rotation.to_i]
            end.first
            if fallback
              LOGGER.warn('[AI TILE SEARCH] no revenue result; using deterministic engine-verified fallback')
              return engine_finish(fallback, round_before, step_before, entity)
            end

            pass = Array(state[:all_actions]).find { |candidate| candidate.is_a?(Engine::Action::Pass) }
            return engine_finish(pass, round_before, step_before, entity) if pass

            LOGGER.warn('[AI TILE SEARCH] no legal tile and no Pass available')
            return engine_finish(nil, round_before, step_before, entity)
          end

          # Immediate engine revenue is authoritative. Topology is used only to
          # break equal-revenue ties. No expert-rule randomness or cost penalty.
          winner = completed.sort_by do |result|
            action = result[:action]
            topology = (@tile_eval_cache && @tile_eval_cache[action]) || {}
            [
              -result[:best_revenue].to_i,
              -result[:topology_revenue].to_i,
              -topology[:horizon_2_value].to_i,
              -topology[:horizon_1_value].to_i,
              action.hex.id.to_s,
              action.tile.name.to_s,
              action.rotation.to_i,
            ]
          end.first

          action = winner[:action]
          topology = (@tile_eval_cache && @tile_eval_cache[action]) || {}
          LOGGER.info(
            "[AI TILE CHOSEN] hex=#{action.hex.id} tile=#{action.tile.id} " "rotation=#{action.rotation} selection_source=deterministic_immediate_revenue " "engine_revenue=#{winner[:best_revenue].to_i} " "topology_revenue=#{winner[:topology_revenue].to_i} " "horizon2=#{topology[:horizon_2_value].to_i} " "horizon1=#{topology[:horizon_1_value].to_i} cost_penalty=disabled"
          )
          # Build and brute-force the complete two-ply shadow queue. This remains
          # diagnostic only: engine_shadow_finish_revenue always executes +action+,
          # the production single-ply winner.
          jobs = []
          first_branches = 0
          LOGGER.info('========== AI 2PLY SHADOW TREE ==========')
          completed.sort_by do |result|
            first = result[:action]
            [first.hex.id.to_s, first.tile.name.to_s, first.rotation.to_i]
          end.each do |result|
            first = result[:action]
            first_game = state[:verified_games][first.object_id]
            next unless first_game

            second_candidates = engine_shadow_second_candidates(first_game, entity, first)
            first_branches += 1
            LOGGER.info(
              "[AI 2PLY SHADOW BRANCH] first=#{first.hex.id}/#{first.tile.name}/" \
              "#{first.rotation} immediate=#{result[:best_revenue].to_i} " \
              "second_candidates=#{second_candidates.size}"
            )
            second_candidates.each do |second|
              jobs << {
                first_result: result,
                first_game: first_game,
                second: second,
              }
            end
          end

          LOGGER.info(
            "[AI 2PLY SHADOW TREE SUMMARY] first_branches=#{first_branches} " \
            "structural_pairs=#{jobs.size} production_choice=" \
            "#{action.hex.id}/#{action.tile.name}/#{action.rotation}"
          )
          LOGGER.info('========== END AI 2PLY SHADOW TREE ==========')

          return engine_finish(action, round_before, step_before, entity) if jobs.empty?

          shadow = {
            jobs: jobs,
            index: 0,
            pairs: [],
            complete: true,
            deadline: engine_now_ms + 30_000,
            production_action: action,
            production_revenue: winner[:best_revenue].to_i,
            entity: entity,
            round_before: round_before,
            step_before: step_before,
          }
          engine_shadow_evaluate_next(shadow)
        end

        def start_engine_token_search(actions, tile_actions, all_actions, entity, round_before, step_before)
          deadline = engine_now_ms + ENGINE_SEARCH_TIMEOUT_MS
          baseline_game = @game.clone(Array(@game.raw_actions))
          engine_route_revenue(baseline_game, entity, deadline, 'token baseline') do |baseline|
            state = {
              deadline: deadline,
              baseline: baseline.to_i,
              actions: actions,
              tile_actions: tile_actions,
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
            result[:revenue].to_i > state[:baseline].to_i
          end

          unless profitable.empty?
            winner = profitable.sort_by do |result|
              action = result[:action]
              [
                -result[:revenue].to_i,
                action.city.hex.id.to_s,
                action.city.id.to_s,
                action.slot.to_i,
              ]
            end.first

            gain = winner[:revenue].to_i - state[:baseline].to_i
            LOGGER.info(
              "[AI TOKEN CHOSEN] hex=#{winner[:action].city.hex.id} " "city=#{winner[:action].city.id} slot=#{winner[:action].slot} " "baseline=#{state[:baseline].to_i} revenue=#{winner[:revenue].to_i} " "gain=#{gain} selection_source=deterministic_revenue"
            )
            return engine_finish(winner[:action], round_before, step_before, entity)
          end

          if Array(state[:tile_actions]).any?
            LOGGER.info(
              '[AI TOKEN] no legal affordable marker strictly increases revenue ' "above baseline=#{state[:baseline].to_i}; continuing to tile search"
            )
            return start_engine_tile_search(
              state[:tile_actions], state[:all_actions], entity, round_before, step_before,
            )
          end

          pass_action = state[:all_actions].find { |action| action.is_a?(Engine::Action::Pass) }
          if pass_action
            LOGGER.info(
              '[AI TOKEN] no legal affordable marker strictly increases revenue ' "above baseline=#{state[:baseline].to_i}; using Pass"
            )
            return engine_finish(pass_action, round_before, step_before, entity)
          end

          # Mandatory token placement, such as a home token: choose the highest
          # revenue legal processed result deterministically even without a gain.
          unless state[:results].empty?
            winner = state[:results].sort_by do |result|
              action = result[:action]
              [
                -result[:revenue].to_i,
                action.city.hex.id.to_s,
                action.city.id.to_s,
                action.slot.to_i,
              ]
            end.first

            LOGGER.warn(
              "[AI TOKEN FALLBACK] forced placement hex=#{winner[:action].city.hex.id} " "city=#{winner[:action].city.id} slot=#{winner[:action].slot} " "baseline=#{state[:baseline].to_i} revenue=#{winner[:revenue].to_i}"
            )
            return engine_finish(winner[:action], round_before, step_before, entity)
          end

          LOGGER.warn('[AI TOKEN] no valid marker, no tile, no pass. AI blocked.')
          engine_finish(nil, round_before, step_before, entity)
        end
      end
    end
  end
end
