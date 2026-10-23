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
            `console.warn("[AI] No legal actions generated for the active state.")`
            return false
          end

          actions.shuffle.each do |act|
            @process_block.call(act)
            `console.log("[AI] Successfully dispatched action:", #{act.class.name})`
            return true
          rescue Engine::GameError, StandardError => e
            `console.warn("[AI] Engine rejected candidate (" + #{act.class.name} + "):", #{e.message})`
          end

          false
        end

        def generate_legal_actions
          step = @game.round.active_step
          return [] unless step

          candidates = resolve_active_entities(step)
          legal = []

          candidates.each do |entity|
            raw_actions = begin
              @game.round.actions_for(entity) || []
            rescue StandardError
              []
            end
            if raw_actions.empty? && step.respond_to?(:actions)
              raw_actions = begin
                step.actions(entity)
              rescue StandardError
                []
              end || []
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

        def resolve_active_entities(step)
          ents = []
          ents << step.current_entity if step.respond_to?(:current_entity) && step.current_entity
          ents.concat(Array(step.active_entities)) if step.respond_to?(:active_entities)
          ents << @game.round.current_entity if @game.round.respond_to?(:current_entity) && @game.round.current_entity
          ents << @game.current_entity if @game.respond_to?(:current_entity) && @game.current_entity

          active_player = ents.find { |e| e.respond_to?(:player?) && e.player? } ||
                          ents.map do |e|
                            e.respond_to?(:owner) ? e.owner : nil
                          end.compact.find { |o| o.respond_to?(:player?) && o.player? }
          ents << active_player if active_player
          ents.compact.uniq
        end

        def collect_pass(_step, entity, actions)
          actions.include?('pass') ? [Engine::Action::Pass.new(entity)] : []
        end

        def collect_choices(step, entity, actions)
          return [] unless actions.include?('choose')

          choices = begin
            if step.respond_to?(:choices_for)
              step.choices_for(entity)
            elsif step.respond_to?(:choices)
              begin
                step.choices(entity)
              rescue StandardError
                step.choices
              end
            end
          rescue StandardError
            nil
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
          opts = (raw_opts.is_a?(Hash) ? raw_opts.keys : Array(raw_opts)).map(&:to_s)
          opts = %w[payout withhold] if opts.empty?
          opts.map { |k| Engine::Action::Dividend.new(entity, kind: k) }
        end

        def collect_shares(step, entity, actions)
          legal = []
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

            if step.respond_to?(:get_par_prices)
              prices = begin
                step.get_par_prices(entity, corp)
              rescue StandardError
                []
              end
            end
            prices ||= begin
              @game.stock_market.par_prices
            rescue StandardError
              []
            end
            Array(prices).each do |sp|
              p_obj = sp.is_a?(Array) ? sp.first : sp
              legal << Engine::Action::Par.new(entity, corporation: corp, share_price: p_obj)
            end
          end
          legal
        end

        def collect_trains(step, entity, actions)
          legal = []
          if actions.include?('buy_train')
            if step.respond_to?(:buyable_trains)
              trains = begin
                step.buyable_trains(entity)
              rescue StandardError
                []
              end
            end
            b_power = if step.respond_to?(:buying_power)
                        begin
                          step.buying_power(entity)
                        rescue StandardError
                          begin
                            entity.cash
                          rescue StandardError
                            0
                          end
                        end
                      else
                        begin
                          entity.cash
                        rescue StandardError
                          0
                        end
                      end

            Array(trains).each do |train|
              next if step.respond_to?(:can_buy_train?) && !step.can_buy_train?(entity, train)

              next unless train.owner == @game.depot || (train.respond_to?(:from_depot?) && train.from_depot?)

              legal << Engine::Action::BuyTrain.new(entity, train: train, price: train.price) if train.price.to_i <= b_power.to_i
            end
          end

          if actions.include?('discard_train')
            discardable = if step.respond_to?(:discardable_trains)
                            begin
                              step.discardable_trains(entity)
                            rescue StandardError
                              []
                            end
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

        def collect_tiles(step, entity, actions)
          return [] unless actions.include?('lay_tile')
          return [] if step.respond_to?(:can_lay_tile?) && !step.can_lay_tile?(entity)

          legal = []
          cand_hexes = @game.hexes.select do |hex|
            step.respond_to?(:available_hex) ? step.available_hex(entity, hex) : true
          rescue StandardError
            false
          end

          cand_hexes.each do |hex|
            pot_tiles = if step.respond_to?(:potential_tiles)
                          begin
                            step.potential_tiles(entity, hex)
                          rescue StandardError
                            []
                          end
                        elsif step.respond_to?(:upgradeable_tiles)
                          begin
                            step.upgradeable_tiles(entity, hex)
                          rescue StandardError
                            []
                          end
                        else
                          []
                        end

            Array(pot_tiles).uniq(&:name).each do |tile|
              orig_rot = tile.rotation || 0
              6.times do
                rot = tile.rotation || 0
                is_legal = begin
                  step.legal_tile_rotation?(entity, hex, tile)
                rescue StandardError
                  false
                end
                legal << Engine::Action::LayTile.new(entity, hex: hex, tile: tile, rotation: rot) if is_legal
                begin
                  tile.rotate!(1)
                rescue StandardError
                  nil
                end
              end
              begin
                tile.rotate!(orig_rot - (tile.rotation || 0))
              rescue StandardError
                (tile.rotation = begin
                  orig_rot
                rescue StandardError
                  nil
                end)
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

          legal = []
          cand_hexes = @game.hexes.select do |hex|
            step.respond_to?(:available_hex) ? step.available_hex(entity, hex) : true
          rescue StandardError
            false
          end

          cand_hexes.each do |hex|
            next unless hex.tile

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

              if tokenable
                slot = city.tokens.index(nil) || 0
                legal << Engine::Action::PlaceToken.new(entity, city: city, slot: slot, token: tok)
              end
            end
          end
          legal
        end
      end
    end
  end
end
