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
            value = highest ? highest + PRICE_STEP : 100
          end
          value
        rescue StandardError
          100
        end

        def maximum_bid
          value = if step.respond_to?(:max_bid)
                    begin
                      step.max_bid(entity)
                    rescue ArgumentError
                      step.max_bid
                    end
                  elsif entity.respond_to?(:cash)
                    entity.cash
                  end
          value = value.to_i
          value.positive? ? value : minimum_bid(target)
        rescue StandardError
          minimum_bid(target)
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

        def render_private_info(item)
          return nil unless private?(item)

          desc_text = if item.respond_to?(:desc) && item.desc && !item.desc.empty?
                        item.desc
                      elsif item.respond_to?(:abilities) && item.abilities&.any?
                        item.abilities.map { |a| a.respond_to?(:description) ? a.description : nil }.compact.join(' ')
                      else
                        'No special abilities.'
                      end

          card = render_railcard(item.name, ['game-card'], nil, nil, nil, nil, nil, entity: item)

          h(:div, {
              style: {
                display: 'flex',
                gap: '1rem',
                padding: '0.75rem',
                backgroundColor: '#f8fafc',
                borderBottom: '1px solid #e2e8f0',
                alignItems: 'center',
              },
            }, [
              h(:div, { style: { flexShrink: '0' } }, [card]),
              h(:div, {
                  style: {
                    fontSize: '0.85rem',
                    lineHeight: '1.4',
                    color: '#334155',
                    fontStyle: 'italic',
                    whiteSpace: 'normal',
                    wordBreak: 'break-word',
                  },
                }, desc_text),
            ])
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
                                    backgroundColor: '#fef08a',
                                    color: '#854d0e',
                                    padding: '2px 8px',
                                    borderRadius: '4px',
                                    fontWeight: 'bold',
                                    border: '1px solid #eab308',
                                    boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                                  },
                                }, "⭐ #{val_str}")
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
            var panel = e.currentTarget.closest('#dashboard-bidding-panel');
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

        def render
          item = target
          bidder = entity
          return h(:div, {}) unless item && bidder

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

          current_price = stored.to_i
          invalid_stored = stored.nil? || stored_signature != signature || current_price < min_bid || current_price > max_bid || (current_price % PRICE_STEP != 0)
          current_price = min_bid if invalid_stored

          set_price = lambda do |raw|
            value = raw.to_i
            value = min_bid if value < min_bid
            value = max_bid if value > max_bid
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

          header_bg = company_color(item)
          header_fg = company_text_color(item)

          header = h(:div, {
                       style: {
                         padding: '0.6rem 1rem',
                         backgroundColor: header_bg,
                         color: header_fg,
                         cursor: 'move',
                         userSelect: 'none',
                         borderBottom: '1px solid rgba(15,23,42,0.25)',
                         display: 'flex',
                         alignItems: 'center',
                         gap: '0.75rem',
                       },
                       on: { mousedown: ->(event) { begin_drag(event) } },
                     }, [
              item_logo(item),
              h(:div, { style: { fontSize: '32px', lineHeight: '38px', fontWeight: 'bold' } }, bidder.name),
            ])

          h(:div, {
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
              render_private_info(item),
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
                      input: ->(event) { set_price.call(`#{event}.target.value`) },
                      change: ->(event) { set_price.call(`#{event}.target.value`) },
                      keydown: ->(event) { submit_bid.call if `#{event}.key` == 'Enter' },
                    },
                  }),
                h(:button, {
                    attrs: { disabled: minus_disabled },
                    style: button.merge(cursor: minus_disabled ? 'not-allowed' : 'pointer', color: minus_disabled ? '#94a3b8' : '#0f172a'),
                    on: minus_disabled ? {} : { click: -> { set_price.call(current_price - PRICE_STEP) } },
                  }, '-5'),
                h(:button, {
                    attrs: { disabled: plus_disabled },
                    style: button.merge(cursor: plus_disabled ? 'not-allowed' : 'pointer', color: plus_disabled ? '#94a3b8' : '#0f172a'),
                    on: plus_disabled ? {} : { click: -> { set_price.call(current_price + PRICE_STEP) } },
                  }, '+5'),
                h(:button, {
                    attrs: { disabled: bid_disabled },
                    style: button.merge(backgroundColor: bid_disabled ? '#e2e8f0' : '#16a34a', color: bid_disabled ? '#94a3b8' : '#ffffff', border: 'none', cursor: bid_disabled ? 'not-allowed' : 'pointer'),
                    on: bid_disabled ? {} : { click: submit_bid },
                  }, "Bid #{@game.format_currency(current_price)}"),
                (h(:button, { style: button.merge(backgroundColor: '#ea7c22', color: '#ffffff', border: 'none'), on: { click: pass_bid } }, 'Pass') if legal_actions.include?('pass')),
              ].compact),
            ].compact)
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
