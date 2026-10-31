# frozen_string_literal: true

# backtick_javascript: true

# Engine-backed asynchronous planning for DashboardAiPlayer.
# Load this file after dashboard_ai_player.rb.

module View
  module Game
    module Dashboard
      class DashboardAiPlayer
        ENGINE_SEARCH_TIMEOUT_MS = 5_000 unless const_defined?(:ENGINE_SEARCH_TIMEOUT_MS)

        # Compact, corporation-specific topology snapshot used to rank tile lays
        # without cloning the complete Engine::Game. Engine legality and the
        # existing AutoRouter remain authoritative for shortlisted candidates.
        class CompactShadowNetwork
          MAX_ENDPOINTS_PER_HEX = 16
          EDGE_COUNT = 6
          EDGE_BITS = [1, 2, 4, 8, 16, 32].freeze

          class TileState
            attr_reader :name, :rotation, :exit_mask, :connections,
                        :connections_by_endpoint, :stops, :printed_revenue,
                        :city_count, :town_count, :offboard_count, :signature

            def initialize(name, rotation, exit_mask, connections, stops,
                           printed_revenue, city_count, town_count,
                           offboard_count, signature)
              @name = name.to_s
              @rotation = rotation.to_i
              @exit_mask = exit_mask.to_i
              @connections = connections
              @stops = stops
              @printed_revenue = printed_revenue.to_i
              @city_count = city_count.to_i
              @town_count = town_count.to_i
              @offboard_count = offboard_count.to_i
              @signature = signature.to_s
              @connections_by_endpoint = Array.new(MAX_ENDPOINTS_PER_HEX) { [] }
              @connections.each do |pair|
                a = pair[0].to_i
                b = pair[1].to_i
                @connections_by_endpoint[a] << b unless @connections_by_endpoint[a].include?(b)
                @connections_by_endpoint[b] << a unless @connections_by_endpoint[b].include?(a)
              end
            end

            def exits_at?(edge)
              (@exit_mask & EDGE_BITS[edge.to_i]).positive?
            end
          end

          class Stop
            attr_reader :id, :hex_index, :endpoint, :kind, :revenue,
                        :visit_cost, :slot_count, :tokened, :blocked

            def initialize(id, hex_index, endpoint, kind, revenue, visit_cost,
                           slot_count, tokened, blocked)
              @id = id.to_i
              @hex_index = hex_index.to_i
              @endpoint = endpoint.to_i
              @kind = kind.to_sym
              @revenue = revenue.to_i
              @visit_cost = visit_cost.to_i
              @slot_count = slot_count.to_i
              @tokened = !!tokened
              @blocked = !!blocked
            end
          end

          # Preserves the Engine train-distance structure rather than flattening
          # every train to one integer. A 3+3 train therefore remains two groups,
          # for example three paying city/offboard visits plus three paying town
          # visits, subject to the exact distance data supplied by the game.
          class TrainRule
            attr_reader :name, :raw_distance, :groups, :multiplier, :supported

            def initialize(train)
              @name = train.respond_to?(:name) ? train.name.to_s : ''
              @raw_distance = train.respond_to?(:distance) ? train.distance : nil
              @multiplier = if train.respond_to?(:multiplier)
                              train.multiplier.to_i
                            else
                              1
                            end
              @multiplier = 1 unless @multiplier.positive?
              @groups = normalize_distance(@raw_distance)
              @supported = !@groups.empty?
            end

            def grouped?
              @groups.size > 1
            end

            private

            def normalize_distance(distance)
              if distance.is_a?(Numeric)
                return [{
                  nodes: %w[city offboard town],
                  pay: distance.to_i,
                  visit: distance.to_i,
                }]
              end

              collections = if distance.is_a?(Array)
                              distance
                            elsif distance.is_a?(Hash)
                              [distance]
                            else
                              []
                            end

              collections.map do |part|
                next unless part.respond_to?(:[])

                nodes = part[:nodes] || part['nodes'] || part[:node] || part['node']
                pay = part[:pay] || part['pay']
                visit = part[:visit] || part['visit'] || pay
                nodes = Array(nodes).map(&:to_s)
                next if nodes.empty? || pay.nil?

                { nodes: nodes.sort, pay: pay.to_i, visit: visit.to_i }
              end.compact
            end
          end

          Change = Struct.new(:hex_index, :old_tile_state_id, :old_hash)

          attr_reader :hex_ids, :hex_index, :neighbors, :neighbor_edges,
                      :tile_state_ids, :tile_states, :stops, :stops_by_hex,
                      :train_rules, :position_hash, :reachable_stops,
                      :reachable_hexes

          def self.from_game(game, entity, revenue_for = nil)
            network = new
            network.send(:extract_board, game, entity, revenue_for)
            network
          rescue StandardError => e
            LOGGER.warn("[AI COMPACT SHADOW] build failed: #{e.class}: #{e.message}")
            nil
          end

          def initialize
            @hex_ids = []
            @hex_index = {}
            @neighbors = []
            @neighbor_edges = []
            @tile_state_ids = []
            @tile_states = []
            @tile_state_lookup = {}
            @stops = []
            @stops_by_hex = []
            @train_rules = []
            @changes = []
            @reachable_stops = []
            @reachable_hexes = []
            @token_endpoints = []
            @position_hash = 0
            @visited = []
            @queue = []
          end

          def translate_candidate(action, tile_state_id = nil)
            index = @hex_index[action.hex.id.to_s]
            return nil unless index

            state_id = tile_state_id || register_tile_state(action.tile, action.rotation)
            {
              action: action,
              hex_index: index,
              tile_state_id: state_id,
              hex_id: action.hex.id.to_s,
              tile_name: action.tile.name.to_s,
              rotation: action.rotation.to_i,
            }
          rescue StandardError
            nil
          end

          def translate_parts(hex_id, tile, rotation, action = nil)
            index = @hex_index[hex_id.to_s]
            return nil if index.nil? || tile.nil?

            state_id = register_tile_state(tile, rotation)
            {
              action: action,
              hex_index: index,
              tile_state_id: state_id,
              hex_id: hex_id.to_s,
              tile_name: tile.name.to_s,
              rotation: rotation.to_i,
            }
          rescue StandardError => e
            LOGGER.warn("[AI COMPACT SHADOW] candidate failed: #{e.class}: #{e.message}")
            nil
          end

          def estimated_total_revenue
            values = @train_rules.map { |rule| estimated_revenue(rule) }
            return nil if values.empty? || values.any?(&:nil?)

            values.sum
          end

          def apply(candidate)
            hex = candidate[:hex_index].to_i
            new_state = candidate[:tile_state_id].to_i
            old_state = @tile_state_ids[hex]
            @changes << Change.new(hex, old_state, @position_hash)
            @position_hash ^= zobrist(hex, old_state)
            @tile_state_ids[hex] = new_state
            @position_hash ^= zobrist(hex, new_state)
            recompute_reachability
            true
          end

          def undo
            change = @changes.pop
            return false unless change

            @tile_state_ids[change.hex_index] = change.old_tile_state_id
            @position_hash = change.old_hash
            recompute_reachability
            true
          end

          def structural_score(before_stop_ids)
            before = {}
            Array(before_stop_ids).each { |id| before[id.to_i] = true }
            new_stops = @reachable_stops.reject { |id| before[id.to_i] }
            new_objects = new_stops.map { |id| @stops[id] }.compact
            new_cities = new_objects.select { |stop| stop.kind == :city || stop.kind == :offboard }
            new_towns = new_objects.select { |stop| stop.kind == :town }
            rank = if new_cities.any?
                     1
                   elsif new_towns.any?
                     4
                   else
                     7
                   end
            {
              rank: rank,
              new_revenue: new_objects.map(&:revenue).sum,
              new_center_count: new_objects.size,
              new_city_revenue: new_cities.map(&:revenue).sum,
              new_town_revenue: new_towns.map(&:revenue).sum,
            }
          end

          def estimated_revenue(train_rule)
            return nil unless train_rule && train_rule.supported

            available = @reachable_stops.map { |id| @stops[id] }.compact.reject(&:blocked)
            total = 0
            train_rule.groups.each do |group|
              permitted = available.select { |stop| group[:nodes].include?(stop.kind.to_s) }
              values = permitted.map(&:revenue).sort.reverse
              total += values.first(group[:pay]).sum
            end
            total * train_rule.multiplier
          end

          # This is deliberately conservative. Game-specific route bonuses,
          # doubled towns, token rules, pullman rules, hex re-use restrictions,
          # and title overrides remain exact only in the Engine AutoRouter.
          def exact_engine_verification_required?
            true
          end

          def recompute_reachability
            endpoint_capacity = @hex_ids.size * MAX_ENDPOINTS_PER_HEX
            @visited = Array.new(endpoint_capacity, false) if @visited.size != endpoint_capacity
            @visited.fill(false)
            @queue.clear

            @token_endpoints.each do |endpoint|
              next if @visited[endpoint]

              @visited[endpoint] = true
              @queue << endpoint
            end

            cursor = 0
            while cursor < @queue.size
              endpoint = @queue[cursor]
              cursor += 1
              each_neighbor(endpoint) do |neighbor|
                next if @visited[neighbor]

                @visited[neighbor] = true
                @queue << neighbor
              end
            end

            stop_ids = []
            hex_seen = {}
            @stops.each do |stop|
              endpoint = global_endpoint(stop.hex_index, stop.endpoint)
              next unless @visited[endpoint]

              stop_ids << stop.id
              hex_seen[stop.hex_index] = true
            end
            @reachable_stops = stop_ids
            @reachable_hexes = hex_seen.keys
            self
          end

          private

          def extract_board(game, entity, revenue_for)
            hexes = Array(game.hexes).compact
            hexes.each_with_index do |hex, index|
              @hex_ids << hex.id.to_s
              @hex_index[hex.id.to_s] = index
            end
            @neighbors = Array.new(hexes.size) { Array.new(EDGE_COUNT, -1) }
            @neighbor_edges = Array.new(hexes.size) { Array.new(EDGE_COUNT, -1) }
            @stops_by_hex = Array.new(hexes.size) { [] }

            hexes.each_with_index do |hex, index|
              extract_neighbors(hex, index)
              state_id = register_tile_state(hex.tile, tile_rotation(hex.tile), revenue_for)
              @tile_state_ids[index] = state_id
              @position_hash ^= zobrist(index, state_id)
              extract_stops(hex.tile, index, entity, revenue_for)
            end

            trains = entity.respond_to?(:trains) ? Array(entity.trains) : []
            @train_rules = trains.map { |train| TrainRule.new(train) }
            recompute_reachability
          end

          def extract_neighbors(hex, index)
            raw = hex.respond_to?(:neighbors) ? hex.neighbors : {}
            raw.each do |edge, neighbor|
              edge_number = edge.to_i
              next unless edge_number.between?(0, EDGE_COUNT - 1)
              next unless neighbor

              neighbor_index = @hex_index[neighbor.id.to_s]
              next unless neighbor_index

              @neighbors[index][edge_number] = neighbor_index
              @neighbor_edges[index][edge_number] = (edge_number + 3) % EDGE_COUNT
            end
          end

          def register_tile_state(tile, rotation, revenue_for = nil)
            key = [tile.object_id, rotation.to_i]
            existing = @tile_state_lookup[key]
            return existing unless existing.nil?

            old_rotation = tile_rotation(tile)
            tile.rotate!(rotation.to_i) if tile.respond_to?(:rotate!)
            connections = extract_connections(tile)
            exit_mask = extract_exit_mask(tile)
            city_count = tile.respond_to?(:cities) ? Array(tile.cities).size : 0
            town_count = tile.respond_to?(:towns) ? Array(tile.towns).size : 0
            offboard_count = tile.respond_to?(:offboards) ? Array(tile.offboards).size : 0
            revenue = tile_revenue(tile, revenue_for)
            signature = [tile.name.to_s, rotation.to_i, exit_mask,
                         connections.map { |pair| pair.join('-') }.sort.join(',')].join(':')
            state = TileState.new(tile.name, rotation, exit_mask, connections, [],
                                  revenue, city_count, town_count,
                                  offboard_count, signature)
            state_id = @tile_states.size
            @tile_states << state
            @tile_state_lookup[key] = state_id
            state_id
          ensure
            tile.rotate!(old_rotation) if tile && tile.respond_to?(:rotate!) && !old_rotation.nil?
          end

          def extract_connections(tile)
            pairs = []
            endpoint_ids = {}
            next_endpoint = EDGE_COUNT
            Array(tile.respond_to?(:paths) ? tile.paths : []).each do |path|
              endpoints = path.respond_to?(:endpoints) ? Array(path.endpoints) : []
              ids = endpoints.map do |endpoint|
                edge = endpoint.respond_to?(:num) ? endpoint.num : nil
                if !edge.nil? && edge.to_i.between?(0, EDGE_COUNT - 1)
                  edge.to_i
                else
                  key = endpoint.object_id
                  endpoint_ids[key] ||= begin
                    value = next_endpoint
                    next_endpoint += 1
                    value
                  end
                end
              end.uniq
              ids.combination(2) { |a, b| pairs << [a, b] }
            end
            pairs.uniq
          end

          def extract_exit_mask(tile)
            mask = 0
            Array(tile.respond_to?(:exits) ? tile.exits : []).each do |edge|
              number = edge.to_i
              mask |= EDGE_BITS[number] if number.between?(0, EDGE_COUNT - 1)
            end
            mask
          end

          def extract_stops(tile, hex_index, entity, revenue_for)
            groups = [
              [:city, tile.respond_to?(:cities) ? Array(tile.cities) : []],
              [:town, tile.respond_to?(:towns) ? Array(tile.towns) : []],
              [:offboard, tile.respond_to?(:offboards) ? Array(tile.offboards) : []],
            ]
            endpoint = EDGE_COUNT
            groups.each do |kind, nodes|
              nodes.each do |node|
                stop_id = @stops.size
                revenue = node_revenue(node, revenue_for)
                tokened = node_tokened_by?(node, entity)
                slots = node.respond_to?(:slots) ? node.slots.to_i : 0
                stop = Stop.new(stop_id, hex_index, endpoint, kind, revenue, 1,
                                slots, tokened, false)
                @stops << stop
                @stops_by_hex[hex_index] << stop_id
                @token_endpoints << global_endpoint(hex_index, endpoint) if tokened
                endpoint += 1
              end
            end
          end

          def node_tokened_by?(node, entity)
            return false unless node.respond_to?(:tokens)

            Array(node.tokens).compact.any? do |token|
              corporation = token.respond_to?(:corporation) ? token.corporation : nil
              corporation == entity
            end
          end

          def tile_revenue(tile, revenue_for)
            return revenue_for.call(tile).to_i if revenue_for

            nodes = []
            nodes.concat(Array(tile.cities)) if tile.respond_to?(:cities)
            nodes.concat(Array(tile.towns)) if tile.respond_to?(:towns)
            nodes.concat(Array(tile.offboards)) if tile.respond_to?(:offboards)
            nodes.map { |node| node_revenue(node, revenue_for) }.sum
          end

          def node_revenue(node, revenue_for)
            return revenue_for.call(node).to_i if revenue_for
            return 0 unless node.respond_to?(:revenue)

            revenue = node.revenue
            revenue.is_a?(Numeric) ? revenue.to_i : 0
          rescue StandardError
            0
          end

          def tile_rotation(tile)
            tile.respond_to?(:rotation) ? (tile.rotation || 0).to_i : 0
          end

          def global_endpoint(hex_index, local_endpoint)
            (hex_index.to_i * MAX_ENDPOINTS_PER_HEX) + local_endpoint.to_i
          end

          def each_neighbor(endpoint)
            hex = endpoint.to_i / MAX_ENDPOINTS_PER_HEX
            local = endpoint.to_i % MAX_ENDPOINTS_PER_HEX
            state = @tile_states[@tile_state_ids[hex]]
            return unless state

            Array(state.connections_by_endpoint[local]).each do |other_local|
              yield global_endpoint(hex, other_local)
            end
            return unless local < EDGE_COUNT
            return unless state.exits_at?(local)

            adjacent_hex = @neighbors[hex][local]
            return if adjacent_hex.nil? || adjacent_hex.negative?

            adjacent_edge = @neighbor_edges[hex][local]
            adjacent_state = @tile_states[@tile_state_ids[adjacent_hex]]
            return unless adjacent_state && adjacent_state.exits_at?(adjacent_edge)

            yield global_endpoint(adjacent_hex, adjacent_edge)
          end

          def zobrist(hex_index, state_id)
            # Deterministic 32-bit mix suitable for an in-memory transposition key.
            value = ((hex_index.to_i + 1) * 1_103_515_245) ^
                    ((state_id.to_i + 1) * 12_345)
            value & 0x7fff_ffff
          end
        end

        class << self
          def engine_search_locks
            @engine_search_locks ||= {}
          end

          # Separate entry point. Do not alias or replace DashboardAiPlayer.play;
          # Opal cannot reliably alias the singleton method while loading this file.
          def engine_play(game, routes = [], &process_block)
            player = new(game, routes, &process_block)
            step = game.round&.active_step
            entity = if step
                       begin
                         step.current_entity if step.respond_to?(:current_entity)
                       rescue StandardError
                         nil
                       end
                     end
            entity ||= begin
              game.round.current_entity if game.round.respond_to?(:current_entity)
            rescue StandardError
              nil
            end
            entity ||= begin
              game.current_entity if game.respond_to?(:current_entity)
            rescue StandardError
              nil
            end
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

          entity = begin
            step.current_entity if step.respond_to?(:current_entity)
          rescue StandardError
            nil
          end
          entity ||= begin
            @game.round.current_entity if @game.round.respond_to?(:current_entity)
          rescue StandardError
            nil
          end
          entity ||= begin
            @game.current_entity if @game.respond_to?(:current_entity)
          rescue StandardError
            nil
          end
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

          end

          router = Engine::AutoRouter.new(
            game,
            ->(_message) {},
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
            end

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

        def engine_log_tile_candidate_list(_label, _actions)
          # Production quiet mode.
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
            state[:rejected_actions].sort_by do |item|
              engine_tile_candidate_key(item[:action])
            end.each do |item|
              action = item[:action]
              hex_id, tile_name, rotation = engine_tile_candidate_key(action)
            end
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

          steps.each do |candidate|
          end

          track_step = steps.find do |candidate|
            next false if candidate.is_a?(Engine::Step::SpecialTrack)

            candidate.is_a?(Engine::Step::Track)
          end

          LOGGER.warn('[AI 2PLY SHADOW TRACK STEP] normal Engine::Step::Track not found') unless track_step

          track_step
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY SHADOW TRACK STEP] failed: #{e.class}: #{e.message}")
          nil
        end

        def engine_local_endpoint_key(endpoint)
          return ['nil'] unless endpoint

          klass = endpoint.class.name.to_s
          return [klass, endpoint.num.to_i] if endpoint.respond_to?(:num)
          return [klass, endpoint.index.to_i] if endpoint.respond_to?(:index)

          [klass]
        end

        # Cheap signature of only the proposed second tile. This runs before any
        # game clone or graph rebuild. It is deliberately scoped to one first
        # branch, so equivalent second-tile rotations can be collapsed safely
        # without assuming equivalence across different first positions.
        def engine_local_second_signature(tile, hex_id, rotation)
          trial_tile = clone_tile_for_trial(tile, rotation)
          return nil unless trial_tile

          paths = Array(trial_tile.paths).map do |path|
            a = path.respond_to?(:a) ? path.a : nil
            b = path.respond_to?(:b) ? path.b : nil
            [engine_local_endpoint_key(a), engine_local_endpoint_key(b)].sort_by(&:to_s)
          end.sort_by(&:to_s)

          nodes = Array(trial_tile.nodes).map do |node|
            revenue = (node.instance_variable_get(:@revenue) if node.instance_variable_defined?(:@revenue))
            revenue_key = case revenue
                          when Numeric, String, Symbol, NilClass then revenue.to_s
                          when Hash then revenue.keys.map(&:to_s).sort.join(',')
                          else revenue.class.name.to_s
                          end
            [node.class.name.to_s, revenue_key]
          end.sort_by(&:to_s)

          [hex_id.to_s, paths, nodes]
        rescue StandardError => e
          LOGGER.warn(
            "[AI 2PLY LOCAL SIGNATURE] hex=#{hex_id} tile=#{tile&.name} " \
            "rotation=#{rotation} failed: #{e.class}: #{e.message}"
          )
          nil
        end

        def engine_shadow_second_candidates(first_game, original_entity, _first_action = nil)
          entity = matching_entity(first_game, original_entity)
          return [] unless entity

          step = engine_shadow_track_step(first_game)
          return [] unless step

          candidates = []
          Array(first_game.hexes).each do |hex|
            next unless hex

            connected = begin
              step.hex_neighbors(entity, hex)
            rescue StandardError
              nil
            end
            next unless connected

            blocker = begin
              step.ability_blocking_hex(entity, hex)
            rescue StandardError
              :unknown
            end
            next if blocker

            tiles = begin
              Array(step.upgradeable_tiles(entity, hex)).compact
            rescue StandardError
              []
            end

            tiles.each do |tile|
              Array(tile.legal_rotations).compact.map(&:to_i).uniq.sort.each do |rotation|
                candidates << {
                  hex_id: hex.id.to_s,
                  tile_name: tile.name.to_s,
                  tile: tile,
                  rotation: rotation.to_i,
                  local_signature: engine_local_second_signature(tile, hex.id, rotation),
                }
              end
            end
          end

          candidates.uniq do |candidate|
            [candidate[:hex_id], candidate[:tile_name], candidate[:rotation]]
          end.sort_by do |candidate|
            [candidate[:hex_id], candidate[:tile_name], candidate[:rotation]]
          end
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY SECOND] failed: #{e.class}: #{e.message}")
          []
        end

        def engine_shadow_game_with_second_tile(first_game, original_entity, candidate, timings)
          t = engine_now_ms
          trial_game = first_game.clone(Array(first_game.raw_actions))
          timings[:clone_ms] += engine_now_ms - t

          t = engine_now_ms
          trial_entity = matching_entity(trial_game, original_entity)
          timings[:entity_lookup_ms] += engine_now_ms - t
          return nil unless trial_entity

          t = engine_now_ms
          trial_hex = Array(trial_game.hexes).find do |hex|
            hex.id.to_s == candidate[:hex_id].to_s
          end
          unless trial_hex
            timings[:tile_lookup_ms] += engine_now_ms - t
            return nil
          end

          supply_tile = Array(trial_game.tiles).find do |tile|
            next false unless tile.name.to_s == candidate[:tile_name].to_s
            next false if tile.respond_to?(:hex) && tile.hex
            next false if trial_game.respond_to?(:tile_available?) && !trial_game.tile_available?(tile)

            true
          end
          timings[:tile_lookup_ms] += engine_now_ms - t
          return nil unless supply_tile

          t = engine_now_ms
          trial_tile = clone_tile_for_trial(supply_tile, candidate[:rotation])
          timings[:clone_tile_ms] += engine_now_ms - t
          return nil unless trial_tile

          trial_tile.hex = trial_hex if trial_tile.respond_to?(:hex=)
          t = engine_now_ms
          set_hex_tile_for_trial(trial_hex, trial_tile)
          timings[:set_tile_ms] += engine_now_ms - t

          t = engine_now_ms
          if trial_game.graph.respond_to?(:clear_graph_for)
            trial_game.graph.clear_graph_for(trial_entity)
          elsif trial_game.graph.respond_to?(:clear)
            trial_game.graph.clear
          end
          timings[:graph_clear_ms] += engine_now_ms - t

          trial_game
        rescue StandardError => e
          LOGGER.warn(
            "[AI 2PLY SHADOW APPLY] second=#{candidate[:hex_id]}/" \
            "#{candidate[:tile_name]}/#{candidate[:rotation]} " \
            "failed: #{e.class}: #{e.message}"
          )
          nil
        end

        # Build one reusable clone for all second-tile candidates belonging to
        # the same verified first-tile branch.
        def engine_shadow_prepare_branch(shadow, job)
          branch_key = job[:first_game].object_id
          return true if shadow[:branch_key] == branch_key && shadow[:branch_game]

          t = engine_now_ms
          branch_game = job[:first_game].clone(Array(job[:first_game].raw_actions))
          shadow[:timings][:clone_ms] += engine_now_ms - t
          shadow[:branch_clones] += 1

          t = engine_now_ms
          branch_entity = matching_entity(branch_game, shadow[:entity])
          shadow[:timings][:entity_lookup_ms] += engine_now_ms - t
          return false unless branch_entity

          shadow[:branch_key] = branch_key
          shadow[:branch_game] = branch_game
          shadow[:branch_entity] = branch_entity
          true
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY BRANCH CLONE] failed: #{e.class}: #{e.message}")
          shadow[:branch_key] = nil
          shadow[:branch_game] = nil
          shadow[:branch_entity] = nil
          false
        end

        # Temporarily install a detached second tile on the reusable branch clone.
        # The returned context contains everything required for unconditional restore.
        def engine_shadow_apply_second_tile(shadow, candidate)
          trial_hex = nil
          old_tile = nil
          trial_tile = nil
          trial_game = shadow[:branch_game]
          trial_entity = shadow[:branch_entity]
          return nil unless trial_game && trial_entity

          t = engine_now_ms
          trial_hex = Array(trial_game.hexes).find do |hex|
            hex.id.to_s == candidate[:hex_id].to_s
          end
          unless trial_hex
            shadow[:timings][:tile_lookup_ms] += engine_now_ms - t
            return nil
          end

          supply_tile = Array(trial_game.tiles).find do |tile|
            next false unless tile.name.to_s == candidate[:tile_name].to_s
            next false if tile.respond_to?(:hex) && tile.hex
            next false if trial_game.respond_to?(:tile_available?) && !trial_game.tile_available?(tile)

            true
          end
          shadow[:timings][:tile_lookup_ms] += engine_now_ms - t
          return nil unless supply_tile

          old_tile = trial_hex.tile
          return nil unless old_tile

          t = engine_now_ms
          trial_tile = clone_tile_for_trial(supply_tile, candidate[:rotation])
          shadow[:timings][:clone_tile_ms] += engine_now_ms - t
          return nil unless trial_tile

          trial_tile.hex = trial_hex if trial_tile.respond_to?(:hex=)
          t = engine_now_ms
          set_hex_tile_for_trial(trial_hex, trial_tile)
          shadow[:timings][:set_tile_ms] += engine_now_ms - t

          t = engine_now_ms
          if trial_game.graph.respond_to?(:clear_graph_for)
            trial_game.graph.clear_graph_for(trial_entity)
          elsif trial_game.graph.respond_to?(:clear)
            trial_game.graph.clear
          end
          shadow[:timings][:graph_clear_ms] += engine_now_ms - t

          { game: trial_game, entity: trial_entity, hex: trial_hex, old_tile: old_tile, trial_tile: trial_tile }
        rescue StandardError => e
          begin
            set_hex_tile_for_trial(trial_hex, old_tile) if trial_hex && old_tile
            trial_tile.instance_variable_set(:@hex, nil) if trial_tile
            graph = trial_game&.graph
            if graph&.respond_to?(:clear_graph_for) && trial_entity
              graph.clear_graph_for(trial_entity)
            elsif graph&.respond_to?(:clear)
              graph.clear
            end
          rescue StandardError
            # The branch is discarded below; never reuse uncertain state.
          end
          shadow[:branch_key] = nil
          shadow[:branch_game] = nil
          shadow[:branch_entity] = nil
          LOGGER.warn(
            "[AI 2PLY SHADOW APPLY] second=#{candidate[:hex_id]}/" \
            "#{candidate[:tile_name]}/#{candidate[:rotation]} " \
            "failed: #{e.class}: #{e.message}"
          )
          nil
        end

        def engine_shadow_restore_second_tile(shadow, context)
          return unless context

          t = engine_now_ms
          set_hex_tile_for_trial(context[:hex], context[:old_tile])
          context[:trial_tile].instance_variable_set(:@hex, nil) if context[:trial_tile]
          shadow[:timings][:restore_tile_ms] += engine_now_ms - t

          t = engine_now_ms
          graph = context[:game].graph
          if graph.respond_to?(:clear_graph_for)
            graph.clear_graph_for(context[:entity])
          elsif graph.respond_to?(:clear)
            graph.clear
          end
          shadow[:timings][:restore_graph_ms] += engine_now_ms - t
          true
        rescue StandardError => e
          LOGGER.warn("[AI 2PLY RESTORE] failed: #{e.class}: #{e.message}")
          shadow[:complete] = false
          shadow[:branch_key] = nil
          shadow[:branch_game] = nil
          shadow[:branch_entity] = nil
          false
        end

        def engine_shadow_evaluate_next(shadow)
          if engine_now_ms >= shadow[:deadline]
            shadow[:complete] = false
            LOGGER.warn(
              "[AI 2PLY TIMEOUT] evaluated=#{shadow[:pairs].size}/#{shadow[:jobs].size} " \
              "router_calls=#{shadow[:router_calls]}"
            )
            return engine_shadow_finish_revenue(shadow)
          end

          return engine_shadow_finish_revenue(shadow) if shadow[:index] >= shadow[:jobs].size

          job = shadow[:jobs][shadow[:index]]
          shadow[:index] += 1

          unless engine_shadow_prepare_branch(shadow, job)
            shadow[:complete] = false
            return engine_shadow_evaluate_next(shadow)
          end

          context = engine_shadow_apply_second_tile(shadow, job[:second])
          unless context
            shadow[:complete] = false
            return engine_shadow_evaluate_next(shadow)
          end

          first = job[:first_result][:action]
          second = job[:second]
          label = "shadow first=#{first.hex.id}/#{first.tile.name}/#{first.rotation} " \
                  "second=#{second[:hex_id]}/#{second[:tile_name]}/#{second[:rotation]}"
          shadow[:router_calls] += 1
          router_started_at = engine_now_ms

          engine_route_revenue(context[:game], shadow[:entity], shadow[:deadline], label) do |revenue|
            shadow[:timings][:router_ms] += engine_now_ms - router_started_at
            restored = engine_shadow_restore_second_tile(shadow, context)
            unless restored
              shadow[:complete] = false
              return engine_shadow_finish_revenue(shadow)
            end

            if revenue.nil?
              shadow[:complete] = false
            else
              shadow[:pairs] << {
                first_result: job[:first_result],
                second: second,
                final_revenue: revenue.to_i,
              }
            end
            engine_shadow_evaluate_next(shadow)
          end
        end

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
            first_game, shadow[:entity], best[:second], shadow[:timings],
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

            elapsed_ms = engine_now_ms - shadow[:started_at]
            LOGGER.info(
              "[AI 2PLY OPTIMISATION] structural_pairs=#{shadow[:structural_pairs]} " "unique_pairs=#{shadow[:jobs].size} deduplicated=#{shadow[:deduplicated]} " "router_calls=#{shadow[:router_calls]} elapsed_ms=#{elapsed_ms}"
            )
            timings = shadow[:timings]
            measured_ms = timings.values.sum
            total_ms = shadow[:generation_ms].to_i + elapsed_ms
            overhead_ms = [total_ms - shadow[:generation_ms].to_i - measured_ms, 0].max
            LOGGER.info(
              "[AI 2PLY PERFORMANCE] generation_ms=#{shadow[:generation_ms].to_i} " \
              "clone_ms=#{timings[:clone_ms].to_i} " \
              "entity_lookup_ms=#{timings[:entity_lookup_ms].to_i} " \
              "tile_lookup_ms=#{timings[:tile_lookup_ms].to_i} " \
              "clone_tile_ms=#{timings[:clone_tile_ms].to_i} " \
              "set_tile_ms=#{timings[:set_tile_ms].to_i} " \
              "graph_clear_ms=#{timings[:graph_clear_ms].to_i} " \
              "restore_tile_ms=#{timings[:restore_tile_ms].to_i} " \
              "restore_graph_ms=#{timings[:restore_graph_ms].to_i} " \
              "router_ms=#{timings[:router_ms].to_i} overhead_ms=#{overhead_ms.to_i} " \
              "total_ms=#{total_ms.to_i} branch_clones=#{shadow[:branch_clones]} " \
              "structural_pairs=#{shadow[:structural_pairs]} " \
              "unique_pairs=#{shadow[:jobs].size} evaluated_pairs=#{shadow[:pairs].size} " \
              "router_calls=#{shadow[:router_calls]}"
            )
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
          end

          if best && shadow[:complete]
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

        COMPACT_SHADOW_PAIR_LIMIT = 12 unless const_defined?(:COMPACT_SHADOW_PAIR_LIMIT)

        def engine_compact_shadow_shortlist(jobs, entity)
          return jobs if jobs.size <= COMPACT_SHADOW_PAIR_LIMIT

          network = CompactShadowNetwork.from_game(@game, entity, ->(node) { printed_hex_revenue(node) })
          return jobs unless network

          base = network.reachable_stops.dup
          scored = jobs.each_with_index.map do |job, index|
            first_action = job[:first_result][:action]
            first = network.translate_candidate(first_action)
            data = job[:second]
            second = network.translate_parts(data[:hex_id], data[:tile], data[:rotation])
            next unless first && second
            next if first[:hex_index] == second[:hex_index]

            network.apply(first)
            first_score = network.structural_score(base)
            first_reachable = network.reachable_stops.dup
            network.apply(second)
            second_score = network.structural_score(first_reachable)
            estimate = network.estimated_total_revenue
            network.undo
            network.undo
            {
              job: job,
              index: index,
              key: [first_score[:rank].to_i, second_score[:rank].to_i,
                    -estimate.to_i, -second_score[:new_revenue].to_i,
                    -first_score[:new_revenue].to_i,
                    -job[:first_result][:best_revenue].to_i, index],
            }
          rescue StandardError => e
            network.undo while network.instance_variable_get(:@changes)&.any?
            LOGGER.warn("[AI COMPACT SHADOW] pair failed: #{e.class}: #{e.message}")
            nil
          end.compact
          return jobs if scored.empty?

          groups = scored.group_by { |item| item[:job][:first_result][:action].object_id }
          limit = [COMPACT_SHADOW_PAIR_LIMIT, groups.size].max
          selected = groups.values.map { |items| items.min_by { |item| item[:key] } }
          ids = {}
          selected.each { |item| ids[item[:index]] = true }
          scored.sort_by { |item| item[:key] }.each do |item|
            break if selected.size >= limit
            next if ids[item[:index]]

            selected << item
            ids[item[:index]] = true
          end
          selected.sort_by! { |item| item[:key] }
          LOGGER.info(
            "[AI COMPACT SHADOW] pairs=#{jobs.size} shortlisted=#{selected.size} " "limit=#{limit} trains=#{network.train_rules.map(&:name).join(',')} " "grouped_trains=#{network.train_rules.count(&:grouped?)}"
          )
          selected.map { |item| item[:job] }
        rescue StandardError => e
          LOGGER.warn("[AI COMPACT SHADOW] shortlist failed: #{e.class}: #{e.message}")
          jobs
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
          generation_started_at = engine_now_ms
          jobs = []
          structural_pairs = 0
          deduplicated = 0
          same_hex_rejected = 0

          completed.sort_by do |result|
            first = result[:action]
            [
              -result[:best_revenue].to_i,
              -result[:topology_revenue].to_i,
              first.hex.id.to_s,
              first.tile.name.to_s,
              first.rotation.to_i,
            ]
          end.each do |result|
            first = result[:action]
            first_game = state[:verified_games][first.object_id]
            next unless first_game

            candidates = engine_shadow_second_candidates(first_game, entity, first)
            structural_pairs += candidates.size
            seen = {}
            candidates.each do |second|
              if second[:hex_id].to_s == first.hex.id.to_s
                same_hex_rejected += 1
                next
              end

              key = second[:local_signature]
              key ||= [second[:hex_id], second[:tile_name], second[:rotation]]
              if seen.key?(key)
                deduplicated += 1
                next
              end
              seen[key] = true
              jobs << {
                first_result: result,
                first_game: first_game,
                second: second,
              }
            end
          end

          pre_shortlist_jobs = jobs.size
          jobs = engine_compact_shadow_shortlist(jobs, entity)
          shadow_pruned = pre_shortlist_jobs - jobs.size
          generation_ms = engine_now_ms - generation_started_at

          LOGGER.info(
            "[AI 2PLY TREE] first_branches=#{completed.size} " \
            "structural_pairs=#{structural_pairs} unique_pairs=#{jobs.size} " \
            "deduplicated=#{deduplicated} same_hex_rejected=#{same_hex_rejected} " \
            "shadow_pruned=#{shadow_pruned} production=" \
            "#{action.hex.id}/#{action.tile.name}/#{action.rotation}"
          )

          return engine_finish(action, round_before, step_before, entity) if jobs.empty?

          started_at = engine_now_ms
          shadow = {
            jobs: jobs,
            index: 0,
            pairs: [],
            complete: true,
            router_calls: 0,
            structural_pairs: structural_pairs,
            deduplicated: deduplicated,
            same_hex_rejected: same_hex_rejected,
            shadow_pruned: shadow_pruned,
            started_at: started_at,
            deadline: started_at + 5_000,
            production_action: action,
            production_revenue: winner[:best_revenue].to_i,
            entity: entity,
            round_before: round_before,
            step_before: step_before,
            generation_ms: generation_ms,
            branch_key: nil,
            branch_game: nil,
            branch_clones: 0,
            branch_entity: nil,
            timings: {
              clone_ms: 0,
              entity_lookup_ms: 0,
              tile_lookup_ms: 0,
              clone_tile_ms: 0,
              set_tile_ms: 0,
              graph_clear_ms: 0,
              restore_tile_ms: 0,
              restore_graph_ms: 0,
              router_ms: 0,
            },
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
            return start_engine_tile_search(
              state[:tile_actions], state[:all_actions], entity, round_before, step_before,
            )
          end

          pass_action = state[:all_actions].find { |action| action.is_a?(Engine::Action::Pass) }
          return engine_finish(pass_action, round_before, step_before, entity) if pass_action

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
