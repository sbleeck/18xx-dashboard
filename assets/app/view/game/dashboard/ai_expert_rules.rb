# assets/app/view/game/dashboard/ai_expert_rules.rb
# frozen_string_literal: true

module View
  module Game
    module Dashboard
      class AiExpertRules
        @game_overrides = {}

        # Optional registry for title-specific rule overrides (e.g., '1835', '1830').
        def self.register_override(game_title, rules)
          @game_overrides[game_title.to_s] = rules
        end

        def self.rules_for(game)
          title = game&.class&.title || (game.respond_to?(:id) ? game.id : nil)
          overrides = @game_overrides[title.to_s] || []
          overrides + DEFAULT_RULES
        end

        def self.score_action(_action, features, game = nil)
          rules = rules_for(game)
          total_score = 0
          applied_rules = []

          rules.each do |rule|
            next unless matches_condition?(rule[:when], features)

            score = rule[:score_add] || 0
            if rule[:score_per_unit]
              field = rule[:score_per_unit][:field]&.to_sym
              multiplier = rule[:score_per_unit][:multiplier] || 1.0
              val = (features[field] || 0).to_f
              score += (val * multiplier).to_i
            end

            total_score += score
            applied_rules << rule[:id]
          end

          [total_score, applied_rules]
        end

        # Selects one candidate from scored items:
        # 1. Hard vetoes (<= -5000) are removed unless all legal actions were vetoed.
        # 2. If any candidate has a positive score (> 0), negative-scoring actions
        #    (such as Pass at -100 or penalized buys) are excluded so roulette noise
        #    never picks Pass when a genuinely good move exists.
        # 3. If no candidate has a positive score (all <= 0), the highest-scoring
        #    candidate (typically Pass at -100 over bad buys at -400) wins cleanly.
        def self.select_candidate(scored_items, top_window: nil)
          return nil if scored_items.empty?

          valid = scored_items.reject { |item| item[:score] <= -5000 }
          valid = scored_items if valid.empty?

          positive = valid.select { |item| item[:score].positive? }
          if positive.empty?
            max_score = valid.map { |item| item[:score] }.max
            return valid.select { |item| item[:score] == max_score }.sample
          end

          pool = top_window ? positive.first(top_window) : positive
          min_score = pool.map { |item| item[:score] }.min

          weights = pool.map do |item|
            ((item[:score] - min_score) + 10.0)**1.5
          end

          total_weight = weights.sum
          target = rand * total_weight
          acc = 0.0

          pool.each_with_index do |candidate, index|
            acc += weights[index]
            return candidate if target < acc
          end

          pool.last
        end

        # Policy: preserve every generated legal action as a candidate.
        def self.apply_probability_policy(items)
          items
        end

        # Return a reproducible probability decision for one game position.
        # Re-evaluating the same action position does not reroll the decision.
        def self.stable_probability?(game, entity, policy_name, probability)
          key = [
            game&.seed,
            game&.raw_actions&.size,
            game&.turn,
            game&.round&.class&.name,
            entity&.class&.name,
            entity&.id,
            policy_name,
          ].join(':')

          value = key.each_byte.reduce(0) do |memo, byte|
            ((memo * 31) + byte) & 0x7fffffff
          end

          Random.new(value).rand < probability
        end

        def self.issue_shares?(game, entity)
          stable_probability?(
            game,
            entity,
            :issue_shares,
            0.80,
          )
        end

        def self.redeem_shares?(game, entity)
          stable_probability?(
            game,
            entity,
            :redeem_shares,
            0.90,
          )
        end

        # Policy: sell shares in a corporation controlled by this player
        # with 5% probability at each eligible game position.
        def self.sell_own_company_shares?(game, entity)
          stable_probability?(
            game,
            entity,
            :sell_own_company_shares,
            0.05,
          )
        end

        # Policy: sell shares in a corporation controlled by another player
        # with 10% probability at each eligible game position.
        def self.sell_other_company_shares?(game, entity)
          stable_probability?(
            game,
            entity,
            :sell_other_company_shares,
            0.10,
          )
        end

        # Policy: generic choices are intentionally uniform.
        def self.select_uniform_choice(actions)
          choices = actions.select { |action| action.is_a?(Engine::Action::Choose) }
          choices.sample
        end

        # Auction policy:
        # 1. Opening bid at or below original value is strongly preferred.
        # 2. Above original value, willingness to continue decays exponentially.
        # 3. Calibrated with harmonic number H_N across N players so expected
        #    winning price is approximately 1.20x original value.
        def self.select_draft_action(actions, game)
          buy_class =
            (Engine::Action::BuyCompany if defined?(Engine::Action::BuyCompany))

          bid_class =
            (Engine::Action::Bid if defined?(Engine::Action::Bid))

          buys =
            if buy_class
              actions.select { |action| action.is_a?(buy_class) }
            else
              []
            end

          bids =
            if bid_class
              actions.select { |action| action.is_a?(bid_class) }
            else
              []
            end

          passes =
            actions.select do |action|
              action.is_a?(Engine::Action::Pass)
            end

          return nil if buys.empty? && bids.empty?

          if buys.any? && bids.any?
            return buys.sample if rand < 0.50
          elsif buys.any?
            return buys.sample
          end

          return bids.sample if passes.empty?
          return passes.sample if bids.empty?

          bid = bids.sample

          target =
            if bid.respond_to?(:company) && bid.company
              bid.company
            elsif bid.respond_to?(:corporation) && bid.corporation
              bid.corporation
            elsif bid.respond_to?(:minor) && bid.minor
              bid.minor
            end

          original_price =
            begin
              if target&.respond_to?(:value) &&
                 target.value.to_i.positive?
                target.value.to_i
              elsif target&.respond_to?(:min_price) &&
                    target.min_price.to_i.positive?
                target.min_price.to_i
              else
                bid.price.to_i
              end
            rescue StandardError
              bid.price.to_i
            end

          bid_price = bid.price.to_i

          return bid if original_price <= 0 || bid_price <= original_price

          player_count =
            begin
              [Array(game.players).size, 1].max
            rescue StandardError
              1
            end

          harmonic =
            (1..player_count).sum do |n|
              1.0 / n
            end

          scale =
            (0.20 * original_price.to_f) /
            harmonic

          excess =
            bid_price.to_f -
            original_price.to_f

          bid_probability =
            Math.exp(
              -excess / scale
            )

          if rand < bid_probability
            bid
          else
            passes.sample
          end
        end

        # Policy: buy as many trains as the network can drive next OR, with a single
        # 20% roll for one additional train.
        def self.train_target_count(useful_count, train_limit)
          extra_train = rand < 0.20 ? 1 : 0
          [useful_count.to_i + extra_train, train_limit.to_i].min
        end

        # Policy: if the corporation has at least twice the price of the
        # next depot train in cash, buy another train.
        def self.buy_train_when_cash_rich?(corporation_cash, next_train_price)
          price = next_train_price.to_i
          return false unless price.positive?

          corporation_cash.to_i >= (2 * price)
        end

        # Policy: buy an engine-legal train from another corporation controlled
        # by the same director with 10% probability.
        def self.buy_same_director_train?(game, entity)
          stable_probability?(
            game,
            entity,
            :buy_same_director_train,
            0.10,
          )
        end

        # Policy: if an affordable permanent train is available from the depot,
        # buy it now.
        def self.buy_affordable_permanent_train?
          true
        end

        # =====================================================================
        # 4-HEX DIRECTIONAL CORRIDOR & TOPOLOGY EVALUATOR
        # =====================================================================

        def self.extract_tile_exits(tile)
          return [] unless tile

          if tile.respond_to?(:exits) && tile.exits&.any?
            Array(tile.exits).compact.map(&:to_i).uniq
          elsif tile.respond_to?(:paths) && tile.paths&.any?
            Array(tile.paths).flat_map(&:exits).flatten.compact.map(&:to_i).uniq
          else
            []
          end
        rescue StandardError
          []
        end

        def self.connected_exits_from_entry(tile, entry_edge, fallback_exits = nil)
          exits = fallback_exits || extract_tile_exits(tile)
          return [] unless tile

          if tile.respond_to?(:paths) && tile.paths&.any?
            reachable = []
            Array(tile.paths).each do |path|
              p_exits = Array(path.exits).compact.map(&:to_i)
              reachable.concat(p_exits - [entry_edge]) if p_exits.include?(entry_edge)
            end
            return reachable.uniq if reachable.any?
          end

          exits - [entry_edge]
        rescue StandardError
          Array(fallback_exits) - [entry_edge]
        end

        def self.max_revenue_on_tile(tile, revenue_for = nil)
          return 0 unless tile

          revs = []
          revs.concat(Array(tile.cities).map(&:revenue)) if tile.respond_to?(:cities) && tile.cities
          revs.concat(Array(tile.towns).map(&:revenue)) if tile.respond_to?(:towns) && tile.towns
          revs.concat(Array(tile.offboards).map(&:revenue)) if tile.respond_to?(:offboards) && tile.offboards

          best = revs.flatten.compact.map do |r|
            r.is_a?(Hash) ? (r.values.select { |v| v.is_a?(Numeric) }.max || 0) : r.to_i
          end.max || 0

          return best if best.positive?

          revenue_for ? revenue_for.call(tile).to_i : 0
        rescue StandardError
          revenue_for ? revenue_for.call(tile).to_i : 0
        end

        def self.tile_has_own_token?(tile, entity)
          return false unless tile && entity && tile.respond_to?(:cities)

          Array(tile.cities).any? do |city|
            if city.respond_to?(:tokened_by?)
              city.tokened_by?(entity)
            else
              Array(city.tokens).compact.any? { |token| token.corporation == entity }
            end
          end
        rescue StandardError
          false
        end

        def self.tile_has_open_slot?(tile, entity)
          return false unless tile && tile.respond_to?(:cities)

          Array(tile.cities).any? do |city|
            next false if entity && city.respond_to?(:tokened_by?) && city.tokened_by?(entity)

            if city.respond_to?(:available_slots)
              city.available_slots.to_i.positive?
            elsif city.respond_to?(:tokens)
              Array(city.tokens).any?(&:nil?)
            else
              false
            end
          end
        rescue StandardError
          false
        end

        # A city hex is completely blocked for through-routing if it has cities,
        # zero open slots, and no token belonging to this entity.
        def self.tile_blocked_for_through_route?(tile, entity)
          return false unless tile && tile.respond_to?(:cities)

          cities = Array(tile.cities)
          return false if cities.empty?

          cities.none? do |city|
            own = if city.respond_to?(:tokened_by?)
                    city.tokened_by?(entity)
                  else
                    Array(city.tokens).compact.any? { |token| token.corporation == entity }
                  end
            open = if city.respond_to?(:available_slots)
                     city.available_slots.to_i.positive?
                   elsif city.respond_to?(:tokens)
                     Array(city.tokens).any?(&:nil?)
                   else
                     true
                   end
            own || open
          end
        rescue StandardError
          false
        end

        def self.neighbor_at_edge(hex, edge)
          neighbors = hex.respond_to?(:neighbors) && hex.neighbors ? hex.neighbors : {}
          all_neighbors = hex.respond_to?(:all_neighbors) && hex.all_neighbors ? hex.all_neighbors : neighbors
          neighbors[edge] || all_neighbors[edge]
        rescue StandardError
          nil
        end

        def self.invert_hex_edge(hex, edge)
          hex.respond_to?(:invert) ? hex.invert(edge) : ((edge + 3) % 6)
        rescue StandardError
          (edge + 3) % 6
        end

        # Identifies which edges of `origin_hex` are already connected to `entity`'s
        # existing network before laying a new tile on `origin_hex`.
        # Excluding these feeder edges from outward lookahead prevents the home city
        # behind a newly laid yellow tile from masking the forward horizon score.
        def self.feeder_edges_for_hex(entity, origin_hex, considered_exits)
          connecting_edges = []
          token_connected_edges = []

          home_coords = []
          if entity.respond_to?(:coordinates) && entity.coordinates
            home_coords.concat(Array(entity.coordinates).flatten.compact.map(&:to_s))
          end

          Array(considered_exits).each do |edge|
            n1 = neighbor_at_edge(origin_hex, edge)
            next unless n1 && n1.respond_to?(:tile) && n1.tile

            inv_edge = invert_hex_edge(origin_hex, edge)
            n1_exits = extract_tile_exits(n1.tile)
            next unless n1_exits.include?(inv_edge)

            connecting_edges << edge
            if ReachabilitySearch.reaches_entity_base?(n1, inv_edge, origin_hex, entity, home_coords)
              token_connected_edges << edge
            end
          end

          return token_connected_edges if token_connected_edges.any?
          return connecting_edges if connecting_edges.size == 1 && considered_exits.size > 1

          []
        rescue StandardError
          []
        end

        module ReachabilitySearch
          def self.reaches_entity_base?(start_hex, start_entry_edge, blocked_hex, entity, home_coords)
            queue = [[start_hex, start_entry_edge, 0]]
            visited = {}

            while (current = queue.shift)
              hex, entry_edge, depth = current
              next unless hex && hex != blocked_hex && hex.respond_to?(:tile) && hex.tile

              tile = hex.tile
              return true if AiExpertRules.tile_has_own_token?(tile, entity)
              return true if home_coords.include?(hex.id.to_s)
              next if depth >= 8

              state_key = "#{hex.id}:#{entry_edge}"
              next if visited[state_key]

              visited[state_key] = true
              out_edges = AiExpertRules.connected_exits_from_entry(tile, entry_edge)
              out_edges.each do |out_edge|
                nxt = AiExpertRules.neighbor_at_edge(hex, out_edge)
                next unless nxt && nxt != blocked_hex && nxt.respond_to?(:tile) && nxt.tile

                nxt_entry = AiExpertRules.invert_hex_edge(hex, out_edge)
                nxt_exits = AiExpertRules.extract_tile_exits(nxt.tile)
                next unless nxt_exits.include?(nxt_entry)

                queue << [nxt, nxt_entry, depth + 1]
              end
            end

            false
          rescue StandardError
            false
          end
        end

        # Evaluates a 4-hex directional corridor starting from `origin_hex` along `start_edge`.
        # Returns best values at horizons 1..4, whether step 1 links to existing track/stops,
        # and whether step 1 is a permanent dead end.
        def self.evaluate_corridor_from_edge(
          entity:,
          origin_hex:,
          start_edge:,
          revenue_for:,
          dest_coords:,
          has_unplaced_tokens:
        )
          horizons = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
          n1 = neighbor_at_edge(origin_hex, start_edge)
          return { horizons: horizons, dead_end: true, connects_existing: false } unless n1 && n1.respond_to?(:tile) && n1.tile

          entry_1 = invert_hex_edge(origin_hex, start_edge)
          queue = [[n1, entry_1, 1, 0]]
          best_visited_penalty = { origin_hex.id.to_s => -1 }
          connects_existing = false
          dead_end_step_1 = false

          while (node = queue.shift)
            curr_hex, entry_edge, depth, acc_penalty = node
            curr_tile = curr_hex.tile
            next unless curr_tile

            color = curr_tile.respond_to?(:color) && curr_tile.color ? curr_tile.color.to_sym : :white
            exits = extract_tile_exits(curr_tile)
            unbuilt = (color == :white) && exits.empty?
            connects_back = exits.include?(entry_edge)
            rev = max_revenue_on_tile(curr_tile, revenue_for)

            # Check if an unbuilt white hex is completely impassable (e.g. water/mountain blocker)
            borders = curr_tile.respond_to?(:borders) ? Array(curr_tile.borders) : []
            entry_blocked_by_border = borders.any? do |border|
              border.respond_to?(:edge) && border.edge.to_i == entry_edge &&
                border.respond_to?(:type) && border.type == :impassable
            end

            if entry_blocked_by_border
              dead_end_step_1 = true if depth == 1
              next
            end

            if !unbuilt && !connects_back
              if %i[red gray brown].include?(color)
                # Pointing into the non-connecting side of a red offboard, gray fixed tile,
                # or brown tile is a dead end.
                dead_end_step_1 = true if depth == 1
                next
              else
                # Yellow or green tile with a city/town that could be upgraded later to add an exit.
                if rev.positive? && depth <= 2
                  upgrade_val = [(rev * 0.65).to_i - acc_penalty, 5].max
                  horizons[depth] = [horizons[depth], upgrade_val].max
                elsif depth == 1
                  dead_end_step_1 = true
                end
                next
              end
            end

            connects_existing = true if depth == 1 && (connects_back || (unbuilt && rev.positive?))

            terrain_cost = curr_hex.respond_to?(:cost) ? curr_hex.cost.to_i : 0
            if unbuilt && terrain_cost.zero? && curr_tile.respond_to?(:upgrades)
              terrain_cost = Array(curr_tile.upgrades).map { |u| u.respond_to?(:cost) ? u.cost.to_i : 0 }.max.to_i
            end
            step_penalty = unbuilt ? (terrain_cost / 4).to_i : 0

            is_dest = dest_coords.include?(curr_hex.id.to_s)
            open_slot = has_unplaced_tokens && tile_has_open_slot?(curr_tile, entity)

            target_val = 0
            if rev.positive?
              target_val = rev
              target_val += 80 if is_dest
              target_val += 15 if open_slot
            elsif is_dest
              target_val = 80
            elsif connects_back
              target_val = 12
            end

            if target_val.positive?
              applied_penalty = acc_penalty + (depth > 1 ? step_penalty : (step_penalty / 2).to_i)
              net_val = [target_val - applied_penalty, (rev.positive? ? 5 : 2)].max
              horizons[depth] = [horizons[depth], net_val].max
            end

            next if depth >= 4
            next if color == :red
            next if tile_blocked_for_through_route?(curr_tile, entity)

            out_edges = if connects_back
                          connected_exits_from_entry(curr_tile, entry_edge, exits)
                        else
                          (0..5).to_a - [entry_edge]
                        end

            out_edges.each do |out_edge|
              next if borders.any? do |b|
                b.respond_to?(:edge) && b.edge.to_i == out_edge &&
                  b.respond_to?(:type) && b.type == :impassable
              end

              nxt_hex = neighbor_at_edge(curr_hex, out_edge)
              next unless nxt_hex && nxt_hex != origin_hex && nxt_hex.respond_to?(:tile) && nxt_hex.tile

              # Slight preference for straight/gentle-curve exits over sharp curves on unbuilt hexes
              turn_delta = (out_edge - entry_edge).abs % 6
              sharp_curve_penalty = unbuilt && [1, 5].include?(turn_delta) ? 3 : 0
              nxt_penalty = acc_penalty + step_penalty + sharp_curve_penalty
              nxt_depth = depth + 1
              nxt_id = "#{nxt_hex.id}:#{nxt_depth}"

              next if best_visited_penalty.key?(nxt_id) && best_visited_penalty[nxt_id] <= nxt_penalty

              best_visited_penalty[nxt_id] = nxt_penalty
              nxt_entry = invert_hex_edge(curr_hex, out_edge)
              queue << [nxt_hex, nxt_entry, nxt_depth, nxt_penalty]
            end
          end

          {
            horizons: horizons,
            dead_end: dead_end_step_1,
            connects_existing: connects_existing,
          }
        rescue StandardError
          { horizons: horizons, dead_end: false, connects_existing: false }
        end

        # Policy: evaluate a tile lay across a 4-hex lookahead horizon.
        # Backwards-compatible with both dashboard_ai_player.rb and dashboard_ai_engine_search.rb.
        def self.two_build_tile_features(entity:, hex:, old_tile:, new_tile:, cost:, revenue_for:)
          old_rev = max_revenue_on_tile(old_tile, revenue_for)
          new_rev = max_revenue_on_tile(new_tile, revenue_for)
          tile_rev_gain = [new_rev - old_rev, 0].max
          has_own_token = tile_has_own_token?(old_tile, entity) || tile_has_own_token?(new_tile, entity)

          old_exits = extract_tile_exits(old_tile)
          new_exits = extract_tile_exits(new_tile)
          added_exits = new_exits - old_exits
          base_exits = added_exits.empty? ? new_exits : added_exits

          # Exclude feeder edges that simply point back into the corporation's existing
          # network when laying on an unbuilt hex, so the home city behind us does not
          # pollute forward horizon values.
          feeder_edges = old_exits.empty? ? feeder_edges_for_hex(entity, hex, base_exits) : []
          outward_exits = base_exits - feeder_edges
          considered_exits = outward_exits.empty? ? base_exits : outward_exits

          dest_coords = []
          if entity.respond_to?(:destination_coordinates) && entity.destination_coordinates
            dest_coords.concat(Array(entity.destination_coordinates).flatten.compact.map(&:to_s))
          end

          has_unplaced_tokens =
            if entity.respond_to?(:unplaced_tokens)
              Array(entity.unplaced_tokens).any?
            elsif entity.respond_to?(:tokens)
              Array(entity.tokens).any? { |t| t.respond_to?(:used) && !t.used }
            else
              false
            end

          horizon_1_value = 0
          horizon_2_raw = 0
          horizon_3_value = 0
          horizon_4_value = 0
          dead_end_count = 0
          outward_connects_existing = false

          considered_exits.each do |edge|
            corridor = evaluate_corridor_from_edge(
              entity: entity,
              origin_hex: hex,
              start_edge: edge,
              revenue_for: revenue_for,
              dest_coords: dest_coords,
              has_unplaced_tokens: has_unplaced_tokens,
            )

            if corridor[:dead_end]
              dead_end_count += 1
              next
            end

            outward_connects_existing ||= corridor[:connects_existing]
            h = corridor[:horizons]
            horizon_1_value = [horizon_1_value, h[1].to_i].max
            horizon_2_raw   = [horizon_2_raw,   h[2].to_i].max
            horizon_3_value = [horizon_3_value, h[3].to_i].max
            horizon_4_value = [horizon_4_value, h[4].to_i].max
          end

          # Count total exits connecting to existing neighbor track/stops on step 1
          total_connecting_exits = new_exits.count do |edge|
            n1 = neighbor_at_edge(hex, edge)
            if n1 && n1.respond_to?(:tile) && n1.tile
              inv = invert_hex_edge(hex, edge)
              extract_tile_exits(n1.tile).include?(inv)
            else
              false
            end
          end

          old_has_stops =
            (old_tile.respond_to?(:cities) && Array(old_tile.cities).any?) ||
            (old_tile.respond_to?(:towns) && Array(old_tile.towns).any?) ||
            (old_tile.respond_to?(:offboards) && Array(old_tile.offboards).any?)
          new_has_stops =
            (new_tile.respond_to?(:cities) && Array(new_tile.cities).any?) ||
            (new_tile.respond_to?(:towns) && Array(new_tile.towns).any?) ||
            (new_tile.respond_to?(:offboards) && Array(new_tile.offboards).any?)

          # A tile lay can only alter immediate ply-1 AutoRouter revenue if it upgrades
          # existing track, involves a city/town/offboard, or bridges >= 2 existing track edges.
          immediate_network_change =
            old_exits.any? ||
            old_has_stops ||
            new_has_stops ||
            tile_rev_gain.positive? ||
            total_connecting_exits >= 2

          # Fold discounted 3-hex and 4-hex values into horizon_2_value so callers
          # summing horizon_1 + horizon_2 automatically gain 4-hex directional vision.
          extended_horizon_2 =
            horizon_2_raw +
            (horizon_3_value * 0.60).to_i +
            (horizon_4_value * 0.35).to_i

          multi_hex_corridor_value =
            horizon_1_value +
            extended_horizon_2

          {
            tile_rev_gain: tile_rev_gain,
            has_own_token: has_own_token,
            horizon_1_value: horizon_1_value,
            horizon_2_raw: horizon_2_raw,
            horizon_2_value: extended_horizon_2,
            horizon_3_value: horizon_3_value,
            horizon_4_value: horizon_4_value,
            multi_hex_corridor_value: multi_hex_corridor_value,
            immediate_network_change: immediate_network_change,
            outward_connects_existing: outward_connects_existing,
            is_dead_end_edge: considered_exits.any? && dead_end_count == considered_exits.size,
            tile_cost: cost.to_i,
          }
        end

        def self.matches_condition?(condition, features)
          return true if condition.nil? || condition.empty?

          condition.all? do |key, expected|
            k = key.to_s
            if k.end_with?('_gt')
              feat_k = k.sub(/_gt$/, '').to_sym
              (features[feat_k] || 0) > expected
            elsif k.end_with?('_gte')
              feat_k = k.sub(/_gte$/, '').to_sym
              (features[feat_k] || 0) >= expected
            elsif k.end_with?('_lt')
              feat_k = k.sub(/_lt$/, '').to_sym
              (features[feat_k] || 0) < expected
            elsif k.end_with?('_lte')
              feat_k = k.sub(/_lte$/, '').to_sym
              (features[feat_k] || 0) <= expected
            elsif k.end_with?('_in')
              feat_k = k.sub(/_in$/, '').to_sym
              Array(expected).include?(features[feat_k])
            elsif k.end_with?('_not')
              feat_k = k.sub(/_not$/, '').to_sym
              features[feat_k] != expected
            else
              features[key.to_sym] == expected
            end
          end
        end

        # =====================================================================
        # HUMAN-READABLE STRATEGIC RULEBOOK
        #
        # Scoring conventions:
        #   +1000 to +2000 : Critical priority (floating own par, emergency finance, dividends)
        #   +400  to +900  : High priority (starting a par, defending presidency)
        #   +100  to +350  : Standard profitable action (buying shares, trains, tiles)
        #   -100           : Pass baseline (chosen only when no action scores > 0)
        #   -200  to -1500 : Soft strategic discouragement (over-concentration, bad buys)
        #   -10_000        : Hard strategic veto (only bypassed if every legal move is vetoed)
        # =====================================================================
        DEFAULT_RULES = [
          # -------------------------------------------------------------------
          # 1. STOCK ROUND: CORPORATION FORMATION (PAR)
          # -------------------------------------------------------------------
          {
            id: 'SR01_base_par',
            description: 'Starting a new corporation beats ordinary share buying when no presidency is unfloated',
            when: { action_type: 'par', unfloated_presidencies: 0 },
            score_add: 450,
            score_per_unit: { field: 'par_price', multiplier: 0.5 },
          },
          {
            id: 'SR02_veto_second_par_if_unfloated',
            description: 'Never par a second company while an existing presidency is still unfloated',
            when: { action_type: 'par', unfloated_presidencies_gt: 0 },
            score_add: -10_000,
          },
          {
            id: 'SR03_prefer_affordable_full_float_par',
            description: 'Strongly prefer par prices where player cash can self-float the corporation',
            when: { action_type: 'par', can_self_float: true },
            score_add: 400,
            score_per_unit: { field: 'par_price', multiplier: 1.5 },
          },
          {
            id: 'SR04_veto_unfloatable_high_par',
            description: 'Veto expensive pars if player cash cannot self-float and a cheaper self-floatable par exists',
            when: { action_type: 'par', can_self_float: false, cheaper_floatable_par_exists: true },
            score_add: -10_000,
          },
          {
            id: 'SR05_par_home_quality',
            description: 'Prefer parring corporations whose home hexes sit in higher-revenue clusters',
            when: { action_type: 'par', home_location_value_gt: 0 },
            score_add: 0,
            score_per_unit: { field: 'home_location_value', multiplier: 2.0 },
          },

          # -------------------------------------------------------------------
          # 2. STOCK ROUND: BUYING SHARES
          # -------------------------------------------------------------------
          {
            id: 'SR06_base_valid_share_buy',
            description: 'Positive baseline for any legal share purchase so healthy buys beat Pass',
            when: { action_type: 'buy_shares' },
            score_add: 100,
          },
          {
            id: 'SR07_float_own_company',
            description: 'Highest Stock Round priority: if director of an unfloated company, buy shares until it floats',
            when: { action_type: 'buy_shares', player_is_president: true, is_floated: false },
            score_add: 1200,
          },
          {
            id: 'SR08_defend_presidency',
            description: 'Defend presidency if an opponent shareholding is within 10% of ours',
            when: { action_type: 'buy_shares', player_is_president: true, presidency_threatened: true },
            score_add: 450,
          },
          {
            id: 'SR09_avoid_over_concentration_in_safe_company',
            description: 'Discourage buying beyond 50% in own safe floated company (drops below Pass unless no other option)',
            when: {
              action_type: 'buy_shares',
              player_is_president: true,
              is_floated: true,
              player_percent_gte: 50,
              presidency_threatened: false,
            },
            score_add: -400,
          },
          {
            id: 'SR10_buy_train_ready_company',
            description: 'Prefer floated companies that already own operating trains',
            when: { action_type: 'buy_shares', is_floated: true, corp_trains_count_gt: 0 },
            score_add: 180,
            score_per_unit: { field: 'share_price', multiplier: 0.5 },
          },
          {
            id: 'SR11_buy_cash_rich_floated',
            description: 'Prefer floated companies with enough treasury cash to buy a train next OR',
            when: { action_type: 'buy_shares', is_floated: true, corp_trains_count: 0, corp_can_buy_train: true },
            score_add: 140,
          },
          {
            id: 'SR12_anti_herd_unfloated',
            description: 'Do not buy into a rival player unfloated company (scores below 0 so Pass wins)',
            when: { action_type: 'buy_shares', other_is_president: true, is_floated: false },
            score_add: -500,
          },
          {
            id: 'SR13_prefer_market_when_cheaper',
            description: 'Prefer Bank Pool shares over IPO when priced lower',
            when: { action_type: 'buy_shares', source: :market, market_price_lt_ipo: true },
            score_add: 75,
          },

          # -------------------------------------------------------------------
          # 3. STOCK ROUND & EMERGENCY FINANCING: SELLING SHARES & PASSING
          # -------------------------------------------------------------------
          {
            id: 'SR14_veto_unnecessary_sells',
            description: 'Veto selling shares unless forced, raising cash for unfloated presidency, or triggered by trim roll',
            when: { action_type: 'sell_shares', sell_justified: false },
            score_add: -10_000,
          },
          {
            id: 'SR15_emergency_cover_train_shortfall',
            description: 'During emergency train financing, prefer a bundle that covers the shortfall with minimal overshoot',
            when: { action_type: 'sell_shares', emergency_train_sale: true, covers_emergency_shortfall: true },
            score_add: 2000,
            score_per_unit: { field: 'emergency_shortfall_overshoot', multiplier: -1.0 },
          },
          {
            id: 'SR16_emergency_largest_partial_bundle',
            description: 'If no single bundle covers the emergency train shortfall, sell the largest bundle first',
            when: { action_type: 'sell_shares', emergency_train_sale: true, covers_emergency_shortfall: false },
            score_add: 200,
            score_per_unit: { field: 'bundle_price', multiplier: 2.0 },
          },
          {
            id: 'SR17_sell_to_float_own_company',
            description: 'Sell a non-presidency share when cash-short to finish floating own unfloated corporation',
            when: {
              action_type: 'sell_shares',
              need_cash_for_unfloated_presidency: true,
              player_is_president_of_sold: false,
              causes_president_dump: false,
            },
            score_add: 400,
          },
          {
            id: 'SR18_sell_weakest_when_over_cert_limit',
            description: 'When over certificate limit, sell smallest non-presidency bundles',
            when: { action_type: 'sell_shares', must_sell: true, player_is_president_of_sold: false },
            score_add: 300,
            score_per_unit: { field: 'bundle_num_shares', multiplier: -50.0 },
          },
          {
            id: 'SR19_voluntary_portfolio_trim',
            description: 'Modest positive score when stable 5%/10% portfolio trim roll triggers after buying completes',
            when: { action_type: 'sell_shares', voluntary_sell_roll: true, causes_president_dump: false },
            score_add: 150,
          },
          {
            id: 'SR20_never_dump_own_presidency',
            description: 'Veto dumping own presidency in normal Stock Rounds',
            when: {
              action_type: 'sell_shares',
              causes_president_dump: true,
              must_sell: false,
              emergency_train_sale: false,
            },
            score_add: -10_000,
          },
          {
            id: 'SR21_avoid_president_dump_in_emergency',
            description: 'Penalize dumping presidency during emergency train financing if non-dump sales exist',
            when: { action_type: 'sell_shares', causes_president_dump: true, emergency_train_sale: true },
            score_add: -1500,
          },
          {
            id: 'SR22_pass_baseline',
            description: 'Pass stays below 0 so any positive action beats it, but it beats negative/penalized actions',
            when: { action_type: 'pass' },
            score_add: -100,
          },

          # -------------------------------------------------------------------
          # 4. OPERATING ROUND: DIVIDEND ALLOCATION
          # -------------------------------------------------------------------
          {
            id: 'OR_DIV01_withhold_if_zero_revenue',
            description: 'Always withhold when route revenue is zero',
            when: { action_type: 'dividend', dividend_kind: 'withhold', revenue: 0 },
            score_add: 2000,
          },
          {
            id: 'OR_DIV02_half_pay_for_needed_train',
            description: 'Prefer half/split pay when partial retention is sufficient to afford a needed or permanent train',
            when: {
              action_type: 'dividend',
              dividend_kind_in: %w[half split],
              retention_enables_needed_train: true,
            },
            score_add: 1800,
          },
          {
            id: 'OR_DIV03_withhold_for_permanent_train',
            description: 'Withhold when full retention makes a permanent train immediately affordable',
            when: {
              action_type: 'dividend',
              dividend_kind: 'withhold',
              retention_enables_permanent_train: true,
            },
            score_add: 1500,
          },
          {
            id: 'OR_DIV04_withhold_when_trainless_and_short',
            description: 'Withhold when the corporation owns zero trains and treasury is below the next train price',
            when: {
              action_type: 'dividend',
              dividend_kind: 'withhold',
              trainless_needs_cash: true,
            },
            score_add: 1400,
          },
          {
            id: 'OR_DIV05_payout_by_default',
            description: 'Pay full dividends by default when revenue is positive to advance share price and fund players',
            when: { action_type: 'dividend', dividend_kind: 'payout', revenue_gt: 0 },
            score_add: 1000,
          },
          {
            id: 'OR_DIV06_half_pay_baseline',
            description: 'Secondary positive baseline for half/split pay when revenue is positive',
            when: { action_type: 'dividend', dividend_kind_in: %w[half split], revenue_gt: 0 },
            score_add: 600,
          },
          {
            id: 'OR_DIV07_avoid_unnecessary_withhold',
            description: 'Penalize withholding positive revenue when the company has a train and cannot cross a permanent train threshold',
            when: {
              action_type: 'dividend',
              dividend_kind: 'withhold',
              revenue_gt: 0,
              retention_enables_permanent_train: false,
              trainless_needs_cash: false,
            },
            score_add: -1000,
          },

          # -------------------------------------------------------------------
          # 5. OPERATING ROUND: TRACK LAYING (1 TO 4 HEX CORRIDOR HORIZON)
          # -------------------------------------------------------------------
          {
            id: 'OR_TL01_base_valid_tile',
            description: 'Baseline score for any verified legal tile lay',
            when: { action_type: 'lay_tile' },
            score_add: 40,
          },
          {
            id: 'OR_TL02_immediate_route_revenue_gain',
            description: 'High reward when AutoRouter or topology confirms route revenue increase',
            when: { action_type: 'lay_tile', route_revenue_gain_gt: 0 },
            score_add: 250,
            score_per_unit: { field: 'route_revenue_gain', multiplier: 8.0 },
          },
          {
            id: 'OR_TL03_upgrade_own_tokened_city',
            description: 'Prioritize upgrading cities where this corporation has a station token',
            when: { action_type: 'lay_tile', has_own_token: true, tile_rev_gain_gt: 0 },
            score_add: 220,
            score_per_unit: { field: 'tile_rev_gain', multiplier: 6.0 },
          },
          {
            id: 'OR_TL04_upgrade_connected_city_or_town',
            description: 'Reward laying or upgrading a connected city/town hex that increases printed revenue',
            when: { action_type: 'lay_tile', has_own_token: false, tile_rev_gain_gt: 0 },
            score_add: 120,
            score_per_unit: { field: 'tile_rev_gain', multiplier: 4.0 },
          },
          {
            id: 'OR_TL05_horizon1_direct_neighbor_target',
            description: '1-Hex Horizon: Outward exit connects to an adjacent city, town, or offboard',
            when: { action_type: 'lay_tile', horizon_1_value_gt: 0 },
            score_add: 200,
            score_per_unit: { field: 'horizon_1_value', multiplier: 18.0 },
          },
          {
            id: 'OR_TL06_horizon2_two_tile_bridge',
            description: '2-Hex Horizon: Outward exit points toward a revenue center or destination 2 hexes away',
            when: { action_type: 'lay_tile', horizon_2_raw_gt: 0 },
            score_add: 60,
            score_per_unit: { field: 'horizon_2_raw', multiplier: 6.0 },
          },
          {
            id: 'OR_TL06b_horizon3_three_tile_corridor',
            description: '3-Hex Horizon: Outward exit steers toward a high-value hub or offboard 3 hexes away',
            when: { action_type: 'lay_tile', horizon_3_value_gt: 0 },
            score_add: 35,
            score_per_unit: { field: 'horizon_3_value', multiplier: 3.5 },
          },
          {
            id: 'OR_TL06c_horizon4_four_tile_corridor',
            description: '4-Hex Horizon: Long-range alignment toward distant destinations or red offboards 4 hexes away',
            when: { action_type: 'lay_tile', horizon_4_value_gt: 0 },
            score_add: 20,
            score_per_unit: { field: 'horizon_4_value', multiplier: 2.0 },
          },
          {
            id: 'OR_TL07_penalize_map_border_dead_end',
            description: 'Penalize pointing new exits off the board edge, into impassable hexes, or into non-connecting offboard sides',
            when: { action_type: 'lay_tile', is_dead_end_edge: true },
            score_add: -600,
          },
          {
            id: 'OR_TL08_half_cost_value_penalty',
            description: 'Penalize terrain cost proportionally, allowing profitable connections to override it',
            when: { action_type: 'lay_tile', tile_cost_gt: 0 },
            score_add: -10,
            score_per_unit: { field: 'tile_cost', multiplier: -0.5 },
          },
          {
            id: 'OR_TL09_veto_expensive_tile_if_breaks_train_budget',
            description: 'Never spend cash on terrain if trainless and doing so drops treasury below cheapest depot train',
            when: { action_type: 'lay_tile', breaks_train_budget: true },
            score_add: -10_000,
          },

          # -------------------------------------------------------------------
          # 6. OPERATING ROUND: TRAINS, TOKENS & CHOICES
          # -------------------------------------------------------------------
          {
            id: 'OR_TR01_buy_depot_train',
            description: 'Buy available train from depot when corporation has capacity',
            when: { action_type: 'buy_train', train_from_depot: true },
            score_add: 320,
          },
          {
            id: 'OR_TR02_prefer_permanent_depot_train',
            description: 'Extra priority for buying a permanent train from the depot',
            when: { action_type: 'buy_train', train_from_depot: true, is_permanent_train: true },
            score_add: 300,
          },
          {
            id: 'OR_TR03_veto_intercompany_train_if_has_train',
            description: 'Veto inter-company train purchases if corporation already owns an operational train',
            when: { action_type: 'buy_train', train_from_depot: false, corp_trains_count_gt: 0 },
            score_add: -10_000,
          },
          {
            id: 'OR_TR04_discard_cheapest_train',
            description: 'Discard the lowest-cost train when over train limit',
            when: { action_type: 'discard_train' },
            score_add: 300,
            score_per_unit: { field: 'train_cost', multiplier: -1.0 },
          },
          {
            id: 'OR_TK01_token_lay_baseline',
            description: 'Baseline score for placing a station token',
            when: { action_type: 'place_token' },
            score_add: 150,
          },
          {
            id: 'OR_CH01_choice_baseline',
            description: 'Baseline score for generic step choices',
            when: { action_type: 'choose' },
            score_add: 50,
          },
        ].freeze
      end
    end
  end
end
