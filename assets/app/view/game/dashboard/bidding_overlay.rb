# frozen_string_literal: true

# backtick_javascript: true
# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'lib/settings'
require 'lib/storage'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    module Dashboard
      class BiddingOverlay < Snabberb::Component
        include Actionable
        include Lib::Settings
        include View::Game::Dashboard::RailcardHelper

        needs :game, store: true
        needs :game_data, default: nil, store: true
        needs :user, default: nil, store: true
        needs :bidder, default: nil

        FONT_MONEY = '"Courier New", Courier, monospace'
        PRICE_STEP = 5

        def step
          @game.round.active_step
        end

        def entity
          return @bidder if @bidder && !@bidder.is_a?(Engine::Bank)

          candidates = []
          candidates.concat(Array(step.active_entities)) if step&.respond_to?(:active_entities)
          candidates << step.current_entity if step&.respond_to?(:current_entity)
          candidates << @game.round.current_entity if @game.round.respond_to?(:current_entity)
          candidates << @game.current_entity if @game.respond_to?(:current_entity)

          if @game.respond_to?(:active_players_id)
            Array(@game.active_players_id).each do |active_id|
              player = @game.players.find { |p| p.id.to_s == active_id.to_s }
              candidates << player if player
            end
          end

          candidates.concat(@game.players || [])
          candidates = candidates.compact.uniq.reject { |candidate| candidate.is_a?(Engine::Bank) }

          candidates.find do |candidate|
            candidate.respond_to?(:player?) && candidate.player? &&
              begin
                (@game.round.actions_for(candidate) || []).any?
              rescue StandardError
                false
              end
          end || candidates.find { |candidate| candidate.respond_to?(:player?) && candidate.player? }
        rescue NotImplementedError, StandardError
          nil
        end

        def actions
          return [] unless entity
          return @game.round.actions_for(entity) || [] if @game.round.respond_to?(:actions_for)

          step.actions(entity) || []
        rescue NotImplementedError, StandardError
          []
        end

        def target
          return step.auctioning if step.respond_to?(:auctioning) && step.auctioning
          return step.target if step.respond_to?(:target) && step.target

          nil
        rescue StandardError
          nil
        end

        def bid_price(bid)
          bid.respond_to?(:price) ? bid.price.to_i : bid.to_i
        end

        def bids_for(item)
          return [] unless step.respond_to?(:bids)

          bids = step.bids
          list = if bids.is_a?(Hash)
                   bids[item] || bids[item.id] || bids[item.id.to_s] || []
                 else
                   bids
                 end
          # Do not call bid.corporation here. Some auction actions use the
          # bank as their action entity, and Engine::Action::Bid#corporation
          # delegates to entity.corporation, which raises for Engine::Bank.
          # The step has already selected the bid list for this target.
          Array(list).compact
        rescue StandardError
          []
        end

        def minimum_bid(item)
          value = if step.respond_to?(:min_bid)
                    begin
                      step.min_bid(item)
                    rescue ArgumentError
                      step.min_bid
                    end
                  end
          value = value.to_i
          if value.zero?
            highest = bids_for(item).map { |bid| bid_price(bid) }.max
            value = highest ? highest + PRICE_STEP : 0
          end
          value
        rescue StandardError
          100
        end

        def maximum_bid
          item = target
          return entity.cash.to_i if item.nil? && entity.respond_to?(:cash)

          value =
            if step.respond_to?(:max_bid)
              begin
                step.max_bid(entity, item)
              rescue ArgumentError
                step.max_bid(entity)
              end
            elsif entity.respond_to?(:cash)
              entity.cash
            else
              0
            end

          value = value.to_i
          value.positive? ? value : minimum_bid(item)
        rescue StandardError
          entity.respond_to?(:cash) ? entity.cash.to_i : 0
        end

        def company_color(item)
          color = item.respond_to?(:color) ? item.color : nil
          color = item.background_color if item.respond_to?(:background_color)
          color || '#f8fafc'
        rescue StandardError
          '#f8fafc'
        end

        def company_text_color(item)
          color = item.respond_to?(:text_color) ? item.text_color : nil
          color || '#111827'
        rescue StandardError
          '#111827'
        end

        def private?(item)
          item.respond_to?(:company?) && item.company?
        end

        def item_logo(item)
          logo_src = begin
            setting_for(:simple_logos, @game) ? item.simple_logo : item.logo
          rescue StandardError
            nil
          end

          if logo_src
            h(:img, {
                attrs: { src: logo_src, alt: item.name },
                style: {
                  width: '38px',
                  height: '38px',
                  objectFit: 'contain',
                  borderRadius: '6px',
                  backgroundColor: '#ffffff',
                  padding: '2px',
                  boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
                  flexShrink: '0',
                },
              })
          else
            bg = company_color(item)
            h(:div, {
                style: {
                  width: '38px',
                  height: '38px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  backgroundColor: '#ffffff',
                  color: bg,
                  fontWeight: '800',
                  fontSize: '1.15rem',
                  borderRadius: '6px',
                  boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
                  flexShrink: '0',
                  overflow: 'hidden',
                },
              }, item.respond_to?(:sym) ? item.sym : (item.id || item.name[0..2]))
          end
        end

        def render_auction_item_card(item, click_handler: nil, action_class: nil, price: nil, wrapper_id: nil)
          classes = ['game-card']
          classes << action_class if action_class
          classes << 'clickable' if click_handler
          if private?(item)
            label = item.respond_to?(:sym) && item.sym && !item.sym.to_s.empty? ? item.sym.to_s : item.id.to_s
            tooltip = build_entity_tooltip(item, price: price)
            render_railcard(label, classes + ['card-private'], click_handler, tooltip, nil, wrapper_id,
                            %w[cmd-company-wrapper status-company-wrapper], entity: item)
          else
            render_major_railcard(item, click_handler, classes + ['major-railcard'], wrapper_id)
          end
        end

        def render_player_table(item, current_entity)
          bids = bids_for(item)
          highest_bid_overall = bids.max_by { |b| bid_price(b) }
          winner_bidder = if highest_bid_overall
                            highest_bid_overall.respond_to?(:entity) ? highest_bid_overall.entity : highest_bid_overall.bidder
                          end

          auction_players = if step.respond_to?(:bidders) && step.bidders&.any?
                              step.bidders
                            elsif step.respond_to?(:active_bidders) && step.active_bidders&.any?
                              step.active_bidders
                            else
                              @game.players
                            end

          bidders_with_bids = bids.map { |b| b.respond_to?(:entity) ? b.entity : b.bidder }.compact
          all_players = (auction_players + bidders_with_bids).uniq

          cols = all_players.map do |p|
            p_bids = bids.select { |b| (b.respond_to?(:entity) ? b.entity : b.bidder) == p }
            p_highest = p_bids.max_by { |b| bid_price(b) }

            is_current = (p == current_entity)
            is_winner = p == winner_bidder && p_highest

            bg_color = is_current ? '#eff6ff' : '#ffffff'
            border = is_current ? '2px solid #3b82f6' : '1px solid #e2e8f0'

            bid_display = if p_highest
                            val_str = @game.format_currency(bid_price(p_highest))
                            if is_winner
                              h(:div, {
                                  attrs: { title: 'Current Highest Bid' },
                                  style: {
                                    display: 'inline-block',
                                    backgroundColor: '#ffffff',
                                    color: '#4c1d95',
                                    fontFamily: FONT_MONEY,
                                    padding: '2px 8px',
                                    borderRadius: '4px',
                                    fontWeight: 'bold',
                                    border: '2px solid #64748b',
                                    boxShadow: 'none',
                                  },
                                }, "Highest: #{val_str}")
                            else
                              h(:div, { style: { fontWeight: 'bold', color: '#4c1d95', fontFamily: FONT_MONEY } }, val_str)
                            end
                          else
                            h(:div, { style: { color: '#94a3b8', fontStyle: 'italic', fontSize: '0.85rem' } }, '—')
                          end

            h(:div, {
                style: {
                  flex: '1',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  padding: '0.6rem 0.4rem',
                  backgroundColor: bg_color,
                  border: border,
                  borderRadius: '6px',
                  minWidth: '70px',
                  boxShadow: is_current ? '0 2px 4px rgba(59, 130, 246, 0.2)' : 'none',
                },
              }, [
                h(:div, { style: { fontWeight: 'bold', fontSize: '0.9rem', marginBottom: '0.35rem', textAlign: 'center', color: '#0f172a' } }, p.name),
                bid_display,
              ])
          end

          h(:div, {
              style: {
                display: 'flex',
                flexDirection: 'row',
                gap: '0.5rem',
                padding: '0.75rem',
                overflowX: 'auto',
                backgroundColor: '#f8fafc',
              },
            }, cols)
        end

        def begin_drag(event)
          %x(
            var e = #{event};
            var panel = e.currentTarget.closest('#dashboard-bidding-panel, #dashboard-bidding-selection-panel');
            if (!panel || e.target.closest('button,input')) return;
            e.preventDefault();
            var rect = panel.getBoundingClientRect();
            var dx = e.clientX - rect.left;
            var dy = e.clientY - rect.top;
            panel.style.left = rect.left + 'px';
            panel.style.top = rect.top + 'px';
            panel.style.transform = 'none';
            function move(ev) {
              var x = Math.max(0, Math.min(window.innerWidth - panel.offsetWidth, ev.clientX - dx));
              var y = Math.max(0, Math.min(window.innerHeight - panel.offsetHeight, ev.clientY - dy));
              panel.style.left = x + 'px';
              panel.style.top = y + 'px';
            }
            function stop() {
              window.removeEventListener('mousemove', move);
              window.removeEventListener('mouseup', stop);
            }
            window.addEventListener('mousemove', move);
            window.addEventListener('mouseup', stop);
          )
        end

        def selectable_targets
          # In a Stock Round (e.g. 1817 IPO auction), an auction is already
          # bound to a single corporation via step.auctioning; do not mount
          # the multi-item target picker behind the bidding panel.
          is_stock_round = (@game.round.respond_to?(:stock?) && @game.round.stock?) ||
                           @game.round.class.name.to_s.include?('Stock')
          return [] if is_stock_round

          items =
            if step.respond_to?(:visible_corporations)
              step.visible_corporations
            elsif step.respond_to?(:available)
              step.available
            else
              []
            end

          Array(items).compact
        rescue StandardError
          []
        end

        def select_target(item)
          Lib::Storage["dashboard_bidding_selected_target_#{@game.id}"] = item.id.to_s
          update
        end

        def selected_target
          selected_id = Lib::Storage["dashboard_bidding_selected_target_#{@game.id}"]
          return nil unless selected_id

          selectable_targets.find do |item|
            item.respond_to?(:id) && item.id.to_s == selected_id.to_s
          end
        end

        def render_target_picker(bidder)
          items = selectable_targets
          return h(:div, {}) if items.empty?

          cards = items.map do |item|
            click_handler = -> { select_target(item) }
            item_price = minimum_bid(item)
            card = render_auction_item_card(item, click_handler: click_handler, action_class: 'action-buy',
                                                  price: item_price, wrapper_id: "auction_selection_#{item.id}")
            h(:div, {
                attrs: { title: "Select #{item.name} for auction" },
                style: {
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.7rem',
                  width: '100%',
                  minHeight: '3.25rem',
                  padding: '0.55rem 0.7rem',
                  backgroundColor: '#ffffff',
                  border: '1px solid #cbd5e1',
                  borderRadius: '6px',
                  boxSizing: 'border-box',
                  cursor: 'pointer',
                },
                on: { click: click_handler },
              }, [
                card,
                h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', minWidth: '0' } }, [
                  h(:span, { style: { fontWeight: 'bold', color: '#0f172a' } }, item.name.to_s),
                  h(:span, { style: { fontFamily: FONT_MONEY, fontSize: '0.82rem', fontWeight: 'bold', color: '#4c1d95' } },
                    "Minimum bid: #{@game.format_currency(item_price)}"),
                ]),
              ])
          end
          pass_action = -> { process_action(Engine::Action::Pass.new(bidder)) }
          h(:div, {
              attrs: { id: 'dashboard-bidding-selection-panel' },
              style: {
                position: 'fixed',
                top: '1rem',
                left: '50%',
                transform: 'translateX(-50%)',
                width: 'min(760px, 94vw)',
                maxHeight: '90vh',
                overflowY: 'auto',
                zIndex: '100090',
                backgroundColor: '#ffffff',
                border: '1px solid #64748b',
                borderRadius: '9px',
                boxShadow: '0 10px 28px rgba(15, 23, 42, 0.28)',
              },
            }, [
              h(:div, {
                  attrs: { title: 'Drag to move' },
                  style: {
                    padding: '0.75rem 1rem',
                    backgroundColor: '#f8fafc',
                    borderBottom: '1px solid #cbd5e1',
                    cursor: 'move',
                    userSelect: 'none',
                  },
                  on: { mousedown: ->(event) { begin_drag(event) } },
                }, [
                  h(:div, { style: { fontSize: '1.15rem', fontWeight: 'bold', color: '#0f172a' } }, 'Select an Item for Auction'),
                  h(:div, { style: { marginTop: '0.2rem', fontSize: '0.85rem', color: '#64748b' } }, "Active Player: #{bidder.name}"),
                ]),
              h(:div, { style: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: '0.6rem', padding: '0.85rem' } }, cards),
              h(:div, { style: { padding: '0.65rem 0.85rem', borderTop: '1px solid #e2e8f0', display: 'flex', justifyContent: 'flex-end' } }, [
                h(:button, {
                    style: {
                      height: '1.85rem',
                      padding: '0 12px',
                      border: '1px solid #1d4ed8',
                      borderRadius: '5px',
                      backgroundColor: '#2563eb',
                      color: '#ffffff',
                      fontWeight: 'bold',
                      cursor: 'pointer',
                    },
                    on: { click: pass_action },
                  }, 'Pass'),
              ]),
            ])
        end

        def render
          bidder = entity
          return h(:div, {}) unless bidder

          picker_item = selected_target
          item = target || picker_item

          return render_target_picker(bidder) unless item

          # Keep the selection overlay mounted underneath when this auction was
          # entered through the dashboard picker. The bidding panel itself is
          # rendered later at the higher z-index.
          selection_panel = picker_item ? render_target_picker(bidder) : nil

          legal_actions = actions
          return h(:div, {}) unless legal_actions.include?('bid') || legal_actions.include?('pass')

          min_bid = minimum_bid(item)
          max_bid = maximum_bid
          max_bid = min_bid if max_bid < min_bid
          price_key = "dashboard_auction_price_#{item.id}"
          signature_key = "dashboard_auction_signature_#{item.id}"
          signature = "#{min_bid}:#{bids_for(item).length}:#{bidder.respond_to?(:id) ? bidder.id : bidder.name}"
          stored = Lib::Storage[price_key]
          stored_signature = Lib::Storage[signature_key]

          current_price = stored.nil? ? min_bid : stored.to_i
          invalid_signature = stored_signature != signature
          current_price = if stored.nil? || invalid_signature
                            min_bid
                          else
                            [current_price, max_bid].min
                          end

          set_price = lambda do |raw, clamp: true|
            value = raw.to_i
            if clamp
              value = min_bid if value < min_bid
              value = max_bid if value > max_bid
            elsif value > max_bid
              value = max_bid
            end
            Lib::Storage[price_key] = value
            Lib::Storage[signature_key] = signature
            update
          end

          submit_bid = lambda do
            stored_submit_price = Lib::Storage[price_key]
            price = stored_submit_price.nil? ? current_price : stored_submit_price.to_i
            next unless legal_actions.include?('bid') && price >= min_bid && price <= max_bid && (price % PRICE_STEP).zero?

            args = { price: price }
            if private?(item)
              args[:company] = item
            elsif item.respond_to?(:corporation?) && item.corporation?
              args[:corporation] = item
            elsif defined?(Engine::Minor) && item.is_a?(Engine::Minor)
              args[:minor] = item
            else
              args[:company] = item
            end
            Lib::Storage[price_key] = nil
            Lib::Storage[signature_key] = nil
            # Keep the selected target while the auction for this item is active.
            # The selection panel therefore stays mounted through every bid/pass.
            # Once the item is sold, selected_target naturally stops resolving it
            # because it is no longer in selectable_targets.
            process_action(Engine::Action::Bid.new(bidder, **args))
          end

          pass_bid = lambda do
            Lib::Storage[price_key] = nil
            Lib::Storage[signature_key] = nil
            process_action(Engine::Action::Pass.new(bidder))
          end

          button = {
            height: '1.85rem',
            padding: '0 11px',
            border: '1px solid #cbd5e1',
            borderRadius: '5px',
            backgroundColor: '#ffffff',
            color: '#0f172a',
            fontWeight: 'bold',
            cursor: 'pointer',
          }
          minus_disabled = current_price <= min_bid
          plus_disabled = current_price + PRICE_STEP > max_bid
          bid_disabled = !legal_actions.include?('bid') || current_price < min_bid || current_price > max_bid || (current_price % PRICE_STEP != 0)

          item_card = render_auction_item_card(item, action_class: 'action-buy', price: min_bid,
                                                     wrapper_id: "auction_target_#{item.id}")
          header = h(:div, {
                       attrs: { title: 'Drag to move' },
                       style: {
                         padding: '0.6rem 1rem',
                         backgroundColor: '#f8fafc',
                         color: '#0f172a',
                         cursor: 'move',
                         userSelect: 'none',
                         borderBottom: '1px solid #cbd5e1',
                         display: 'flex',
                         alignItems: 'center',
                         gap: '0.75rem',
                       },
                       on: { mousedown: ->(event) { begin_drag(event) } },
                     }, [
              item_card,
              h(:div, { style: { minWidth: '0' } }, [
                h(:div, { style: { fontSize: '1.05rem', lineHeight: '1.2', fontWeight: 'bold' } }, item.name.to_s),
                h(:div, { style: { marginTop: '0.15rem', fontSize: '0.82rem', color: '#64748b' } }, "Bidder: #{bidder.name}"),
              ]),
            ])
          bidding_panel = h(:div, {
                              attrs: { id: 'dashboard-bidding-panel' },
                              style: {
                                position: 'fixed',
                                top: '1rem',
                                left: '50%',
                                transform: 'translateX(-50%)',
                                width: 'min(640px, 94vw)',
                                zIndex: '100100',
                                backgroundColor: '#ffffff',
                                border: '1px solid #64748b',
                                borderRadius: '9px',
                                overflow: 'hidden',
                                boxShadow: '0 10px 28px rgba(15, 23, 42, 0.28)',
                              },
                            }, [
              header,
              render_player_table(item, bidder),
              h(:div, { style: { padding: '0.65rem 0.75rem', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '0.5rem', flexWrap: 'wrap', borderTop: '1px solid #e2e8f0' } }, [
                h(:input, {
                    attrs: {
                      type: 'number',
                      min: min_bid,
                      max: max_bid,
                      step: PRICE_STEP,
                      value: current_price.to_s,
                      inputmode: 'numeric',
                      'aria-label': 'Bid amount',
                    },
                    style: { width: '6rem', height: '1.85rem', boxSizing: 'border-box', fontFamily: FONT_MONEY, fontSize: '1rem', fontWeight: 'bold', color: '#4c1d95', textAlign: 'right' },
                    on: {
                      input: ->(event) { set_price.call(`#{event}.target.value`, clamp: false) },
                      change: ->(event) { set_price.call(`#{event}.target.value`, clamp: true) },
                      keydown: ->(event) { submit_bid.call if `#{event}.key` == 'Enter' },
                    },
                  }),
                h(:button, {
                    attrs: { disabled: minus_disabled },
                    style: button.merge(cursor: minus_disabled ? 'not-allowed' : 'pointer', color: minus_disabled ? '#94a3b8' : '#0f172a'),
                    on: minus_disabled ? {} : { click: -> { set_price.call(current_price - PRICE_STEP, clamp: true) } },
                  }, '-5'),
                h(:button, {
                    attrs: { disabled: plus_disabled },
                    style: button.merge(cursor: plus_disabled ? 'not-allowed' : 'pointer', color: plus_disabled ? '#94a3b8' : '#0f172a'),
                    on: plus_disabled ? {} : { click: -> { set_price.call(current_price + PRICE_STEP) } },
                  }, '+5'),
                h(:button, {
                    attrs: { disabled: bid_disabled },
                    style: button.merge(backgroundColor: bid_disabled ? '#e2e8f0' : '#2563eb', color: bid_disabled ? '#94a3b8' : '#ffffff', border: 'none', cursor: bid_disabled ? 'not-allowed' : 'pointer'),
                    on: bid_disabled ? {} : { click: submit_bid },
                  }, "Bid #{@game.format_currency(current_price)}"),
                (h(:button, { style: button.merge(backgroundColor: '#2563eb', color: '#ffffff', border: '1px solid #1d4ed8'), on: { click: pass_bid } }, 'Pass') if legal_actions.include?('pass')),
              ].compact),
            ].compact)

          return bidding_panel unless selection_panel

          h(:div, {}, [selection_panel, bidding_panel])
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
