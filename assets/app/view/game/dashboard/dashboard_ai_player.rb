# assets/app/view/game/dashboard/dashboard_ai_player.rb
# frozen_string_literal: true

require_relative 'ai_expert_rules'

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
          @random_target_train_count = {}
        end

        def play
          step = @game.round&.active_step
          return false unless step

          entity = current_acting_entity(step)
          return false unless entity

          round_before = @game.round
          actions = generate_legal_actions(step, entity)
          return false if actions.empty?

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
            `console.log("[AI Expert] Draft/auction action selected:", #{draft_action.class.name})`
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
            `console.log("[AI Expert] Draft: uniformly selected one of " + #{choose_actions.size}.to_s + " choices")`
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
                      # Building is an optimisation problem, not a weighted lottery.
                      # Choose uniformly only among candidates tied for the highest score.
                      best_score = tile_items.map { |item| item[:score] }.max
                      tile_items.select { |item| item[:score] == best_score }.sample
                    else
                      scored.sort_by! { |item| -item[:score] }
                      AiExpertRules.select_candidate(scored)
                    end
          return false unless winning

          action = winning[:action]
          return false unless action_belongs_to_entity?(action, entity)
          unless @game.round.equal?(round_before) && @game.round.active_step.equal?(step) && current_acting_entity(step).equal?(entity)
            return false
          end

          @process_block.call(action)
          `console.log("[AI Expert] Executed exactly one action:", #{action.class.name})`
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

        def generate_legal_actions(step = nil, entity = nil)
          step ||= @game.round&.active_step
          return [] unless step

          entity ||= current_acting_entity(step)
          return [] unless entity

          raw = begin; step.actions(entity) || []; rescue StandardError; []; end
          raw = begin; @game.round.actions_for(entity) || []; rescue StandardError; []; end if raw.empty?
          actions = raw.compact.map(&:to_s).uniq
          return [] if actions.empty?

          legal = []
          legal.concat(collect_pass(step, entity, actions))
          legal.concat(collect_choices(step, entity, actions))
          legal.concat(collect_draft_and_bids(step, entity, actions))
          legal.concat(collect_dividends(step, entity, actions))
          legal.concat(collect_shares(step, entity, actions))
          legal.concat(collect_par(step, entity, actions))
          legal.concat(collect_trains(step, entity, actions))
          legal.concat(collect_routes(step, entity, actions))
          legal.concat(collect_tiles(step, entity, actions))
          legal.concat(collect_tokens(step, entity, actions))
          legal.select { |a| action_belongs_to_entity?(a, entity) }
        end

        private

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
          cert_count = @game.respond_to?(:num_certs) ? @game.num_certs(entity) : 0
          cert_limit = @game.respond_to?(:cert_limit) ? @game.cert_limit(entity) : 999
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
            f[:action_type] = 'sell_shares'
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

          companies = begin
            step.respond_to?(:buyable_companies) ? Array(step.buyable_companies(entity)) : Array(step.companies)
          rescue StandardError
            []
          end
          candidates = companies.filter_map do |company|
            next if company.respond_to?(:closed?) && company.closed?
            next if company.respond_to?(:owner) && company.owner.equal?(entity)

            price = company.respond_to?(:value) ? company.value.to_i : 0
            next if entity.respond_to?(:cash) && price > entity.cash.to_i

            if step.respond_to?(:can_buy_company?)
              legal = begin
 step.can_buy_company?(entity, company, price)
              rescue ArgumentError; step.can_buy_company?(entity, company); rescue StandardError; false; end
              next unless legal
            end
            Engine::Action::BuyCompany.new(entity, company: company, price: price)
          rescue StandardError
            nil
          end
          candidates
        end

        def collect_dividends(step, entity, actions)
          return [] unless (actions & %w[dividend payout withhold half split]).any?

          raw_opts = if step.respond_to?(:dividend_options)
                       begin; step.dividend_options(entity); rescue StandardError; []; end
                     elsif step.respond_to?(:dividend_types)
                       begin; step.dividend_types; rescue StandardError; []; end
                     else
                       []
                     end

          opts = (raw_opts.is_a?(Hash) ? raw_opts.keys : Array(raw_opts)).map(&:to_s)
          opts = (actions & %w[payout withhold half split]) if opts.empty?
          opts.reject! { |o| o == 'dividend' }

          opts.map { |k| Engine::Action::Dividend.new(entity, kind: k) }
        end

        def collect_shares(step, entity, actions)
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

                unissued = ipo_shares.select { |s| s.owner == corp || (s.respond_to?(:from_depot?) && s.from_depot?) }
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
                kwargs[:share_price] = bundle.share_price if bundle.respond_to?(:share_price) && bundle.share_price

                legal << Engine::Action::SellShares.new(entity, **kwargs)
              end
            end
          end

          legal
        end

        def collect_par(step, entity, actions)
          return [] unless actions.include?('par')

          legal = []
          unfloated = @game.corporations.select do |c|
            if c.respond_to?(:ipoed)
              !c.ipoed
            else
              begin; !c.owner; rescue StandardError; true; end
            end
          end

          player_cash = entity.respond_to?(:cash) ? entity.cash : 0

          unfloated.each do |corp|
            if step.respond_to?(:can_par?)
              can_p = begin
                step.can_par?(corp, entity)
              rescue ArgumentError
                step.can_par?(entity, corp)
              rescue StandardError
                false
              end
              next unless can_p
            end

            prices = if step.respond_to?(:get_par_prices)
                       begin; step.get_par_prices(entity, corp); rescue StandardError; []; end
                     elsif @game.stock_market.respond_to?(:par_prices)
                       begin; @game.stock_market.par_prices; rescue StandardError; []; end
                     else
                       []
                     end

            multiplier = corp.presidents_share&.num_shares || 2

            Array(prices).each do |sp|
              p_obj = sp.is_a?(Array) ? sp.first : sp
              price_val = p_obj.respond_to?(:price) ? p_obj.price : p_obj.to_i
              next if (price_val * multiplier) > player_cash

              slot = nil
              if @game.respond_to?(:par_chart) && @game.par_chart[p_obj]
                slot = begin; @game.par_chart[p_obj].index(nil); rescue StandardError; nil; end
              end
              next if @game.respond_to?(:par_chart) && @game.par_chart[p_obj] && slot.nil?

              kwargs = { corporation: corp, share_price: p_obj }
              kwargs[:slot] = slot if slot
              president_shares = if corp.respond_to?(:presidents_share) && corp.presidents_share
                                   [corp.presidents_share]
                                 else
                                   []
                                 end
              begin
                # Some game-specific Par actions require the president shares explicitly.
                legal << Engine::Action::Par.new(entity, **kwargs.merge(shares: president_shares))
              rescue ArgumentError => e
                # Standard 18xx Par actions derive the shares from the corporation.
                raise unless e.message.to_s.include?('unknown keyword') || e.message.to_s.include?('shares')
                legal << Engine::Action::Par.new(entity, **kwargs)
              end
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

          return [] if current_count >= target_count

          trains = step.respond_to?(:buyable_trains) ? (begin; step.buyable_trains(entity); rescue StandardError; []; end) : []
          b_power = if step.respond_to?(:buying_power)
                      begin; step.buying_power(entity); rescue StandardError; entity.cash; end
                    else
                      (entity.respond_to?(:cash) ? entity.cash : 0)
                    end

          legal = []
          Array(trains).each do |train|
            next if step.respond_to?(:can_buy_train?) && !step.can_buy_train?(entity, train)
            next unless train.owner == @game.depot || (train.respond_to?(:from_depot?) && train.from_depot?)

            legal << Engine::Action::BuyTrain.new(entity, train: train, price: train.price) if train.price.to_i <= b_power.to_i
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

        def compute_auto_router_revenue(entity)
          return 0 unless defined?(Engine::AutoRouter)
          return 0 unless entity.respond_to?(:trains) && entity.trains&.any?

          best_rev = 0
          clear_entity_graph_cache(entity)
          router = Engine::AutoRouter.new(@game, ->(_msg) {})
          router.compute(
            entity,
            routes: [],
            path_timeout: 250,
            route_timeout: 250,
            callback: lambda do |computed_routes|
              if computed_routes
                best_rev = computed_routes.sum do |r|
                  r.chains.any? ? r.revenue : 0
                rescue StandardError
                  0
                end
              end
            end
          )
          best_rev
        rescue StandardError
          0
        end

        # Mechanical adapter: expert policy owns the two-build evaluation.
        def evaluate_horizons_while_mounted(entity, hex, old_tile, new_tile, cost)
          features = AiExpertRules.two_build_tile_features(
            entity: entity,
            hex: hex,
            old_tile: old_tile,
            new_tile: new_tile,
            cost: cost,
            revenue_for: ->(tile) { printed_hex_revenue(tile) },
          )

          min_train_price = if @game.respond_to?(:depot) && @game.depot.respond_to?(:min_depot_train)
                              @game.depot.min_depot_train&.price || 0
                            else
                              0
                            end
          corp_trains = entity.respond_to?(:trains) ? entity.trains.size : 0
          corp_cash = entity.respond_to?(:cash) ? entity.cash : 0
          features[:breaks_train_budget] = corp_trains.zero? && cost.positive? && min_train_price.positive? &&
                                             corp_cash >= min_train_price && (corp_cash - cost) < min_train_price
          features[:route_revenue_gain] = 0
          features
        end

        # Mounts tile at absolute rotation r in-place, verifies all engine restrictions,
        # evaluates Horizon 0/1/2 metrics, and strictly restores state in ensure.
        def trial_and_evaluate_tile(step, entity, hex, tile, r, cost)
          old_tile = hex.tile
          return nil unless old_tile

          original_rotation = tile.rotation || 0
          begin
            # Keep the two-build intelligence, but never mount a trial tile on the live map.
            tile.rotate!(r)
            if step.respond_to?(:legal_tile_rotation?)
              legal_rotation = begin
                step.legal_tile_rotation?(entity, hex, tile)
              rescue ArgumentError
                begin; step.legal_tile_rotation?(entity, hex, tile, r); rescue StandardError; false; end
              rescue StandardError
                false
              end
              return nil unless legal_rotation
            end
            evaluate_horizons_while_mounted(entity, hex, old_tile, tile, cost)
          rescue StandardError
            nil
          ensure
            tile.rotate!(original_rotation)
          end
        end

        # AutoRouter trial mounting is disabled because it changes live tile/undo state.
        # Horizon 1 and Horizon 2 scoring above remain active and non-mutating.

        def collect_tiles(step, entity, actions)
          return [] unless actions.include?('lay_tile')
          return [] if step.respond_to?(:can_lay_tile?) && !step.can_lay_tile?(entity)

          connected = (begin; step.connected_hexes(entity); rescue StandardError; nil; end if step.respond_to?(:connected_hexes))
          connected ||= begin; @game.graph.connected_hexes(entity); rescue StandardError; nil; end
          return [] unless connected && connected.any?

          legal = []
          @tile_eval_cache = {}

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

            available_tiles = Array(tiles).compact.select do |tile|
              count = tile.respond_to?(:count) ? tile.count : nil
              next false if count && count <= 0 && (!tile.respond_to?(:unlimited) || !tile.unlimited)

              if @game.respond_to?(:tile_available?)
                @game.tile_available?(tile)
              elsif @game.respond_to?(:tiles)
                @game.tiles.include?(tile)
              else
                true
              end
            end

            available_tiles.uniq(&:name).each do |tile|
              cost = calculate_tile_cost(step, entity, hex, tile)
              next if cost.nil?
              next if entity.respond_to?(:cash) && entity.cash.to_i < cost.to_i

              rotations = if step.respond_to?(:legal_tile_rotations)
                            begin; step.legal_tile_rotations(entity, hex, tile); rescue StandardError; []; end
                          else
                            (0..5).to_a
                          end

              Array(rotations).each do |r|
                eval_metrics = trial_and_evaluate_tile(step, entity, hex, tile, r, cost)
                next unless eval_metrics

                act = Engine::Action::LayTile.new(entity, hex: hex, tile: tile, rotation: r)
                @tile_eval_cache[act] = eval_metrics
                legal << act
              end
            end
          end

          legal
        end

        def collect_tokens(step, entity, actions)
          return [] unless actions.include?('place_token')
          return [] if step.respond_to?(:can_place_token?) && !step.can_place_token?(entity)

          tokens = if step.respond_to?(:available_tokens)
                     (begin; step.available_tokens(entity); rescue StandardError; []; end)
                   else
                     []
                   end
          tokens = [entity.next_token].compact if (tokens.nil? || tokens.empty?) && entity.respond_to?(:next_token)
          tok = Array(tokens).first
          return [] unless tok

          cost = if step.respond_to?(:token_cost)
                   begin; step.token_cost(entity, tok); rescue StandardError; tok.price; end
                 else
                   tok.price
                 end || 0
          return [] if entity.respond_to?(:cash) && entity.cash < cost

          connected = (begin; step.connected_hexes(entity); rescue StandardError; nil; end if step.respond_to?(:connected_hexes))
          connected ||= begin; @game.graph.connected_hexes(entity); rescue StandardError; nil; end
          return [] unless connected && connected.any?

          legal = []
          connected.each_key do |hex|
            next unless hex&.tile
            next if step.respond_to?(:available_hex) && !step.available_hex(entity, hex)

            hex.tile.cities.each do |city|
              tokenable = city.respond_to?(:tokenable?) && (begin
                city.tokenable?(entity, token: tok)
              rescue StandardError
                begin; city.tokenable?(entity); rescue StandardError; false; end
              end)
              next unless tokenable

              slot = city.tokens.find_index(&:nil?)
              next if slot.nil?

              legal << Engine::Action::PlaceToken.new(entity, city: city, slot: slot, token: tok)
            end
          end

          legal
        end
      end
    end
  end
end
