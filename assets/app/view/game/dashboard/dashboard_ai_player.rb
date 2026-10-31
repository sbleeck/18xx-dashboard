# assets/app/view/game/dashboard/dashboard_ai_player.rb
# frozen_string_literal: true

require_relative 'ai_expert_rules'
unless defined?(Engine::AutoRouter)
  if RUBY_ENGINE == 'opal'
    require 'engine/auto_router'
  else
    require_relative '../../../../../lib/engine/auto_router'
  end
end

module View
  module Game
    module Dashboard
      class DashboardAiPlayer
        @execution_locks = {}
        @last_invocations = {}

        class << self
          def play(game, routes = [], &process_block)
            @execution_locks ||= {}
            @last_invocations ||= {}
            key = game.object_id
            return false if @execution_locks[key]

            fingerprint = invocation_fingerprint(game)
            now = `Date.now()`.to_f
            previous = @last_invocations[key]
            if previous && previous[:fingerprint] == fingerprint && (now - previous[:time]) < 300
              `console.warn("[AI Expert] Duplicate invocation suppressed.")`
              return false
            end

            @last_invocations[key] = { fingerprint: fingerprint, time: now }
            @execution_locks[key] = true
            begin
              new(game, routes, &process_block).play
            ensure
              @execution_locks.delete(key)
            end
          end

          def reset!(game = nil)
            @execution_locks ||= {}
            @last_invocations ||= {}
            if game
              key = game.object_id
              @execution_locks.delete(key)
              @last_invocations.delete(key)
            else
              @execution_locks.clear
              @last_invocations.clear
            end
          end

          private

          def invocation_fingerprint(game)
            round = game.round
            step = round&.active_step
            entity = begin; step.current_entity if step.respond_to?(:current_entity); rescue StandardError; nil; end
            entity ||= begin; round.current_entity if round.respond_to?(:current_entity); rescue StandardError; nil; end
            entity ||= begin; game.current_entity if game.respond_to?(:current_entity); rescue StandardError; nil; end
            count = if game.respond_to?(:actions)
                      Array(game.actions).size
                    elsif game.respond_to?(:raw_actions)
                      Array(game.raw_actions).size
                    else
                      0
                    end
            [round&.object_id, step&.object_id, entity&.object_id, count].join(':')
          rescue StandardError
            game.object_id.to_s
          end
        end

        def initialize(game, routes = [], &process_block)
          @game = game
          @routes = routes || []
          @process_block = process_block
          @tile_eval_cache = {}
          @token_eval_cache = {}
          @random_target_train_count = {}
        end

        def play
          step = @game.round&.active_step
          return false unless step

          entity = current_acting_entity(step)
          return false unless entity

          round_before = @game.round
          actions = generate_legal_actions(step, entity)
          actions = apply_share_strategy(actions, entity)
          if actions.any? { |action| action.is_a?(Engine::Action::LayTile) }
            actions = actions.reject { |action| action.is_a?(Engine::Action::Pass) }
          end
          return false if actions.empty?

          command_types = actions.map do |action|
            if action.is_a?(Engine::Action::Pass)
              :pass
            elsif action.is_a?(Engine::Action::SellShares) &&
                  entity.respond_to?(:corporation?) &&
                  entity.corporation?
              :issue
            else
              :other
            end
          end

          if command_types.all? { |type| %i[pass issue].include?(type) }
            action = actions.sample

            return false unless action_belongs_to_entity?(action, entity)
            return false unless execution_context_unchanged?(round_before, step, entity)

            @process_block.call(action)

            return true
          end

          # Draft / auction policy:
          # Buying receives 50% of the total probability when at least one legal
          # BuyCompany action exists. All buy actions share that half equally.
          # Legal Bid and Pass actions share the other half equally. Without a
          # buy action, all legal Bid and Pass actions are equally likely.
          draft_action = AiExpertRules.select_draft_action(actions)
          if draft_action
            return false unless action_belongs_to_entity?(draft_action, entity)
            return false unless @game.round.equal?(round_before)
            return false unless @game.round.active_step.equal?(step)
            return false unless current_acting_entity(step).equal?(entity)

            @process_block.call(draft_action)
            return true
          end

          # Generic Choose step: every legal choice has exactly the same probability.
          choose_actions = actions.select { |action| action.is_a?(Engine::Action::Choose) }

          if choose_actions.any?
            action = AiExpertRules.select_uniform_choice(actions)

            return false unless action_belongs_to_entity?(action, entity)
            return false unless @game.round.equal?(round_before)
            return false unless @game.round.active_step.equal?(step)
            return false unless current_acting_entity(step).equal?(entity)

            @process_block.call(action)
            return true
          end

          scored = actions.map do |action|
            features = extract_features(action, step, entity, actions)
            score, rules = AiExpertRules.score_action(action, features, @game)
            { action: action, score: score, rules: rules, features: features }
          end
          scored = AiExpertRules.apply_probability_policy(scored)

          # Every draft/choice option has exactly the same probability.
          choice_items = scored.select { |item| item[:features][:action_type] == 'choose' }
          tile_items = scored.select { |item| item[:features][:action_type] == 'lay_tile' }
          winning = if choice_items.any?
                      chosen_action = AiExpertRules.select_uniform_choice(choice_items.map { |item| item[:action] })
                      choice_items.find { |item| item[:action].equal?(chosen_action) }
                    elsif tile_items.any?
                      # Tile building is selected strictly by the highest recursive
                      # AutoRouter income; ties are random among the joint winners.
                      # First maximise income that is realised immediately on an
                      # already connected, own-token city. Only then compare the
                      # speculative two-build continuation value. This prevents a
                      # remote track lay with an attractive heuristic horizon from
                      # defeating a real revenue upgrade such as I15 tile 53.
                      tile_items.each do |item|
                        features = item[:features]
                        features[:realized_income_gain] = if features[:has_own_token]
                                                            features[:tile_rev_gain].to_i
                                                          else
                                                            0
                                                          end
                      end
                      best_key = tile_items.map do |item|
                        [item[:features][:realized_income_gain].to_i,
                         item[:features][:projected_revenue].to_i]
                      end.max
                      tied = tile_items.select do |item|
                        [item[:features][:realized_income_gain].to_i,
                         item[:features][:projected_revenue].to_i] == best_key
                      end
                      selected = tied.sample
                      chosen = selected[:action]
                      chosen_rotation = chosen.tile.respond_to?(:rotation) ? chosen.tile.rotation : nil
                      chosen_message = "[AI BUILD CHOSEN] hex=#{chosen.hex.id} tile=#{chosen.tile.name} " \
                                       "rotation=#{chosen_rotation} realized_gain=#{best_key[0]} " \
                                       "two_build_value=#{best_key[1]} tied_candidates=#{tied.size} " \
                                       "best_second=#{selected[:features][:best_second]}"
                      selected
                    else

                      token_items = scored.select { |item| item[:features][:action_type] == 'place_token' }

                      if token_items.any?
                        profitable = token_items.select do |item|
                          item[:features][:token_revenue_gain].to_i.positive?
                        end

                        if profitable.any?
                          best_gain = profitable.map do |item|
                            item[:features][:token_revenue_gain].to_i
                          end.max

                          profitable.select do |item|
                            item[:features][:token_revenue_gain].to_i == best_gain
                          end.sample
                        else
                          non_tokens = scored.reject do |item|
                            item[:features][:action_type] == 'place_token'
                          end

                          if non_tokens.empty?
                            # Mandatory token-only step, e.g. HomeToken.
                            # All candidates have already passed engine legality checking.
                            # Revenue improvement is irrelevant because the token must be placed.
                            token_items.sample
                          else
                            non_tokens.sort_by! { |item| -item[:score] }
                            AiExpertRules.select_candidate(non_tokens)
                          end
                        end

                      else
                        scored.sort_by! { |item| -item[:score] }
                        AiExpertRules.select_candidate(scored)
                      end
                    end
          return false unless winning

          action = materialize_action_for_dispatch(winning[:action])
          return false unless action
          return false unless action_belongs_to_entity?(action, entity)
          unless @game.round.equal?(round_before) && @game.round.active_step.equal?(step) && current_acting_entity(step).equal?(entity)
            return false
          end

          @process_block.call(action)
          true
        rescue Engine::GameError => e
          `console.warn("[AI Expert] Engine rejected selected action: " + #{e.message})`
          false
        rescue StandardError => e
          `console.error("[AI Expert] Error during single-action dispatch: " + #{e.message})`
          false
        ensure
          @tile_eval_cache.clear if @tile_eval_cache
        end

        # Registry of engine action names to collectors. The registry is deliberately
        # explicit: strategic collectors only run when the CURRENT blocking step exposes
        # one of their action names. Unsupported names are logged and safely fall back
        # to Pass when Pass is available.
        ACTION_REGISTRY = {
          'bankrupt' => :collect_bankruptcy,
          'pass' => :collect_pass,
          'choose' => :collect_choices,
          'bid' => :collect_draft_and_bids,
          'buy_company' => :collect_draft_and_bids,
          'buy_companies' => :collect_draft_and_bids,
          'dividend' => :collect_dividends,
          'payout' => :collect_dividends,
          'withhold' => :collect_dividends,
          'half' => :collect_dividends,
          'split' => :collect_dividends,
          'buy_shares' => :collect_shares,
          'sell_shares' => :collect_shares,
          'par' => :collect_par,
          'buy_train' => :collect_trains,
          'discard_train' => :collect_trains,
          'run_routes' => :collect_routes,
          'lay_tile' => :collect_tiles,
          'place_token' => :collect_tokens,
          'issue' => :collect_issue_shares,
          'issue_shares' => :collect_issue_shares,
          'reissue' => :collect_issue_shares,
          'reissue_shares' => :collect_issue_shares,
          'corporate_sell_shares' => :collect_issue_shares,
          'redeem' => :collect_redeem_shares,
          'redeem_shares' => :collect_redeem_shares,
          'corporate_buy_shares' => :collect_redeem_shares,
        }.freeze

        # Optional operating-round opportunities are not always advertised by
        # step.actions(entity). Probe only the CURRENT blocking step, never a future
        # round step, and let each collector return [] when the opportunity is absent.
        OR_OPPORTUNITY_COLLECTORS = %i[
          collect_or_train_opportunities
          collect_or_company_opportunities
          collect_or_issue_opportunities
          collect_or_redeem_opportunities
        ].freeze

        BACKGROUND_ACTION_PREFIXES = ['program_'].freeze
        BACKGROUND_ACTIONS = %w[end_game log message undo redo].freeze

        def generate_legal_actions(step = nil, entity = nil)
          step ||= @game.round&.active_step
          return [] unless step

          entity ||= current_acting_entity(step)
          return [] unless entity

          step_actions = begin
            Array(step.actions(entity))
          rescue StandardError
            []
          end

          round_actions = begin
            Array(@game.round.actions_for(entity))
          rescue StandardError
            []
          end

          raw = step_actions + round_actions

          actions = raw.compact.map(&:to_s).uniq
          return [] if actions.empty?

          collectors = actions.filter_map { |name| ACTION_REGISTRY[name] }.uniq
          legal = []
          collectors.each do |collector_name|
            legal.concat(Array(send(collector_name, step, entity, actions)))
          rescue StandardError => e
            LOGGER.warn(
              "[AI ACTION REGISTRY] collector=#{collector_name} entity=#{entity_label(entity)} " \
              "failed=#{e.class}: #{e.message}"
            )
          end

          if operating_entity?(entity)
            OR_OPPORTUNITY_COLLECTORS.each do |collector_name|
              discovered = Array(send(collector_name, step, entity, actions))
              unless discovered.empty?
              end
              legal.concat(discovered)
            rescue StandardError => e
              LOGGER.warn(
                "[AI OR OPPORTUNITY] collector=#{collector_name} " \
                "entity=#{entity_label(entity)} failed=#{e.class}: #{e.message}"
              )
            end
          end

          unknown = actions.reject do |name|
            ACTION_REGISTRY.key?(name) || BACKGROUND_ACTIONS.include?(name) ||
              BACKGROUND_ACTION_PREFIXES.any? { |prefix| name.start_with?(prefix) }
          end
          if unknown.any?
            LOGGER.warn(
              "[AI UNRECOGNISED ACTION] step=#{step.class.name} entity=#{entity_label(entity)} " \
              "actions=#{unknown.join(',')}"
            )
          end

          legal = legal.compact.uniq.select { |action| action_belongs_to_entity?(action, entity) }

          # Fail-safe: an unsupported/unmaterialisable step must never invent an action.
          # If the engine offers Pass, return only Pass when no understood candidate exists.
          if legal.empty? && actions.include?('pass')
            fallback = collect_pass(step, entity, actions)
            return fallback if fallback.any?
          end

          legal
        end

        def operating_entity?(entity)
          return false unless @game.round.respond_to?(:operating?) && @game.round.operating?

          (entity.respond_to?(:corporation?) && entity.corporation?) ||
            (entity.respond_to?(:minor?) && entity.minor?)
        rescue StandardError
          false
        end

        def collect_or_train_opportunities(step, entity, actions)
          return [] unless step.respond_to?(:buyable_trains)

          collect_trains(step, entity, (actions + ['buy_train']).uniq)
        end

        def collect_or_company_opportunities(step, entity, _actions)
          buy_step = private_buy_step_for(step, entity)
          return [] unless buy_step

          collect_company_purchases(buy_step, entity)
        end

        # Mirror DashboardActionWindow#render_buyable_companies: private-company
        # buying may be implemented by a different step in the current operating
        # round, even while the visible/current step advertises only Pass.
        def private_buy_step_for(default_step, entity)
          steps = if @game.round.respond_to?(:steps)
                    Array(@game.round.steps)
                  else
                    []
                  end

          found = steps.find do |candidate_step|
            next false unless candidate_step
            next false unless candidate_step.respond_to?(:buyable_companies) ||
                              candidate_step.respond_to?(:can_buy_company?)

            private_companies_for(candidate_step, entity).any?
          rescue StandardError
            false
          end

          found ||= default_step if default_step &&
            (default_step.respond_to?(:buyable_companies) || default_step.respond_to?(:can_buy_company?))
          found
        end

        def private_companies_for(step, entity)
          operating_player = if entity.respond_to?(:player?) && entity.player?
                               entity
                             elsif entity.respond_to?(:owner)
                               entity.owner
                             end
          return [] unless operating_player

          companies = if step.respond_to?(:buyable_companies)
                        begin
                          Array(step.buyable_companies(entity))
                        rescue StandardError
                          []
                        end
                      elsif step.respond_to?(:can_buy_company?) && @game.respond_to?(:companies)
                        Array(@game.companies).select do |company|
                          step.can_buy_company?(entity, company)
                        rescue StandardError
                          false
                        end
                      else
                        []
                      end

          companies.compact
            .reject { |company| company.respond_to?(:closed?) && company.closed? }
            .select do |company|
              company.respond_to?(:owner) && company.owner == operating_player && company.owner != entity
            end
        end

        def collect_or_issue_opportunities(step, entity, actions)
          supports_issue = step.respond_to?(:issuable_shares) ||
            step.respond_to?(:issueable_shares) || step.respond_to?(:issuable_bundles)
          return [] unless supports_issue

          collect_issue_shares(step, entity, (actions + ['issue_shares']).uniq)
        end

        def collect_or_redeem_opportunities(step, entity, actions)
          supports_redeem = step.respond_to?(:redeemable_shares) ||
            step.respond_to?(:redeemable_bundles)
          return [] unless supports_redeem

          collect_redeem_shares(step, entity, (actions + ['redeem_shares']).uniq)
        end

        def current_acting_entity(step)
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

          entity
        end

        private

        def entity_label(entity)
          return 'unknown' unless entity

          if entity.respond_to?(:id) && entity.id
            entity.id.to_s
          elsif entity.respond_to?(:name) && entity.name
            entity.name.to_s
          else
            entity.class.name.to_s
          end
        end

        # Trial search may create detached tile copies with the same tile id.
        # Immediately before dispatch, rebuild LayTile using a currently available
        # supply object. Never send a trial/search object to the engine.
        def materialize_action_for_dispatch(action)
          return action unless action.is_a?(Engine::Action::LayTile)

          wanted = action.tile
          wanted_name = wanted.respond_to?(:name) ? wanted.name : nil
          candidates = @game.respond_to?(:tiles) ? Array(@game.tiles) : []
          supply_tile = candidates.find do |candidate|
            same_name = !wanted_name.nil? && candidate.respond_to?(:name) && candidate.name == wanted_name
            off_map = !candidate.respond_to?(:hex) || candidate.hex.nil?
            available = !@game.respond_to?(:tile_available?) || @game.tile_available?(candidate)
            same_name && off_map && available && !candidate.equal?(action.hex.tile)
          end
          return nil unless supply_tile

          Engine::Action::LayTile.new(
            action.entity,
            hex: action.hex,
            tile: supply_tile,
            rotation: action.rotation,
          )
        rescue StandardError => e
          `console.warn("[AI Expert] Could not rematerialize tile action: " + #{e.message})`
          nil
        end

        def action_belongs_to_entity?(action, expected_entity)
          return false unless action
          return true unless action.respond_to?(:entity)

          action.entity.equal?(expected_entity)
        end

        def execution_context_unchanged?(round, step, entity)
          return false unless @game.round.equal?(round)
          return false unless @game.round.active_step.equal?(step)

          current_acting_entity(step).equal?(entity)
        end

        def underscore(name)
          name.to_s
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
        end

        def corporation_revenue(corp)
          return 0 unless corp
          return corp.last_revenue.to_i if corp.respond_to?(:last_revenue)

          history = corp.respond_to?(:operating_history) ? corp.operating_history : nil
          history && history.last ? history.last[:revenue].to_i : 0
        rescue StandardError
          0
        end

        def extract_features(action, step, entity, all_actions)
          f = {}
          f[:player_cash] = entity.respond_to?(:cash) ? entity.cash : 0
          cert_count =
            if entity.respond_to?(:shares) && @game.respond_to?(:num_certs)
              begin
                @game.num_certs(entity)
              rescue StandardError
                0
              end
            else
              0
            end

          cert_limit =
            if entity.respond_to?(:shares) && @game.respond_to?(:cert_limit)
              begin
                @game.cert_limit(entity)
              rescue StandardError
                999
              end
            else
              999
            end
          f[:cert_count] = cert_count
          f[:cert_limit] = cert_limit
          f[:certs_free] = cert_limit - cert_count

          my_unfloated = @game.corporations.select do |c|
            c.owner == entity && (!c.respond_to?(:floated?) || !c.floated?)
          end
          f[:unfloated_presidencies] = my_unfloated.size

          case action
          when Engine::Action::Pass
            f[:action_type] = 'pass'

          when Engine::Action::BuyShares
            f[:action_type] = 'buy_shares'
            bundle = action.bundle
            corp = bundle&.corporation
            if corp
              f[:corp_id] = corp.id
              f[:is_floated] = corp.respond_to?(:floated?) ? corp.floated? : true
              f[:player_is_president] = (corp.owner == entity)
              f[:other_is_president] = (!corp.owner.nil? && corp.owner != entity)
              f[:player_percent] = entity.respond_to?(:percent_of) ? entity.percent_of(corp) : 0
              f[:corp_trains_count] = corp.respond_to?(:trains) ? corp.trains.size : 0
              f[:share_price] = bundle.price
              is_market = (@game.respond_to?(:share_pool) && bundle.owner == @game.share_pool)
              f[:source] = is_market ? :market : :ipo

              f[:corp_can_buy_train] = corp.cash >= if @game.respond_to?(:depot) && @game.depot.respond_to?(:min_depot_train)
                                                      (@game.depot.min_depot_train&.price || 999)
                                                    else
                                                      100
                                                    end

              opp_percents = @game.players.reject { |p| p == entity }.map { |p| p.percent_of(corp) }
              max_opp = opp_percents.max || 0
              f[:presidency_threatened] = (f[:player_is_president] && max_opp >= (f[:player_percent] - 10))

              f[:market_price_lt_ipo] = bundle.price < corp.par_price.price if is_market && corp.par_price
            end

          when Engine::Action::Par
            f[:action_type] = 'par'
            corp = action.corporation
            sp = action.share_price
            price_val = sp.respond_to?(:price) ? sp.price : sp.to_i
            f[:par_price] = price_val

            needed_shares = if corp.respond_to?(:percent_to_float)
                              (corp.percent_to_float / 10).to_i
                            else
                              6
                            end
            cost_to_self_float = price_val * needed_shares
            f[:can_self_float] = (f[:player_cash] >= cost_to_self_float)

            cheaper_floatable = all_actions.any? do |a|
              if a.is_a?(Engine::Action::Par) && a != action
                p = a.share_price.respond_to?(:price) ? a.share_price.price : a.share_price.to_i
                p < price_val && (f[:player_cash] >= (p * needed_shares))
              else
                false
              end
            end
            f[:cheaper_floatable_par_exists] = cheaper_floatable

          when Engine::Action::SellShares
            f[:action_type] = if entity.respond_to?(:corporation?) && entity.corporation?
                                'issue_shares'
                              else
                                'sell_shares'
                              end
            bundle = action.bundle
            corp = bundle&.corporation
            if corp
              f[:corp_id] = corp.id
              f[:player_is_president_of_sold] = (corp.owner == entity)
              f[:causes_president_dump] =
                (corp.owner == entity && bundle.num_shares >= (corp.presidents_share&.num_shares || 2))
            end
            f[:must_sell] = step.respond_to?(:must_sell?) && step.must_sell?(entity)
            f[:must_sell_or_raise_float_cash] =
              f[:must_sell] || (f[:certs_free] <= 0) || (f[:unfloated_presidencies] > 0)

          when Engine::Action::Dividend
            f[:action_type] = 'dividend'
            f[:dividend_kind] = action.kind
            corp = entity
            f[:corp_trains_count] = corp.respond_to?(:trains) ? corp.trains.size : 0
            f[:revenue] = @routes&.sum { |r| r.respond_to?(:revenue) ? r.revenue.to_i : 0 }.to_i
            f[:withhold_enables_permanent_train] = action.kind.to_s == 'withhold' && can_buy_permanent_train?(corp, f[:revenue])

          when Engine::Action::BuyTrain
            f[:action_type] = 'buy_train'
            train = action.train
            f[:train_from_depot] =
              (train.owner == @game.depot || (train.respond_to?(:from_depot?) && train.from_depot?))
            f[:train_cost] = action.price || train.price || 0
            corp = entity
            f[:corp_trains_count] = corp.respond_to?(:trains) ? corp.trains.size : 0

          when Engine::Action::DiscardTrain
            f[:action_type] = 'discard_train'
            f[:train_cost] = action.train&.price || 0

          when Engine::Action::LayTile
            f[:action_type] = 'lay_tile'
            eval_data = @tile_eval_cache[action] || {}
            f.merge!(eval_data)

          when Engine::Action::PlaceToken
            f[:action_type] = 'place_token'
            f.merge!(@token_eval_cache[action] || {})

          when Engine::Action::Choose
            f[:action_type] = 'choose'
          end

          f
        end

        def collect_pass(step, entity, actions)
          return [] unless actions.include?('pass')
          return [] if step.respond_to?(:must_buy_train?) && step.must_buy_train?(entity)
          return [] if step.respond_to?(:must_lay_tile?) && step.must_lay_tile?(entity)
          return [] if step.respond_to?(:must_sell?) && step.must_sell?(entity)
          return [] if step.respond_to?(:can_pass?) && !step.can_pass?(entity)

          [Engine::Action::Pass.new(entity)]
        end

        def collect_choices(step, entity, actions)
          return [] unless actions.include?('choose')

          choices = if step.respond_to?(:choices_for)
                      begin; step.choices_for(entity); rescue StandardError; nil; end
                    elsif step.respond_to?(:choices)
                      begin; step.choices(entity); rescue StandardError; begin
                        step.choices
                      rescue StandardError
                        nil
                      end; end
                    end

          case choices
          when Hash
            choices.keys.map { |k| Engine::Action::Choose.new(entity, choice: k) }
          when Array
            choices.map { |c| Engine::Action::Choose.new(entity, choice: c) }
          else
            []
          end
        end

        def permanent_train?(train)
          return train.permanent? if train.respond_to?(:permanent?)
          return !train.rusts_on if train.respond_to?(:rusts_on)
          return !train.obsolete_on if train.respond_to?(:obsolete_on)

          false
        rescue StandardError
          false
        end

        def can_buy_permanent_train?(entity, extra_cash = 0)
          cash = (entity.respond_to?(:cash) ? entity.cash.to_i : 0) + extra_cash.to_i
          trains = @game.depot.respond_to?(:depot_trains) ? @game.depot.depot_trains : @game.depot.upcoming
          Array(trains).any? { |t| permanent_train?(t) && t.price.to_i <= cash }
        rescue StandardError
          false
        end

        def same_director_train?(buyer, train)
          seller = train.respond_to?(:owner) ? train.owner : nil
          seller && seller != @game.depot && buyer.respond_to?(:owner) && seller.respond_to?(:owner) && buyer.owner == seller.owner
        rescue StandardError
          false
        end

        def collect_draft_and_bids(step, entity, actions)
          legal = []

          if actions.include?('bid')
            bids = collect_auction_bids(step, entity)
            legal.concat(bids)
          end

          legal.concat(collect_company_purchases(step, entity)) if (actions & %w[buy_company buy_companies]).any?

          legal
        end

        def collect_auction_bids(step, entity)
          return [] unless defined?(Engine::Action::Bid)

          cash = entity.respond_to?(:cash) ? entity.cash.to_i : 0
          return [] unless cash.positive?

          companies = auction_bid_companies(step)
          return [] if companies.empty?

          companies.filter_map do |company|
            current = current_company_bid(step, company)
            price = current.positive? ? current + bid_increment(step, company) : opening_bid(step, company)
            maximum = maximum_bid(step, entity, company, cash)

            next unless price.positive?
            next if price > cash
            next if maximum.positive? && price > maximum

            if step.respond_to?(:can_bid?)
              can_bid = begin
                step.can_bid?(entity, company, price)
              rescue ArgumentError
                begin
                  step.can_bid?(entity, price)
                rescue ArgumentError
                  begin
                    step.can_bid?(entity, company)
                  rescue StandardError
                    false
                  end
                rescue StandardError
                  false
                end
              rescue StandardError
                false
              end
              next unless can_bid
            end

            Engine::Action::Bid.new(entity, company: company, price: price)
          rescue StandardError
            nil
          end
        end

        def auction_bid_companies(step)
          companies = []

          if step.respond_to?(:auctioning)
            auctioning = begin
              step.auctioning
            rescue StandardError
              nil
            end
            companies << auctioning if auctioning
          end

          companies.concat(Array(step.available)) if companies.empty? && step.respond_to?(:available)

          companies.concat(Array(step.companies)) if companies.empty? && step.respond_to?(:companies)

          companies.concat(Array(@game.companies)) if companies.empty? && @game.respond_to?(:companies)

          companies.compact.uniq.reject do |company|
            company.respond_to?(:closed?) && company.closed?
          end
        rescue StandardError
          []
        end

        def current_company_bid(step, company)
          values = []

          if step.respond_to?(:highest_bid)
            highest = begin
              step.highest_bid(company)
            rescue ArgumentError
              begin
                step.highest_bid
              rescue StandardError
                nil
              end
            rescue StandardError
              nil
            end

            if highest.respond_to?(:price)
              values << highest.price.to_i
            elsif highest.is_a?(Numeric)
              values << highest.to_i
            end
          end

          if step.respond_to?(:current_bid)
            current = begin
              step.current_bid(company)
            rescue ArgumentError
              begin
                step.current_bid
              rescue StandardError
                nil
              end
            rescue StandardError
              nil
            end

            if current.respond_to?(:price)
              values << current.price.to_i
            elsif current.is_a?(Numeric)
              values << current.to_i
            end
          end

          if step.respond_to?(:bids)
            bids = begin
              step.bids
            rescue StandardError
              nil
            end

            relevant = if bids.is_a?(Hash)
                         bids[company] ||
                           (company.respond_to?(:id) && bids[company.id]) ||
                           (company.respond_to?(:id) && bids[company.id.to_s]) ||
                           bids.values.flatten
                       else
                         bids
                       end

            Array(relevant).each do |bid|
              next if bid.respond_to?(:company) && bid.company != company

              if bid.respond_to?(:price)
                values << bid.price.to_i
              elsif bid.is_a?(Numeric)
                values << bid.to_i
              elsif bid.is_a?(Array)
                numeric = bid.reverse.find { |value| value.is_a?(Numeric) }
                values << numeric.to_i if numeric
              end
            end
          end

          values.max.to_i
        rescue StandardError
          0
        end

        def bid_increment(step, company)
          value = begin; step.min_increment(company) if step.respond_to?(:min_increment); rescue StandardError; nil; end
          value ||= begin; step.bid_increment(company) if step.respond_to?(:bid_increment); rescue StandardError; nil; end
          value = 5 unless value.to_i.positive?
          value.to_i
        end

        def opening_bid(step, company)
          value = begin; step.min_bid(company) if step.respond_to?(:min_bid); rescue StandardError; nil; end
          value ||= company.min_price if company.respond_to?(:min_price)
          value ||= company.value if company.respond_to?(:value)
          value.to_i
        end

        def maximum_bid(step, entity, company, cash)
          value = begin; step.max_bid(entity, company) if step.respond_to?(:max_bid); rescue StandardError; nil; end
          value ||= begin; step.maximum_bid(entity, company) if step.respond_to?(:maximum_bid); rescue StandardError; nil; end
          [value.nil? ? cash : value.to_i, cash].min
        end

        def collect_company_purchases(step, entity)
          return [] unless defined?(Engine::Action::BuyCompany)

          companies = private_companies_for(step, entity)
          cash = entity.respond_to?(:cash) ? entity.cash.to_i : 0

          companies.filter_map do |company|
            min_price = if step.respond_to?(:min_price)
                          begin; step.min_price(company); rescue StandardError; nil; end
                        elsif company.respond_to?(:min_price)
                          company.min_price
                        else
                          1
                        end

            max_price = if step.respond_to?(:max_price)
                          begin; step.max_price(entity, company); rescue StandardError; nil; end
                        elsif company.respond_to?(:max_price)
                          company.max_price
                        else
                          cash
                        end

            next if min_price.nil? || max_price.nil?

            min_price = min_price.to_i
            max_price = [max_price.to_i, cash].min
            next if max_price < min_price

            # User policy: each private gets an independent 30% roll. A successful
            # purchase pays the maximum legal amount the corporation can afford.
            next unless AiExpertRules.buy_private_company?

            Engine::Action::BuyCompany.new(
              entity,
              company: company,
              price: max_price,
            )
          rescue StandardError => e
            LOGGER.warn("[AI PRIVATE PURCHASE] #{e.class}: #{e.message}")
            nil
          end
        end

        def collect_dividends(step, entity, actions)
          return [] unless (actions & %w[dividend payout withhold half split]).any?

          raw_opts =
            if step.respond_to?(:dividend_options)
              begin
                step.dividend_options(entity)
              rescue StandardError
                []
              end
            elsif step.respond_to?(:dividend_types)
              begin
                step.dividend_types
              rescue StandardError
                []
              end
            else
              []
            end

          opts =
            (raw_opts.is_a?(Hash) ? raw_opts.keys : Array(raw_opts))
              .map(&:to_s)

          opts = (actions & %w[payout withhold half split]) if opts.empty?
          opts.reject! { |option| option == 'dividend' }

          has_permanent_train =
            entity.respond_to?(:trains) &&
            Array(entity.trains).any? do |train|
              train.rusts_on.nil? &&
                train.obsolete_on.nil? &&
                !train.rusted
            end

          # Conservative treasury policy:
          #
          # If the corporation does not currently have enough treasury cash to buy
          # the cheapest/next available depot train, withhold whenever withholding
          # is a legal dividend option.
          #
          # Some games provide an entity-specific min_depot_price; otherwise use
          # the standard depot price.
          next_train_price =
            begin
              if @game.respond_to?(:min_depot_price)
                @game.min_depot_price(entity).to_i
              elsif @game.respond_to?(:depot) && @game.depot
                @game.depot.min_depot_price.to_i
              else
                0
              end
            rescue ArgumentError
              begin
                @game.min_depot_price.to_i
              rescue StandardError
                @game.depot&.min_depot_price.to_i
              end
            rescue StandardError
              @game.depot&.min_depot_price.to_i
            end

          corporation_cash =
            entity.respond_to?(:cash) ? entity.cash.to_i : 0

          if !has_permanent_train &&
             next_train_price.positive? &&
             corporation_cash < next_train_price &&
             opts.include?('withhold')
            return [
              Engine::Action::Dividend.new(
                entity,
                kind: 'withhold',
              ),
            ]
          end

          opts.map do |kind|
            Engine::Action::Dividend.new(
              entity,
              kind: kind,
            )
          end
        end

        def apply_share_strategy(actions, entity)
          actions = Array(actions)
          return actions if actions.empty?

          return apply_corporate_share_strategy(actions, entity) if entity.respond_to?(:corporation?) && entity.corporation?

          apply_player_share_focus(actions, entity)
        end

        def apply_player_share_focus(actions, entity)
          return actions unless entity.respond_to?(:player?) && entity.player?

          buy_actions = actions.select do |action|
            action.is_a?(Engine::Action::BuyShares)
          end

          return actions if buy_actions.empty?

          controlled_buys = buy_actions.select do |action|
            corporation = share_action_corporation(action)
            corporation && corporation.owner == entity
          end

          return actions if controlled_buys.empty?

          # Once the player controls a corporation and can legally afford another
          # share in it, continue buying that corporation rather than parring another.
          non_share_actions = actions.reject do |action|
            action.is_a?(Engine::Action::BuyShares) ||
              action.is_a?(Engine::Action::Par)
          end

          controlled_buys + non_share_actions
        end

        def apply_corporate_share_strategy(actions, entity)
          issue_actions = actions.select do |action|
            action.is_a?(Engine::Action::SellShares)
          end

          redeem_actions = actions.select do |action|
            corporate_redeem_action?(action)
          end

          if redeem_actions.any? &&
             AiExpertRules.redeem_shares?(@game, entity)
            return redeem_actions
          end

          if issue_actions.any? &&
             AiExpertRules.issue_shares?(@game, entity)
            return issue_actions
          end

          alternatives = actions.reject do |action|
            issue_actions.include?(action) ||
              redeem_actions.include?(action)
          end

          alternatives.empty? ? actions : alternatives
        end

        def corporate_redeem_action?(action)
          classes = []

          classes << Engine::Action::Redeem if defined?(Engine::Action::Redeem)
          classes << Engine::Action::RedeemShares if defined?(Engine::Action::RedeemShares)
          classes << Engine::Action::CorporateBuyShares if defined?(Engine::Action::CorporateBuyShares)

          # Some games represent treasury redemption using BuyShares with the
          # corporation itself as the acting entity.
          classes << Engine::Action::BuyShares if defined?(Engine::Action::BuyShares)

          classes.any? { |klass| action.is_a?(klass) }
        end

        def share_action_corporation(action)
          return action.bundle.corporation if action.respond_to?(:bundle) && action.bundle

          if action.respond_to?(:shares)
            share = Array(action.shares).first
            return share.corporation if share&.respond_to?(:corporation)
          end

          nil
        rescue StandardError
          nil
        end

        def collect_shares(step, entity, actions)
          return [] if entity.respond_to?(:corporation?) && entity.corporation?
          return [] unless entity.respond_to?(:shares)

          legal = []
          player_cash = entity.respond_to?(:cash) ? entity.cash : 0
          cert_limit = @game.respond_to?(:cert_limit) ? @game.cert_limit(entity) : 999
          current_certs = @game.respond_to?(:num_certs) ? @game.num_certs(entity) : 0

          if actions.include?('buy_shares')
            candidate_bundles = []

            if step.respond_to?(:buyable_shares)
              begin
                candidate_bundles.concat(Array(step.buyable_shares(entity)))
              rescue StandardError
              end
            end
            if step.respond_to?(:buyable_bundles)
              begin
                candidate_bundles.concat(Array(step.buyable_bundles(entity)))
              rescue StandardError
              end
            end

            if candidate_bundles.empty?
              @game.corporations.each do |corp|
                next unless corp.ipoed || corp.share_price

                ipo_shares = if corp.respond_to?(:ipo_shares) && corp.ipo_shares&.any?
                               corp.ipo_shares
                             elsif corp.respond_to?(:shares)
                               corp.shares
                             end || []

                unissued = ipo_shares.select do |s|
                  s.owner == corp || (s.respond_to?(:from_depot?) && s.from_depot?)
                end
                unissued = ipo_shares if unissued.empty?
                unissued.uniq(&:percent).each do |s|
                  candidate_bundles << (s.respond_to?(:to_bundle) ? s.to_bundle : Engine::ShareBundle.new(s))
                end

                pool = @game.respond_to?(:share_pool) ? @game.share_pool : nil
                pool_shares = pool.respond_to?(:shares_of) ? pool.shares_of(corp) : []
                if pool_shares.empty? && @game.respond_to?(:bank) && @game.bank.respond_to?(:shares_of)
                  pool_shares = @game.bank.shares_of(corp)
                end
                pool_shares.uniq(&:percent).each do |s|
                  candidate_bundles << (s.respond_to?(:to_bundle) ? s.to_bundle : Engine::ShareBundle.new(s))
                end
              end
            end

            candidate_bundles.compact.uniq.each do |bnd|
              b = if bnd.respond_to?(:num_shares)
                    bnd
                  elsif bnd.respond_to?(:to_bundle)
                    bnd.to_bundle
                  elsif defined?(Engine::ShareBundle)
                    Engine::ShareBundle.new(bnd)
                  else
                    bnd
                  end
              next unless b
              next if step.respond_to?(:can_buy?) && !step.can_buy?(entity, b)

              b_price = b.respond_to?(:price) ? (b.price || 0) : 0
              next if b_price > player_cash

              shares_count = if b.respond_to?(:num_shares)
                               b.num_shares
                             else
                               (b.respond_to?(:shares) ? b.shares.size : 1)
                             end
              next if current_certs + shares_count > cert_limit
              next if step.respond_to?(:did_sell?) && step.did_sell?(b.corporation, entity)

              raw_shares = if b.respond_to?(:shares) && b.shares&.any?
                             b.shares
                           else
                             Array(b)
                           end

              kwargs = { shares: raw_shares }
              kwargs[:percent] = b.percent if b.respond_to?(:percent) && b.percent
              kwargs[:share_price] = b.share_price if b.respond_to?(:share_price) && b.share_price

              legal << Engine::Action::BuyShares.new(entity, **kwargs)
            end
          end

          if actions.include?('sell_shares')
            corps = @game.corporations.select do |c|
              entity.shares_of(c).any?
            rescue StandardError
              false
            end
            corps.each do |corp|
              bundles = nil
              if step.respond_to?(:sellable_bundles)
                bundles = begin; step.sellable_bundles(entity, corp); rescue StandardError; []; end
              end
              if step.respond_to?(:bundles_for_corporation)
                bundles ||= begin; step.bundles_for_corporation(entity, corp); rescue StandardError; []; end
              end
              Array(bundles).each do |bundle|
                next if step.respond_to?(:can_sell?) && !step.can_sell?(entity, bundle)

                raw_shares = if bundle.respond_to?(:shares) && bundle.shares&.any?
                               bundle.shares
                             else
                               Array(bundle)
                             end

                kwargs = { shares: raw_shares }
                kwargs[:percent] = bundle.percent if bundle.respond_to?(:percent) && bundle.percent
                if bundle.respond_to?(:share_price) && bundle.share_price
                  kwargs[:share_price] =
                    bundle.share_price
                end

                legal << Engine::Action::SellShares.new(entity, **kwargs)
              end
            end
          end

          legal
        end

        def collect_par(step, entity, actions)
          return [] unless actions.include?('par')

          legal = []

          unfloated = @game.corporations.select do |corporation|
            if corporation.respond_to?(:ipoed)
              !corporation.ipoed
            else
              begin
                !corporation.owner
              rescue StandardError
                true
              end
            end
          end

          player_cash =
            entity.respond_to?(:cash) ? entity.cash.to_i : 0

          unfloated.each do |corporation|
            if step.respond_to?(:can_par?)
              can_par =
                begin
                  step.can_par?(corporation, entity)
                rescue ArgumentError
                  step.can_par?(entity, corporation)
                rescue StandardError
                  false
                end

              next unless can_par
            end

            prices =
              if step.respond_to?(:get_par_prices)
                begin
                  Array(step.get_par_prices(entity, corporation))
                rescue StandardError
                  []
                end
              elsif @game.stock_market.respond_to?(:par_prices)
                begin
                  Array(@game.stock_market.par_prices)
                rescue StandardError
                  []
                end
              else
                []
              end

            share_percent =
              if corporation.respond_to?(:share_percent)
                corporation.share_percent.to_i
              else
                10
              end

            share_percent = 10 unless share_percent.positive?

            percent_needed =
              if corporation.respond_to?(:percent_to_float)
                corporation.percent_to_float.to_i
              elsif corporation.respond_to?(:float_percent)
                corporation.float_percent.to_i
              else
                corporation.presidents_share&.percent.to_i
              end

            president_percent =
              corporation.presidents_share&.percent.to_i

            if percent_needed < president_percent
              percent_needed =
                president_percent
            end

            share_units_needed =
              (percent_needed.to_f / share_percent).ceil

            affordable_prices = prices.filter_map do |price_entry|
              share_price =
                price_entry.is_a?(Array) ? price_entry.first : price_entry

              price_value =
                if share_price.respond_to?(:price)
                  share_price.price.to_i
                else
                  share_price.to_i
                end

              total_float_cost =
                price_value * share_units_needed

              next if total_float_cost > player_cash

              slot = nil

              if @game.respond_to?(:par_chart) &&
                 @game.par_chart[share_price]
                slot =
                  begin
                    @game.par_chart[share_price].index(nil)
                  rescue StandardError
                    nil
                  end

                next if slot.nil?
              end

              {
                share_price: share_price,
                price_value: price_value,
                total_float_cost: total_float_cost,
                slot: slot,
              }
            end

            # Choose only the highest legal par price that still leaves enough

            if step.respond_to?(:companies_pending_par)
              pending = Array(step.companies_pending_par).first

              if pending
                corporation =
                  if pending.respond_to?(:corporation?) && pending.corporation?
                    pending
                  elsif pending.respond_to?(:all_abilities)
                    share_ability = pending.all_abilities.find do |ability|
                      ability.respond_to?(:type) &&
                        ability.type == :shares &&
                        ability.respond_to?(:shares) &&
                        ability.shares&.any?
                    end

                    share_ability&.shares&.first&.corporation
                  end

                if corporation
                  prices =
                    begin
                      Array(step.get_par_prices(entity, corporation))
                    rescue StandardError
                      []
                    end

                  best_price = prices
                    .map { |entry| entry.is_a?(Array) ? entry.first : entry }
                    .compact
                    .max_by do |price|
                      price.respond_to?(:price) ? price.price.to_i : price.to_i
                    end

                  if best_price
                    return [
                      Engine::Action::Par.new(
                        entity,
                        corporation: corporation,
                        share_price: best_price,
                      ),
                    ]
                  end
                end
              end
            end
            # purchasing power to reach the corporation's engine-defined float level.
            best = affordable_prices.max_by do |candidate|
              candidate[:price_value]
            end

            next unless best

            kwargs = {
              corporation: corporation,
              share_price: best[:share_price],
            }

            kwargs[:slot] = best[:slot] unless best[:slot].nil?

            president_shares =
              if corporation.respond_to?(:presidents_share) &&
                 corporation.presidents_share
                [corporation.presidents_share]
              else
                []
              end

            begin
              legal << Engine::Action::Par.new(
                entity,
                **kwargs.merge(shares: president_shares)
              )
            rescue ArgumentError => e
              raise unless e.message.to_s.include?('unknown keyword') ||
                           e.message.to_s.include?('shares')

              legal << Engine::Action::Par.new(
                entity,
                **kwargs
              )
            end
          end

          if RUBY_ENGINE != 'opal'
            legal.select! do |action|
              trial = @game.clone(Array(@game.raw_actions))
              mapped = Engine::Action::Base.action_from_h(
                action.to_h,
                trial,
              )

              trial.process_action(
                mapped,
                add_auto_actions: true,
              )

              trial.exception.nil?
            rescue StandardError
              false
            end
          end

          legal
        end

        # Number of distinct trains the current network can actually route next OR.
        # AutoRouter is authoritative here: counting connected stops overstates capacity
        # because several stops may belong to the same overlapping route.
        def drivable_train_capacity(entity)
          limit = @game.respond_to?(:train_limit) ? @game.train_limit(entity).to_i : 1
          limit = 1 unless limit.positive?

          if defined?(Engine::AutoRouter) && entity.respond_to?(:trains) && entity.trains&.any?
            routed_count = 0
            router = Engine::AutoRouter.new(@game, ->(_msg) {})
            router.compute(
              entity,
              routes: [],
              path_timeout: 1000,
              route_timeout: 1500,
              callback: lambda do |computed_routes|
                routed_count = Array(computed_routes).count do |route|
                  route.respond_to?(:chains) && route.chains&.any?
                end
              end
            )
            return [[routed_count, 1].max, limit].min if routed_count.positive?
          end

          # Before the corporation owns a train AutoRouter cannot construct routes.
          # Fall back conservatively: one train for a connected network, never infer
          # multiple trains merely from the number of visible revenue stops.
          connected = begin; @game.graph.connected_nodes(entity); rescue StandardError; []; end
          connected = begin; @game.graph.connected_hexes(entity).keys; rescue StandardError; []; end if Array(connected).empty?
          Array(connected).empty? ? 1 : [1, limit].min
        rescue StandardError
          1
        end

        def collect_bankruptcy(step, entity, actions)
          return [] unless actions.include?('bankrupt')
          return [] unless defined?(Engine::Action::Bankrupt)
          return [] unless entity.respond_to?(:corporation?) && entity.corporation?

          step_actions =
            begin
              Array(step.actions(entity)).map(&:to_s)
            rescue StandardError
              []
            end

          # Bankruptcy is relevant only during the corporation's train-buying step.
          return [] unless step_actions.include?('buy_train')

          must_buy =
            begin
              step.send(:must_buy_train?, entity)
            rescue StandardError
              begin
                @game.must_buy_train?(entity)
              rescue StandardError
                false
              end
            end

          return [] unless must_buy

          # If ANY legal train purchase exists, bankruptcy is not forced.
          buyable_trains =
            begin
              Array(step.buyable_trains(entity))
            rescue StandardError
              []
            end

          buyable_trains.each do |train|
            action = Engine::Action::BuyTrain.new(
              entity,
              train: train,
              price: train.price,
            )

            begin
              trial = @game.clone(Array(@game.raw_actions))
              mapped = Engine::Action::Base.action_from_h(
                action.to_h,
                trial,
              )

              trial.process_action(
                mapped,
                add_auto_actions: true,
              )

              # The corporation can escape bankruptcy by buying this train,
              # including any engine-supported president contribution.
              return [] unless trial.exception
            rescue StandardError
              # Try the next possible train.
            end
          end

          # Only now test whether bankruptcy itself is legal.
          action = Engine::Action::Bankrupt.new(entity)

          if RUBY_ENGINE != 'opal'
            begin
              trial = @game.clone(Array(@game.raw_actions))
              mapped = Engine::Action::Base.action_from_h(
                action.to_h,
                trial,
              )

              trial.process_action(
                mapped,
                add_auto_actions: true,
              )

              return [] if trial.exception
            rescue StandardError
              return []
            end
          end

          [action]
        end

        def collect_trains(step, entity, actions)
          return [] unless actions.include?('buy_train')

          if entity.respond_to?(:trains) && @game.respond_to?(:train_limit) && (entity.trains.size >= @game.train_limit(entity))
            return []
          end

          current_count = entity.respond_to?(:trains) ? entity.trains.size : 0
          useful_count = drivable_train_capacity(entity)

          # Buy enough trains to reach the number the network can drive next OR.
          # Decide the optional +1 exactly once for this corporation while it is in
          # the train-buying step, so repeated AI presses cannot reroll the 20% chance.
          target_key = [@game.round.object_id, step.object_id, entity.object_id].join(':')
          target_count = @random_target_train_count[target_key]
          unless target_count
            limit = @game.respond_to?(:train_limit) ? @game.train_limit(entity).to_i : useful_count + 1
            target_count = AiExpertRules.train_target_count(useful_count, limit)
            @random_target_train_count[target_key] = target_count
          end

          normal_train_needed = current_count < target_count

          optional_progression =
            if RUBY_ENGINE == 'opal'
              !normal_train_needed && AiExpertRules.buy_progression_train?
            else
              false
            end

          return [] unless normal_train_needed || optional_progression

          trains = if step.respond_to?(:buyable_trains)
                     (begin
                    step.buyable_trains(entity); rescue StandardError; []; end)
                   else
                     []
                   end
          b_power = if step.respond_to?(:buying_power)
                      begin; step.buying_power(entity); rescue StandardError; entity.cash; end
                    else
                      (entity.respond_to?(:cash) ? entity.cash : 0)
                    end

          legal = []
          train_candidates = Array(trains)
          train_candidates = train_candidates.first(1) if optional_progression
          train_candidates.each do |train|
            depot_train =
              train.owner == @game.depot ||
              (train.respond_to?(:from_depot?) && train.from_depot?)

            next unless depot_train

            can_buy =
              if step.respond_to?(:can_buy_train?)
                begin
                  step.can_buy_train?(entity, train)
                rescue ArgumentError
                  begin
                    step.can_buy_train?(entity, train, train.price)
                  rescue StandardError
                    false
                  end
                rescue StandardError
                  false
                end
              else
                train.price.to_i <= b_power.to_i
              end

            # Under Opal, retain the lightweight preliminary check.
            #
            # Under CRuby, can_buy_train? may return false for a valid emergency
            # purchase requiring president contribution. Let authoritative clone
            # processing determine legality below.
            next if RUBY_ENGINE == 'opal' && !can_buy

            next if optional_progression && !(entity.respond_to?(:cash) && entity.cash.to_i >= train.price.to_i)

            legal << Engine::Action::BuyTrain.new(
              entity,
              train: train,
              price: train.price,
            )
          end

          if RUBY_ENGINE != 'opal'
            legal.select! do |action|
              trial = @game.clone(Array(@game.raw_actions))
              mapped = Engine::Action::Base.action_from_h(action.to_h, trial)

              trial.process_action(mapped, add_auto_actions: true)

              trial.exception.nil?
            rescue StandardError
              false
            end
          end

          if actions.include?('discard_train')
            discardable = if step.respond_to?(:discardable_trains)
                            begin; step.discardable_trains(entity); rescue StandardError; []; end
                          else
                            (entity.respond_to?(:trains) ? entity.trains : [])
                          end
            Array(discardable).each do |t|
              legal << Engine::Action::DiscardTrain.new(entity, train: t)
            end
          end

          legal
        end

        def collect_issue_shares(step, entity, actions)
          return [] unless (actions & %w[issue issue_shares reissue reissue_shares corporate_sell_shares sell_shares]).any?
          return [] unless entity.respond_to?(:corporation?) && entity.corporation?
          return [] unless defined?(Engine::Action::SellShares)

          issue_step = step

          bundles = []

          %i[issuable_shares issueable_shares issuable_bundles].each do |method_name|
            next unless issue_step.respond_to?(method_name)

            result =
              begin
                issue_step.public_send(method_name, entity)
              rescue ArgumentError
                begin
                  issue_step.public_send(method_name)
                rescue StandardError
                  []
                end
              rescue StandardError
                []
              end

            bundles.concat(Array(result))
          end

          bundles.compact.uniq.filter_map do |bundle|
            raw_shares =
              if bundle.respond_to?(:shares)
                Array(bundle.shares)
              elsif bundle.respond_to?(:to_bundle)
                Array(bundle.to_bundle.shares)
              else
                Array(bundle)
              end

            next if raw_shares.empty?

            kwargs = { shares: raw_shares }
            kwargs[:percent] = bundle.percent if bundle.respond_to?(:percent) && bundle.percent
            kwargs[:share_price] = bundle.share_price if bundle.respond_to?(:share_price) && bundle.share_price

            Engine::Action::SellShares.new(entity, **kwargs)
          rescue StandardError => e
            LOGGER.warn(
              "[AI ISSUE SHARES] rejected candidate: #{e.class}: #{e.message}"
            )
            nil
          end
        end

        def collect_redeem_shares(step, entity, actions)
          return [] unless (actions & %w[redeem redeem_shares corporate_buy_shares buy_shares]).any?
          return [] unless entity.respond_to?(:corporation?) && entity.corporation?

          raw = if step.respond_to?(:redeemable_shares)
                  begin; Array(step.redeemable_shares(entity)); rescue ArgumentError; Array(step.redeemable_shares); end
                elsif step.respond_to?(:redeemable_bundles)
                  begin; Array(step.redeemable_bundles(entity)); rescue ArgumentError; Array(step.redeemable_bundles); end
                elsif step.respond_to?(:buyable_shares)
                  begin; Array(step.buyable_shares(entity)); rescue ArgumentError; Array(step.buyable_shares); end
                else
                  []
                end

          raw.filter_map do |candidate|
            bundle = candidate.respond_to?(:to_bundle) && !candidate.respond_to?(:shares) ? candidate.to_bundle : candidate
            shares = bundle.respond_to?(:shares) ? Array(bundle.shares).flatten.compact : Array(bundle).flatten.compact
            next if shares.empty?

            price = bundle.respond_to?(:price) ? bundle.price.to_i : 0
            next if entity.respond_to?(:cash) && price > entity.cash.to_i

            if actions.include?('redeem_shares') && defined?(Engine::Action::RedeemShares)
              Engine::Action::RedeemShares.new(entity, bundle: bundle, shares: shares)
            elsif actions.include?('redeem') && defined?(Engine::Action::Redeem)
              Engine::Action::Redeem.new(entity, bundle: bundle, shares: shares)
            elsif actions.include?('corporate_buy_shares') && defined?(Engine::Action::CorporateBuyShares)
              Engine::Action::CorporateBuyShares.new(entity, bundle: bundle, shares: shares)
            else
              Engine::Action::BuyShares.new(entity, bundle: bundle, shares: shares)
            end
          rescue StandardError => e
            LOGGER.warn("[AI REDEEM] rejected candidate: #{e.class}: #{e.message}")
            nil
          end
        end

        def collect_routes(_step, entity, actions)
          return [] unless actions.include?('run_routes')

          active_r = @routes&.select do |r|
            r.chains.any?
          rescue StandardError
            false
          end || []

          # If UI routes are not yet populated, invoke Engine::AutoRouter directly
          if active_r.empty? && defined?(Engine::AutoRouter)
            begin
              router = Engine::AutoRouter.new(@game, ->(_msg) {})
              router.compute(
                entity,
                routes: [],
                path_timeout: 1500,
                route_timeout: 2000,
                callback: lambda do |computed|
                  active_r = computed.select { |r| r.chains.any? } if computed
                end
              )
            rescue StandardError => e
              `console.warn("[AI Expert] AutoRouter fallback warning:", #{e.message})`
            end
          end

          # Reject stale UI/AutoRouter routes using trains owned by another corporation.
          active_r = Array(active_r).select do |route|
            train = route.respond_to?(:train) ? route.train : nil
            owner = train.respond_to?(:owner) ? train.owner : nil
            next false unless owner

            owner.equal?(entity) ||
              (owner.respond_to?(:id) && entity.respond_to?(:id) && owner.id.to_s == entity.id.to_s)
          end

          [Engine::Action::RunRoutes.new(entity, routes: active_r)]
        end

        # =========================================================
        # SURGICAL IN-PLACE TILE TRIAL & 2-TILE HORIZON EVALUATOR
        # =========================================================

        def calculate_tile_cost(step, entity, hex, tile)
          return 0 unless entity.respond_to?(:cash)

          cost = 0
          if step.respond_to?(:tile_cost)
            cost = begin
              step.tile_cost(entity, hex, tile)
            rescue ArgumentError
              begin
                step.tile_cost(entity, tile, hex)
              rescue ArgumentError
                begin; step.tile_cost(entity, hex); rescue StandardError; 0; end
              end
            rescue StandardError
              0
            end
          elsif step.respond_to?(:upgrade_cost)
            cost = begin
              step.upgrade_cost(entity, hex, tile)
            rescue StandardError
              0
            end
          end
          cost ||= 0
          cost = hex.cost if cost.zero? && hex.respond_to?(:cost) && hex.cost
          cost.to_i
        end

        def printed_hex_revenue(tile)
          return 0 unless tile

          rev = 0
          if tile.respond_to?(:stops) && tile.stops&.any?
            tile.stops.each do |stop|
              r = if stop.respond_to?(:revenue_to_render)
                    stop.revenue_to_render
                  elsif stop.respond_to?(:revenue)
                    stop.revenue
                  else
                    0
                  end
              val = case r
                    when Numeric then r
                    when Hash then r.values.select { |v| v.is_a?(Numeric) }.max || 0
                    when Array then r.flatten.select { |v| v.is_a?(Numeric) }.max || 0
                    else 0
                    end
              rev += val.to_i
            end
          end
          rev
        rescue StandardError
          0
        end

        def clear_entity_graph_cache(entity)
          return unless @game.respond_to?(:graph) && @game.graph

          if @game.graph.respond_to?(:clear_graph_for)
            @game.graph.clear_graph_for(entity)
          elsif @game.graph.respond_to?(:clear)
            @game.graph.clear
          end
        rescue StandardError
          nil
        end

        def compute_auto_router_revenue(entity, label: nil)
          return nil unless defined?(Engine::AutoRouter)
          return nil unless entity.respond_to?(:trains) && entity.trains&.any?

          best_rev = nil
          callback_finished = false
          started_ms = `Date.now()`.to_f
          clear_entity_graph_cache(entity)
          router = Engine::AutoRouter.new(@game, ->(_msg) {})
          router.compute(
            entity,
            routes: [],
            path_timeout: 250,
            route_timeout: 250,
            callback: lambda do |computed_routes|
              best_rev = Array(computed_routes).sum do |route|
                route.respond_to?(:chains) && route.chains&.any? ? route.revenue.to_i : 0
              rescue StandardError
                0
              end
              callback_finished = true
              elapsed = `Date.now()`.to_f - started_ms
            end
          )

          return nil unless callback_finished

          best_rev
        rescue StandardError => e
          `console.warn("[AI BUILD ROUTER ERROR] " + #{label} + " " + #{e.message})`
          nil
        end

        TILE_SEARCH_TIMEOUT_MS = 5000

        def set_hex_tile_for_trial(hex, tile)
          if hex.respond_to?(:tile=)
            hex.tile = tile
          else
            hex.instance_variable_set(:@tile, tile)
          end
        end

        # IMPORTANT: look-ahead must never move a real tile object from the
        # game's tile supply onto the map. Doing that corrupts tile ownership/counts
        # and the eventual LayTile action is rejected as "tile already on map".
        # Use a detached clone strictly for AutoRouter evaluation.
        def clone_tile_for_trial(tile, rotation)
          trial = begin
            tile.dup
          rescue StandardError
            nil
          end
          return nil unless trial

          trial.rotate!(rotation) if trial.respond_to?(:rotate!)
          trial
        rescue StandardError
          nil
        end

        def with_temporary_tile(entity, hex, source_tile, rotation)
          old_tile = hex.tile
          trial_tile = clone_tile_for_trial(source_tile, rotation)
          return unless trial_tile

          begin
            set_hex_tile_for_trial(hex, trial_tile)
            clear_entity_graph_cache(entity)
            yield trial_tile
          ensure
            set_hex_tile_for_trial(hex, old_tile)
            # Hex#tile= may write a back-reference into the detached trial tile.
            # Remove it so no search artefact can look like a laid supply tile.
            trial_tile.instance_variable_set(:@hex, nil) if trial_tile
            clear_entity_graph_cache(entity)
          end
        end

        def legal_tile_candidates(step, entity)
          connected = begin; step.connected_hexes(entity); rescue StandardError; nil; end if step.respond_to?(:connected_hexes)
          connected ||= begin; @game.graph.connected_hexes(entity); rescue StandardError; {}; end
          candidates = []
          connected.each_key do |hex|
            next unless hex
            next if step.respond_to?(:available_hex) && !step.available_hex(entity, hex)

            tiles = if step.respond_to?(:potential_tiles)
                      begin; step.potential_tiles(entity, hex); rescue StandardError; []; end
                    elsif step.respond_to?(:upgradeable_tiles)
                      begin; step.upgradeable_tiles(entity, hex); rescue StandardError; []; end
                    else
                      []
                    end
            Array(tiles).compact.each do |tile|
              # Never select a tile object that is already installed on a map hex.
              next if tile.respond_to?(:hex) && tile.hex
              next if @game.respond_to?(:tile_available?) && !@game.tile_available?(tile)

              cost = calculate_tile_cost(step, entity, hex, tile)
              next if cost.nil? || (entity.respond_to?(:cash) && entity.cash.to_i < cost.to_i)

              rotations = if step.respond_to?(:legal_tile_rotations)
                            begin; step.legal_tile_rotations(entity, hex, tile); rescue StandardError; []; end
                          else
                            (0..5).to_a
                          end
              Array(rotations).each { |rotation| candidates << [hex, tile, rotation, cost] }
            end
          end
          candidates
        rescue StandardError
          []
        end

        # Synchronous two-build fallback. AutoRouter callbacks are asynchronous in
        # the browser, so temporary-map AutoRouter evaluation cannot safely be used
        # inside this synchronous action dispatcher. Score every legal first build
        # with the expert two-build topology evaluator and log every result.
        def trial_and_evaluate_tile(step, entity, hex, tile, rotation, cost, deadline_ms)
          label = "hex=#{hex.id} tile=#{tile.name} rotation=#{rotation}"
          return nil if `Date.now()`.to_f >= deadline_ms
          return nil if tile.respond_to?(:hex) && tile.hex

          old_tile = hex.tile
          return nil unless old_tile

          old_rotation = tile.respond_to?(:rotation) ? (tile.rotation || 0) : 0
          begin
            tile.rotate!(rotation) if tile.respond_to?(:rotate!)
            legal_rotation = if step.respond_to?(:legal_tile_rotation?)
                               begin; step.legal_tile_rotation?(entity, hex, tile)
                               rescue ArgumentError
                                 begin; step.legal_tile_rotation?(entity, hex, tile, rotation); rescue StandardError; false; end
                               rescue StandardError
                                 false
                               end
                             else
                               true
                             end
            return nil unless legal_rotation

            metrics = AiExpertRules.two_build_tile_features(
              entity: entity,
              hex: hex,
              old_tile: old_tile,
              new_tile: tile,
              cost: cost,
              revenue_for: ->(candidate) { printed_hex_revenue(candidate) },
            )
            first_value = metrics[:tile_rev_gain].to_i + metrics[:horizon_1_value].to_i
            two_build_value = first_value + metrics[:horizon_2_value].to_i
            metrics[:first_revenue] = first_value
            metrics[:projected_revenue] = two_build_value
            metrics[:route_revenue_gain] = two_build_value
            metrics[:best_second] = "topology horizon 2 value=#{metrics[:horizon_2_value].to_i}"
            metrics[:search_timed_out] = false

            metrics
          rescue StandardError => e
            `console.warn("[AI BUILD EVALUATION ERROR] " + #{label} + " " + #{e.message})`
            nil
          ensure
            tile.rotate!(old_rotation) if tile.respond_to?(:rotate!)
          end
        end

        def collect_tiles(step, entity, actions)
          return [] unless actions.include?('lay_tile')
          return [] unless step.respond_to?(:upgradeable_tiles)

          legal = []
          @tile_eval_cache = {}
          approved_hexes = []

          # Use exactly the same engine API as the normal map UI:
          #   step.available_hex -> step.upgradeable_tiles -> tile.legal_rotations
          # Tracker#upgradeable_tiles already applies potential_tiles,
          # tile_valid_for_phase?, upgrades_to?, blocks_lay,
          # legal_tile_rotations, and max-exit restrictions.
          Array(@game.hexes).each do |hex|
            next unless hex

            available = begin
              step.available_hex(entity, hex)
            rescue StandardError => e
              LOGGER.warn(
                "[AI TILE ENGINE LIST] available_hex failed hex=#{hex.id}: #{e.class}: #{e.message}"
              )
              false
            end
            next unless available

            tiles = begin
              Array(step.upgradeable_tiles(entity, hex)).compact
            rescue StandardError => e
              LOGGER.warn(
                "[AI TILE ENGINE LIST] upgradeable_tiles failed hex=#{hex.id}: #{e.class}: #{e.message}"
              )
              []
            end
            next if tiles.empty?

            approved_hexes << hex.id.to_s

            tiles.each do |tile|
              rotations = Array(tile.legal_rotations).compact.map(&:to_i).uniq.sort

              rotations.each do |rotation|
                legal << Engine::Action::LayTile.new(
                  entity,
                  hex: hex,
                  tile: tile,
                  rotation: rotation,
                )
              end
            end
          end

          if RUBY_ENGINE != 'opal'
            legal.select! do |action|
              trial = @game.clone(Array(@game.raw_actions))
              mapped = Engine::Action::Base.action_from_h(action.to_h, trial)

              trial.process_action(mapped, add_auto_actions: true)

              trial.exception.nil?
            rescue StandardError
              false
            end
          end

          legal.uniq! do |action|
            [action.hex.id.to_s, action.tile.name.to_s, action.rotation.to_i]
          end

          legal.sort_by! do |action|
            [action.hex.id.to_s, action.tile.name.to_s, action.rotation.to_i]
          end

          legal
        end

        def token_revenue_gain(entity, city, token, slot)
          before = compute_auto_router_revenue(entity)
          old_tokens = city.tokens.dup
          old_city = token.respond_to?(:city) ? token.city : nil
          old_used = token.respond_to?(:used) ? token.used : nil
          begin
            city.tokens[slot] = token
            token.instance_variable_set(:@city, city)
            token.instance_variable_set(:@used, true)
            clear_entity_graph_cache(entity)
            compute_auto_router_revenue(entity) - before
          ensure
            city.tokens.replace(old_tokens)
            token.instance_variable_set(:@city, old_city)
            token.instance_variable_set(:@used, old_used)
            clear_entity_graph_cache(entity)
          end
        rescue StandardError
          0
        end

        def collect_tokens(step, entity, actions)
          return [] unless actions.include?('place_token') || actions.include?('hex_token')

          if step.respond_to?(:pending_token) &&
   step.respond_to?(:available_tokens)
            legal = []

            Array(@game.hexes).each do |hex|
              next unless hex

              available =
                begin
                  step.available_hex(entity, hex)
                rescue StandardError
                  false
                end

              next unless available

              Array(hex.tile&.cities).each do |city|
                slot =
                  (city.tokens.find_index(&:nil?) if city.respond_to?(:tokens))

                next if slot.nil?

                legal << Engine::Action::PlaceToken.new(
                  entity,
                  city: city,
                  slot: slot,
                )
              end
            end

            if RUBY_ENGINE != 'opal'
              legal.select! do |action|
                trial = @game.clone(Array(@game.raw_actions))
                mapped = Engine::Action::Base.action_from_h(
                  action.to_h,
                  trial,
                )

                trial.process_action(
                  mapped,
                  add_auto_actions: true,
                )

                trial.exception.nil?
              rescue StandardError
                false
              end
            end

            return legal
          end

          unplaced = if step.respond_to?(:available_tokens)
                       begin
                         Array(step.available_tokens(entity))
                       rescue StandardError
                         []
                       end
                     elsif entity.respond_to?(:tokens_by_type)
                       entity.tokens_by_type.reject(&:used)
                     elsif entity.respond_to?(:unplaced_tokens)
                       entity.unplaced_tokens
                     elsif entity.respond_to?(:tokens)
                       entity.tokens.reject(&:used)
                     else
                       []
                     end
          return [] if unplaced.empty?

          token_to_place = unplaced.first
          legal = []

          # Mirror CitySlot#flash_token_slot? from dashboard_map.rb
          breathing_hexes = @game.hexes.select do |hex|
            next false unless hex && hex.tile

            begin
              step.available_hex(entity, hex)
            rescue StandardError
              false
            end
          end

          breathing_hexes.each do |hex|
            cities = hex.tile.cities || []
            cities.each do |city|
              already_tokened = (city.respond_to?(:tokened_by?) && city.tokened_by?(entity)) ||
                                (city.respond_to?(:tokens) && city.tokens.compact.any? { |t| t.corporation == entity })
              next if already_tokened

              open_slot = city.respond_to?(:open_slot?) ? city.open_slot?(entity) : city.tokens.any?(&:nil?)
              next unless open_slot

              # Check reservation compatibility
              if city.respond_to?(:reservations) && city.reservations
                res_matching = city.reservations.any? do |r|
                  res_corp = r.respond_to?(:corporation) ? r.corporation : r
                  res_corp.nil? || res_corp == entity || (res_corp.respond_to?(:id) && res_corp.id == entity.id)
                end
                next if !res_matching && city.reservations.compact.size >= city.slots
              end

              slot_index = nil
              if city.respond_to?(:reservations) && city.reservations
                slot_index = city.reservations.index { |r| r == entity || (r.respond_to?(:owner) && r.owner == entity) }
              end
              slot_index = city.tokens.find_index(&:nil?) if slot_index.nil? && city.respond_to?(:tokens) && city.tokens
              next if slot_index.nil?

              if step.respond_to?(:can_place_token?)
                can_place = begin
                  step.can_place_token?(entity, city, token_to_place)
                rescue ArgumentError
                  begin
                    step.can_place_token?(entity, city)
                  rescue StandardError
                    true
                  end
                rescue StandardError
                  true
                end
                next unless can_place
              end

              action_args = { city: city, slot: slot_index }
              action_args[:token_type] = token_to_place.type if token_to_place.respond_to?(:type)

              legal << Engine::Action::PlaceToken.new(entity, **action_args)
            end
          end

          legal
        end
      end
    end
  end
end
