# assets/app/view/game/dashboard/ai_expert_rules.rb
# frozen_string_literal: true

module View
  module Game
    module Dashboard
      class AiExpertRules
        @game_overrides = {}

        # Backdoor for game-specific rules (e.g., '1835', '1830')
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

        def self.select_candidate(scored_items, top_window: nil)
          return nil if scored_items.empty?

          # Only an explicit hard veto removes an action.
          valid = scored_items.reject { |item| item[:score] <= -5000 }
          return nil if valid.empty?

          # Start from ALL non-vetoed legal actions.
          #
          # Equal scores => exactly equal probability.
          min_score = valid.map { |item| item[:score] }.min

          weights = valid.map do |item|
            ((item[:score] - min_score) + 10.0)**1.5
          end

          total_weight = weights.sum
          target = rand * total_weight
          acc = 0.0

          valid.each_with_index do |candidate, index|
            acc += weights[index]
            return candidate if target < acc
          end

          valid.last
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

        DEFAULT_RULES = [
          # --- SHARE ROUND: FLOATING & PRESIDENCY RULES ---
          {
            id: 'SR01_float_own_company',
            description: 'If director of an unfloated company, buy shares until it opens',
            when: { action_type: 'buy_shares', player_is_president: true, is_floated: false },
            score_add: 500,
          },
          {
            id: 'SR02_veto_second_par_if_unfloated',
            description: 'Never par a second company while an unfloated presidency is active',
            when: { action_type: 'par', unfloated_presidencies_gt: 0 },
            score_add: -10_000,
          },
          {
            id: 'SR03_prefer_affordable_full_float_par',
            description: 'Prefer par prices where player cash can fund the entire float threshold',
            when: { action_type: 'par', can_self_float: true },
            score_add: 300,
            score_per_unit: { field: 'par_price', multiplier: 1.5 },
          },
          {
            id: 'SR04_veto_unfloatable_high_par',
            description: 'Veto expensive pars if player cash cannot float and cheaper floatable pars exist',
            when: { action_type: 'par', can_self_float: false, cheaper_floatable_par_exists: true },
            score_add: -10_000,
          },
          {
            id: 'SR05_defend_presidency',
            description: 'Defend presidency if opponent shareholding is within 10% of mine',
            when: { action_type: 'buy_shares', player_is_president: true, presidency_threatened: true },
            score_add: 350,
          },
          {
            id: 'SR06_avoid_over_concentration_in_safe_company',
            description: 'Discourage buying beyond 50% in own safe company if already floated',
            when: {
              action_type: 'buy_shares',
              player_is_president: true,
              is_floated: true,
              player_percent_gte: 50,
              presidency_threatened: false,
            },
            score_add: -180,
          },

          # --- SHARE ROUND: GENERAL INVESTING ---
          {
            id: 'SR07_buy_train_ready_company',
            description: 'Buy shares in floated companies that already own operating trains',
            when: { action_type: 'buy_shares', is_floated: true, corp_trains_count_gt: 0 },
            score_add: 160,
            score_per_unit: { field: 'share_price', multiplier: 0.5 },
          },
          {
            id: 'SR08_buy_cash_rich_floated',
            description: 'Buy shares in floated companies capable of buying a train next OR',
            when: { action_type: 'buy_shares', is_floated: true, corp_trains_count: 0, corp_can_buy_train: true },
            score_add: 120,
          },
          {
            id: 'SR09_anti_herd_unfloated',
            description: 'Do not buy into rival unfloated companies',
            when: { action_type: 'buy_shares', other_is_president: true, is_floated: false },
            score_add: -400,
          },
          {
            id: 'SR10_prefer_market_when_cheaper',
            description: 'Prefer Bank Pool shares over IPO when priced lower',
            when: { action_type: 'buy_shares', source: :market, market_price_lt_ipo: true },
            score_add: 75,
          },

          # --- SHARE ROUND: SELLING & PASS DISCIPLINE ---
          {
            id: 'SR11_veto_unnecessary_sells',
            description: 'Never sell shares unless over cert limit or liquidating to float own company',
            when: { action_type: 'sell_shares', must_sell_or_raise_float_cash: false },
            score_add: -10_000,
          },
          {
            id: 'SR12_sell_to_float_own_company',
            description: 'Sell external non-presidency share to raise cash to finish floating own company',
            when: { action_type: 'sell_shares', unfloated_presidencies_gt: 0, player_is_president_of_sold: false },
            score_add: 400,
          },
          {
            id: 'SR13_sell_weakest_when_over_cert_limit',
            description: 'Sell non-presidency shares when over certificate limit',
            when: { action_type: 'sell_shares', certs_free_lte: 0, player_is_president_of_sold: false },
            score_add: 300,
          },
          {
            id: 'SR14_never_dump_own_presidency',
            description: 'Veto selling own presidency share unless forced by game engine',
            when: { action_type: 'sell_shares', causes_president_dump: true, must_sell: false },
            score_add: -10_000,
          },
          {
            id: 'SR15_pass_baseline',
            description: 'Pass has a modest negative baseline so valid profitable moves beat it, but it beats vetoed moves',
            when: { action_type: 'pass' },
            score_add: -100,
          },

          {
            id: 'OR01_payout_by_default',
            description: 'Always pay revenue unless retaining revenue enables purchase of a permanent train',
            when: { action_type: 'dividend', dividend_kind: 'payout' },
            score_add: 1000,
          },
          {
            id: 'OR02_withhold_for_permanent_train',
            description: 'Withhold if doing so makes a permanent train affordable',
            when: {
              action_type: 'dividend',
              dividend_kind: 'withhold',
              retention_enables_permanent_train: true,
            },
            score_add: 1500,
          },
          {
            id: 'OR03_half_pay_for_permanent_train',
            description: 'Prefer half pay if partial retention is sufficient to make a permanent train affordable',
            when: {
              action_type: 'dividend',
              dividend_kind_in: %w[half split],
              retention_enables_permanent_train: true,
            },
            score_add: 1600,
          },
          {
            id: 'OR04_avoid_unnecessary_retention',
            description: 'Do not retain revenue unless it enables a permanent train purchase',
            when: {
              action_type: 'dividend',
              retention_enables_permanent_train: false,
            },
            score_add: -1000,
          },

          # --- OPERATING ROUND: 1-TILE & 2-TILE HORIZON TRACK LAYING ---
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
            description: 'Reward laying or upgrading a city/town hex that increases printed revenue',
            when: { action_type: 'lay_tile', has_own_token: false, tile_rev_gain_gt: 0 },
            score_add: 120,
            score_per_unit: { field: 'tile_rev_gain', multiplier: 4.0 },
          },
          {
            id: 'OR_TL05_horizon1_direct_neighbor_target',
            description: '1-Tile Horizon: New exit connects directly to an adjacent city, town, or offboard',
            when: { action_type: 'lay_tile', horizon_1_value_gt: 0 },
            score_add: 140,
            score_per_unit: { field: 'horizon_1_value', multiplier: 4.5 },
          },
          {
            id: 'OR_TL06_horizon2_two_tile_bridge',
            description: '2-Tile Horizon: New exit points across an open neighbor toward a city/offboard 2 hexes away',
            when: { action_type: 'lay_tile', horizon_2_value_gt: 0 },
            score_add: 70,
            score_per_unit: { field: 'horizon_2_value', multiplier: 2.5 },
          },
          {
            id: 'OR_TL07_penalize_map_border_dead_end',
            description: 'Penalize pointing new exits off the board edge or into impassable hexes',
            when: { action_type: 'lay_tile', is_dead_end_edge: true },
            score_add: -250,
          },
          {
            id: 'OR_TL08_half_cost_value_penalty',
            description: 'Penalize terrain cost proportional to expense, especially before owning a train',
            when: { action_type: 'lay_tile', tile_cost_gt: 0 },
            score_add: -20,
            score_per_unit: { field: 'tile_cost', multiplier: -1.5 },
          },
          {
            id: 'OR_TL09_veto_expensive_tile_if_breaks_train_budget',
            description: 'Never spend cash on terrain if trainless and it drops cash below cheapest depot train',
            when: { action_type: 'lay_tile', breaks_train_budget: true },
            score_add: -10_000,
          },

          # --- OPERATING ROUND: TOKENS, DIVIDENDS & TRAINS ---
          {
            id: 'OR01_payout_if_revenue',
            description: 'Payout dividends when revenue is positive',
            when: { action_type: 'dividend', dividend_kind: 'payout', revenue_gt: 0 },
            score_add: 450,
          },
          {
            id: 'OR02_withhold_if_no_train',
            description: 'Withhold revenue if company owns no train and needs cash',
            when: { action_type: 'dividend', dividend_kind: 'withhold', corp_trains_count: 0 },
            score_add: 500,
          },
          {
            id: 'OR03_withhold_if_zero_revenue',
            description: 'Always withhold if route revenue is zero',
            when: { action_type: 'dividend', dividend_kind: 'withhold', revenue: 0 },
            score_add: 600,
          },
          {
            id: 'OR04_buy_depot_train',
            description: 'Buy available train from depot if company has capacity',
            when: { action_type: 'buy_train', train_from_depot: true },
            score_add: 320,
          },
          {
            id: 'OR05_veto_intercompany_train_if_has_train',
            description: 'Veto inter-company train purchases if company already has an operational train',
            when: { action_type: 'buy_train', train_from_depot: false, corp_trains_count_gt: 0 },
            score_add: -10_000,
          },
          {
            id: 'OR06_discard_cheapest_train',
            description: 'Discard the lowest cost train when over train limit',
            when: { action_type: 'discard_train' },
            score_add: 300,
            score_per_unit: { field: 'train_cost', multiplier: -1.0 },
          },
          {
            id: 'OR08_token_lay_baseline',
            when: { action_type: 'place_token' },
            score_add: 150,
          },
          {
            id: 'OR09_choice_baseline',
            when: { action_type: 'choose' },
            score_add: 50,
          },
        ].freeze
      end
    end
  end
end
