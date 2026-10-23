# frozen_string_literal: true

module View
  module Game
    module Dashboard
      class DashboardAiPlayer
        def self.play(game, routes = [], &process_block)
          new(game, routes, &process_block).play
        end

        def initialize(game, routes = [], &process_block)
          @game = game
          @routes = routes || []
          @process_block = process_block
        end

        def play
          actions = generate_legal_actions
          if actions.empty?
            `console.warn("[AI] No valid actions available for active entity.")`
            return false
          end

          actions.shuffle.each do |act|
            @process_block.call(act)
            `console.log("[AI] Successfully executed action:", #{act.class.name})`
            return true
          rescue Engine::GameError => e
            `console.warn("[AI] Engine rejected candidate (" + #{act.class.name} + "): " + #{e.message})`
          rescue StandardError => e
            `console.error("[AI] Error during action dispatch (" + #{act.class.name} + "): " + #{e.message})`
          end

          false
        end

        def generate_legal_actions
          step = @game.round.active_step
          return [] unless step

          acting_entities = if step.respond_to?(:active_entities) && step.active_entities&.any?
                              step.active_entities
                            else
                              [step.current_entity || @game.current_entity].compact
                            end

          legal = []

          acting_entities.each do |entity|
            raw_actions = begin
              step.actions(entity)
            rescue StandardError
              []
            end || []
            if raw_actions.empty?
              raw_actions = begin
                @game.round.actions_for(entity)
              rescue StandardError
                []
              end
            end
            actions = raw_actions.compact.map(&:to_s).uniq
            next if actions.empty?

            legal.concat(collect_pass(step, entity, actions))
            legal.concat(collect_choices(step, entity, actions))
            legal.concat(collect_dividends(step, entity, actions))
            legal.concat(collect_shares(step, entity, actions))
            legal.concat(collect_par(step, entity, actions))
            legal.concat(collect_trains(step, entity, actions))
            legal.concat(collect_routes(step, entity, actions))
            legal.concat(collect_tiles(step, entity, actions))
            legal.concat(collect_tokens(step, entity, actions))
          end

          legal
        end

        private

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
            if step.respond_to?(:buyable_shares)
              bundles = begin
                step.buyable_shares(entity)
              rescue StandardError
                []
              end
            end
            Array(bundles).each do |bnd|
              b = bnd.respond_to?(:to_bundle) && !bnd.respond_to?(:num_shares) ? bnd.to_bundle : bnd
              next if step.respond_to?(:can_buy?) && !step.can_buy?(entity, b)
              next if b.price > player_cash

              shares_count = b.respond_to?(:num_shares) ? b.num_shares : b.shares.size
              next if current_certs + shares_count > cert_limit
              next if step.respond_to?(:did_sell?) && step.did_sell?(b.corporation, entity)

              legal << Engine::Action::BuyShares.new(entity, bundle: b)
            end
          end

          if actions.include?('sell_shares')
            corps = @game.corporations.select do |c|
              entity.shares_of(c).any?
            rescue StandardError
              false
            end
            corps.each do |corp|
              if step.respond_to?(:sellable_bundles)
                bundles = begin
                  step.sellable_bundles(entity, corp)
                rescue StandardError
                  []
                end
              end
              if step.respond_to?(:bundles_for_corporation)
                bundles ||= begin
                  step.bundles_for_corporation(entity, corp)
                rescue StandardError
                  []
                end
              end
              Array(bundles).each do |bundle|
                next if step.respond_to?(:can_sell?) && !step.can_sell?(entity, bundle)

                legal << Engine::Action::SellShares.new(entity, bundle: bundle)
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
              begin
                !c.owner
              rescue StandardError
                true
              end
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
                       begin
                         @game.stock_market.par_prices
                       rescue StandardError
                         []
                       end
                     else
                       []
                     end

            multiplier = corp.presidents_share&.num_shares || 2

            Array(prices).each do |sp|
              p_obj = sp.is_a?(Array) ? sp.first : sp
              price_val = p_obj.respond_to?(:price) ? p_obj.price : p_obj.to_i
              next if (price_val * multiplier) > player_cash

              if @game.respond_to?(:par_chart) && @game.par_chart[p_obj]
                slot = begin
                  @game.par_chart[p_obj].index(nil)
                rescue StandardError
                  nil
                end
              end
              next if @game.respond_to?(:par_chart) && @game.par_chart[p_obj] && slot.nil?

              kwargs = { corporation: corp, share_price: p_obj }
              kwargs[:slot] = slot if slot
              legal << Engine::Action::Par.new(entity, **kwargs)
            end
          end

          legal
        end

        def collect_trains(step, entity, actions)
          return [] unless actions.include?('buy_train')

          if entity.respond_to?(:trains) && @game.respond_to?(:train_limit) && (entity.trains.size >= @game.train_limit(entity))
            return []
          end

          if step.respond_to?(:buyable_trains)
            trains = begin
              step.buyable_trains(entity)
            rescue StandardError
              []
            end
          end
          b_power = if step.respond_to?(:buying_power)
                      begin; step.buying_power(entity); rescue StandardError; entity.cash; end
                    else
                      begin
                        entity.cash
                      rescue StandardError
                        0
                      end
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
                            begin
                              entity.trains
                            rescue StandardError
                              []
                            end
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
          [Engine::Action::RunRoutes.new(entity, routes: active_r)]
        end

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

        def collect_tiles(step, entity, actions)
          return [] unless actions.include?('lay_tile')
          return [] if step.respond_to?(:can_lay_tile?) && !step.can_lay_tile?(entity)

          connected = (begin; step.connected_hexes(entity); rescue StandardError; nil; end if step.respond_to?(:connected_hexes))
          connected ||= begin; @game.graph.connected_hexes(entity); rescue StandardError; nil; end
          return [] unless connected && connected.any?

          legal = []

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
              next if entity.respond_to?(:cash) && entity.cash < cost

              # Delegate directly to the engine tracker's rotation evaluator
              rotations = if step.respond_to?(:legal_tile_rotations)
                            begin
                              step.legal_tile_rotations(entity, hex, tile)
                            rescue StandardError
                              []
                            end
                          else
                            []
                          end

              Array(rotations).each do |r|
                legal << Engine::Action::LayTile.new(entity, hex: hex, tile: tile, rotation: r)
              end
            end
          end

          legal
        end

        def collect_tokens(step, entity, actions)
          return [] unless actions.include?('place_token')
          return [] if step.respond_to?(:can_place_token?) && !step.can_place_token?(entity)

          if step.respond_to?(:available_tokens)
            tokens = begin
              step.available_tokens(entity)
            rescue StandardError
              []
            end
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
              tokenable = begin
                if city.respond_to?(:tokenable?)
                  begin
                    city.tokenable?(entity, token: tok)
                  rescue StandardError
                    city.tokenable?(entity)
                  end
                else
                  false
                end
              rescue StandardError
                false
              end
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
