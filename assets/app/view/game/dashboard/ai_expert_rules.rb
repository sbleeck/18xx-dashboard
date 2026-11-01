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

        # Policy: evaluate a tile lay as the first of two consecutive builds.
        def self.two_build_tile_features(entity:, hex:, old_tile:, new_tile:, cost:, revenue_for:)
          old_rev = revenue_for.call(old_tile)
          new_rev = revenue_for.call(new_tile)
          tile_rev_gain = [new_rev - old_rev, 0].max
          has_own_token = old_tile.respond_to?(:cities) && Array(old_tile.cities).any? do |city|
            if city.respond_to?(:tokened_by?)
              city.tokened_by?(entity)
            else
              Array(city.tokens).compact.any? { |token| token.corporation == entity }
            end
          end

          old_exits = old_tile.respond_to?(:exits) ? Array(old_tile.exits).uniq : []
          new_exits = new_tile.respond_to?(:exits) ? Array(new_tile.exits).uniq : []
          added_exits = new_exits - old_exits
          considered_exits = added_exits.empty? ? new_exits : added_exits

          neighbors = hex.respond_to?(:neighbors) && hex.neighbors ? hex.neighbors : {}
          all_neighbors = hex.respond_to?(:all_neighbors) && hex.all_neighbors ? hex.all_neighbors : neighbors
          horizon_1_value = 0
          horizon_2_value = 0
          dead_end_count = 0

          considered_exits.each do |edge|
            n1 = neighbors[edge] || all_neighbors[edge]
            unless n1 && n1.respond_to?(:tile) && n1.tile
              dead_end_count += 1
              next
            end

            inv_edge = hex.respond_to?(:invert) ? hex.invert(edge) : ((edge + 3) % 6)
            n1_tile = n1.tile

            max_revenue_on_tile = lambda do |t|
              return 0 unless t

              revs = []
              revs.concat(t.cities.map(&:revenue)) if t.respond_to?(:cities) && t.cities
              revs.concat(t.towns.map(&:revenue)) if t.respond_to?(:towns) && t.towns
              revs.flatten.compact.map do |r|
                r.is_a?(Hash) ? (r.values.compact.max || 0) : r
              end.max || 0
            end

            n1_rev = max_revenue_on_tile.call(n1_tile)

            n1_exits = if n1_tile.respond_to?(:exits) && n1_tile.exits&.any?
                         Array(n1_tile.exits).uniq
                       elsif n1_tile.respond_to?(:paths) && n1_tile.paths&.any?
                         Array(n1_tile.paths).flat_map(&:exits).flatten.compact.uniq
                       else
                         []
                       end

            n1_color = n1_tile.respond_to?(:color) ? n1_tile.color : nil
            n1_unbuilt = [:white, 'white'].include?(n1_color) || n1_color.nil?
            n1_connects_back = n1_exits.include?(inv_edge)

            if n1_rev.positive?
              if n1_connects_back
                horizon_1_value = [horizon_1_value, n1_rev].max
              elsif n1_unbuilt
                horizon_1_value = [horizon_1_value, [n1_rev, 20].max].max
              end
            elsif n1_connects_back
              horizon_1_value = [horizon_1_value, 10].max
            end

            n2_edges = []
            if n1_unbuilt
              n2_edges = (0..5).to_a - [inv_edge]
            elsif n1_connects_back
              if n1_tile.respond_to?(:paths) && n1_tile.paths&.any?
                Array(n1_tile.paths).each do |path|
                  path_exits = path.exits
                  n2_edges.concat(path_exits - [inv_edge]) if path_exits.include?(inv_edge)
                end
              else
                n2_edges = n1_exits - [inv_edge]
              end
            end
            n2_edges.uniq!
            next if n2_edges.empty?

            n1_neighbors = n1.respond_to?(:neighbors) && n1.neighbors ? n1.neighbors : {}
            n1_all = n1.respond_to?(:all_neighbors) && n1.all_neighbors ? n1.all_neighbors : n1_neighbors
            n1_cost = n1.respond_to?(:cost) ? (n1.cost || 0).to_i : 0
            best_second_build = 0

            n2_edges.each do |edge2|
              n2 = n1_neighbors[edge2] || n1_all[edge2]
              next unless n2 && n2 != hex && n2.respond_to?(:tile) && n2.tile

              n2_tile = n2.tile
              n2_rev = revenue_for.call(n2_tile)

              n2_exits = if n2_tile.respond_to?(:exits) && n2_tile.exits&.any?
                           Array(n2_tile.exits).uniq
                         elsif n2_tile.respond_to?(:paths) && n2_tile.paths&.any?
                           Array(n2_tile.paths).flat_map(&:exits).flatten.compact.uniq
                         else
                           []
                         end

              n2_color = n2_tile.respond_to?(:color) ? n2_tile.color : nil
              n2_unbuilt = [:white, 'white'].include?(n2_color) || n2_color.nil?
              back_to_n1 = n1.respond_to?(:invert) ? n1.invert(edge2) : ((edge2 + 3) % 6)

              if !n2_unbuilt
                next unless n2_exits.include?(back_to_n1)
              else
                next unless n2_rev.positive?
              end

              value = if n2_rev.positive?
                        n2_rev
                      else
                        (n2_exits.any? ? 10 : 0)
                      end
              value -= n1_cost / 3 if n1_unbuilt
              best_second_build = [best_second_build, value].max
            end
            horizon_2_value = [horizon_2_value, best_second_build].max
          end

          {
            tile_rev_gain: tile_rev_gain,
            has_own_token: has_own_token,
            horizon_1_value: horizon_1_value,
            horizon_2_value: horizon_2_value,
            is_dead_end_edge: considered_exits.any? && dead_end_count == considered_exits.size,
            tile_cost: cost,
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
          # 5. OPERATING ROUND: TRACK LAYING (1-TILE & 2-TILE HORIZON)
          # -------------------------------------------------------------------
          {
            id: 'OR_TL01_base_valid_tile',
            description: 'Baseline score for any verified legal tile lay',
            when: { action_type: 'lay_tile' },
            score_add: 40,
          },
          {
            id: 'OR_TL02_immediate_route_revenue_gain',
            description: 'High reward when AutoRouter confirms immediate route revenue increase',
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
            description: '1-Tile Horizon: New exit connects directly to an adjacent city, town, or offboard',
            when: { action_type: 'lay_tile', horizon_1_value_gt: 0 },
            score_add: 200,
            score_per_unit: { field: 'horizon_1_value', multiplier: 18.0 },
          },
          {
            id: 'OR_TL06_horizon2_two_tile_bridge',
            description: '2-Tile Horizon: New exit points across an open neighbor toward a city/offboard 2 hexes away',
            when: { action_type: 'lay_tile', horizon_2_value_gt: 0 },
            score_add: 50,
            score_per_unit: { field: 'horizon_2_value', multiplier: 5.0 },
          },
          {
            id: 'OR_TL07_penalize_map_border_dead_end',
            description: 'Penalize pointing new exits off the board edge or into impassable hexes',
            when: { action_type: 'lay_tile', is_dead_end_edge: true },
            score_add: -400,
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
