# frozen_string_literal: true

require 'lib/settings'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    class DashboardUpcomingTrains < Snabberb::Component
      include Lib::Settings
      include View::Game::Dashboard::RailcardHelper

      needs :game

      FONT_STD = '"Helvetica Neue", Helvetica, Arial, sans-serif'
      FONT_MONEY = '"Courier New", Courier, monospace'
      FONT_CASH = '"Arial Black", Gadget, sans-serif'
      COLOR_CASH = '#4b0082' # Dark Purple (Indigo)

      def train_phase(train)
        return train.available_on.to_s if train.respond_to?(:available_on) && train.available_on

        if train.respond_to?(:phase) && train.phase
          ph = train.phase
          return ph.name.to_s if ph.respond_to?(:name)
          return (ph[:name] || ph['name']).to_s if ph.is_a?(Hash) && (ph[:name] || ph['name'])
          return ph.to_s if ph.is_a?(String) || ph.is_a?(Symbol)
        end

        phases = if @game.respond_to?(:phases) && @game.phases.is_a?(Array)
                   @game.phases
                 elsif @game.respond_to?(:phase) && @game.phase.respond_to?(:phases)
                   @game.phase.phases
                 end

        if phases
          matching = phases.find do |p|
            p[:train].to_s == train.sym.to_s ||
              p[:name].to_s == train.name.to_s ||
              p[:name].to_s == train.sym.to_s ||
              (p[:trains] && Array(p[:trains]).map(&:to_s).include?(train.sym.to_s))
          end
          return matching[:name].to_s if matching

          if train.name.to_s =~ /^(\d+)[^0-9]/
            base = Regexp.last_match(1)
            return base if phases.any? { |p| p[:name].to_s == base }
          end

          return phases.first[:name].to_s if @depot&.trains && train == @depot.trains.first
        end

        train.sym.to_s
      end

      def train_phase_details(train)
        details = []
        rust_details = []

        all_trains = (@game.respond_to?(:trains) && @game.trains) || (@depot.respond_to?(:trains) && @depot.trains) || []

        rusts = all_trains.select do |t|
          Array(t.rusts_on).map(&:to_s).include?(train.sym.to_s) || Array(t.rusts_on).map(&:to_s).include?(train.name.to_s)
        end.map(&:name).uniq
        rust_details << "Rusts: #{rusts.join(', ')} train#{'s' if rusts.size > 1}" if rusts.any?

        obsoletes = all_trains.select do |t|
          Array(t.obsolete_on).map(&:to_s).include?(train.sym.to_s) || Array(t.obsolete_on).map(&:to_s).include?(train.name.to_s)
        end.map(&:name).uniq
        rust_details << "Phases out: #{obsoletes.join(', ')}" if obsoletes.any?

        rust_details << "Rusted later by: #{Array(train.rusts_on).join(', ')}" if train.rusts_on && !train.rusts_on.empty?
        if train.obsolete_on && !train.obsolete_on.empty?
          rust_details << "Obsoleted later by: #{Array(train.obsolete_on).join(', ')}"
        end

        phases = if @game.respond_to?(:phases) && @game.phases.is_a?(Array)
                   @game.phases
                 elsif @game.respond_to?(:phase) && @game.phase.respond_to?(:phases)
                   @game.phase.phases
                 end

        phase_name = nil
        if phases
          phase = phases.find { |p| p[:name].to_s == train.name.to_s || p[:train].to_s == train.sym.to_s }
          if phase
            phase_name = phase[:name].to_s
            if phase[:tiles] && !phase[:tiles].empty?
              details << "Tiles: #{Array(phase[:tiles]).map(&:to_s).map(&:capitalize).join(', ')} available"
            end
            details << "Operating Rounds: #{phase[:operating_rounds]}" if phase[:operating_rounds]

            if phase[:train_limit]
              limit = if phase[:train_limit].is_a?(Hash)
                        phase[:train_limit].map do |k, v|
                          "#{k}: #{v}"
                        end.join(', ')
                      else
                        phase[:train_limit]
                      end
              details << "Train Limit: #{limit}"
            end

            if phase[:events]
              phase[:events].each do |k, v|
                next unless v

                details << "Event: #{k.to_s.tr('_', ' ').capitalize}"
              end
            end

            if phase[:status]
              Array(phase[:status]).each do |st|
                details << "Status: #{st.to_s.tr('_', ' ').capitalize}"
              end
            end
          end
        end

        if train.events && !train.events.empty?
          train.events.each do |ev|
            ev_name = ev.is_a?(Hash) ? (ev[:type] || ev['type'] || ev.keys.first) : ev
            details << "Event: #{ev_name.to_s.tr('_', ' ').capitalize}" if ev_name
          end
        end

        [phase_name || train_phase(train), details, rust_details]
      end

      def render_train_phase_tooltip(train)
        phase_name, details, rust_details = train_phase_details(train)

        h(:div, {
            attrs: {
              class: 'status-corp-tooltip cmd-corp-tooltip',
            },
            style: {
              display: 'none',
              position: 'fixed',
              top: '50%',
              left: '50%',
              transform: 'translate(-50%, -50%)',
              width: '300px',
              backgroundColor: '#ffffff',
              border: '2px solid #333333',
              borderRadius: '6px',
              padding: '8px',
              boxShadow: '0 8px 24px rgba(0,0,0,0.35)',
              zIndex: '99999',
              pointerEvents: 'none',
              color: '#000000',
              textAlign: 'left',
              boxSizing: 'border-box',
              whiteSpace: 'normal',
              wordBreak: 'break-word',
            },
          }, [
          h(:div, {
              style: {
                backgroundColor: '#1e3a8a',
                color: '#ffffff',
                fontWeight: 'bold',
                fontSize: '0.8rem',
                textAlign: 'center',
                padding: '2px 4px',
                marginBottom: '4px',
                textTransform: 'uppercase',
                borderRadius: '3px',
              },
            }, "Phase Trigger: #{phase_name}"),
          h(:div, {
              style: {
                fontWeight: 'bold',
                fontSize: '0.95rem',
                textAlign: 'center',
                marginBottom: '4px',
                color: '#111111',
              },
            }, "#{train.name} Train (#{@game.format_currency(train.price)})"),
          (if details.any?
             h(:div, { style: { borderTop: '1px solid #ddd', paddingTop: '4px', marginBottom: '4px' } }, [
               h(:div, { style: { fontSize: '0.75rem', fontWeight: 'bold', color: '#1e3a8a', marginBottom: '2px' } },
                 'Phase Changes:'),
               *details.map { |d| h(:div, { style: { fontSize: '0.75rem', marginBottom: '2px', color: '#222222' } }, "• #{d}") },
             ])
           end),
          (if rust_details.any?
             h(:div, { style: { borderTop: '1px solid #ddd', paddingTop: '4px', marginTop: '4px' } }, [
               h(:div, { style: { fontSize: '0.75rem', fontWeight: 'bold', color: '#b91c1c', marginBottom: '2px' } },
                 'Rust & Obsolete Effects:'),
               *rust_details.map do |rd|
                 h(:div, { style: { fontSize: '0.75rem', marginBottom: '2px', color: '#333333', lineHeight: '1.2' } }, "• #{rd}")
               end,
             ])
           end),
          (if details.empty? && rust_details.empty?
             h(:div,
               { style: { borderTop: '1px solid #ddd', paddingTop: '4px', fontSize: '0.75rem', color: '#666666', fontStyle: 'italic', textAlign: 'center' } }, 'No immediate phase changes or rust effects.')
           end),
        ].compact)
      end

      def render
        return nil unless @game.respond_to?(:depot) && @game.depot

        @depot = @game.depot
        return nil if @depot.trains.empty?

        upcoming_by_type = @depot.trains.reject(&:reserved).group_by(&:sym).map do |sym, trains|
          remaining = @depot.upcoming.select { |t| t.sym == sym }
          next nil if remaining.empty?

          train = trains.first
          {
            sym: sym,
            train: train,
            remaining: remaining,
            phase: train_phase(train),
          }
        end.compact

        return nil if upcoming_by_type.empty?

        phase_rows = upcoming_by_type.group_by { |item| item[:phase] }.map do |_phase, items|
          entries = []
          items.each do |item|
            train = item[:train]
            variants = if train.respond_to?(:names_to_prices) && train.names_to_prices && !train.names_to_prices.empty?
                         train.names_to_prices
                       elsif train.respond_to?(:variants) && train.variants && !train.variants.empty?
                         train.variants.map { |k, v| [k, v[:price] || train.price] }.to_h
                       else
                         { train.name || train.sym => train.price }
                       end

            variants.each do |v_name, v_price|
              entries << {
                train: train,
                name: v_name.to_s,
                price: v_price,
                remaining: item[:remaining],
              }
            end
          end

          if entries.size == 1
            entry = entries.first
            train = entry[:train]
            name = entry[:name]
            price = @game.format_currency(entry[:price])
            rem_text = train.unlimited ? '(∞)' : "(#{entry[:remaining].size})"
            tooltip_node = render_train_phase_tooltip(train)
            wrapper_id = "upcoming_train_#{train.id}_#{name.tr('/', '_')}"
            card_node = render_railcard(
              name,
              %w[game-card card-train],
              nil,
              tooltip_node,
              nil,
              wrapper_id,
              %w[status-corp-wrapper cmd-corp-wrapper],
              entity: train
            )

            h(:div, {
                style: {
                  display: 'flex',
                  flexDirection: 'row',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '2px 4px',
                  borderBottom: '1px solid #e0e0e0',
                  gap: '0.5rem',
                },
              }, [
              card_node,
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem', justifyContent: 'flex-end', flex: '1 1 auto' } }, [
                h(:span, { style: { fontFamily: FONT_CASH, color: COLOR_CASH, fontWeight: 'bold', fontSize: '0.85rem' } }, price),
                h(:span,
                  { style: { fontFamily: FONT_STD, fontSize: '0.85rem', fontWeight: 'bold', color: '#000000', minWidth: '1.8rem', textAlign: 'right' } }, rem_text),
              ]),
            ])
          else
            same_remaining = entries.map { |e| e[:remaining].size }.uniq.size == 1 && entries.none? { |e| e[:train].unlimited }
            common_rem = entries.first[:train].unlimited ? '(∞)' : "(#{entries.first[:remaining].size})"

            train_nodes = entries.map do |entry|
              train = entry[:train]
              name = entry[:name]
              price = @game.format_currency(entry[:price])
              rem_text = if same_remaining
                           nil
                         else
                           (train.unlimited ? '(∞)' : "(#{entry[:remaining].size})")
                         end
              tooltip_node = render_train_phase_tooltip(train)
              wrapper_id = "upcoming_train_#{train.id}_#{name.tr('/', '_')}"
              card_node = render_railcard(
                name,
                %w[game-card card-train],
                nil,
                tooltip_node,
                nil,
                wrapper_id,
                %w[status-corp-wrapper cmd-corp-wrapper],
                entity: train
              )

              h(:div, {
                  style: {
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '4px',
                  },
                }, [
                card_node,
                h(:span, { style: { fontFamily: FONT_CASH, color: COLOR_CASH, fontWeight: 'bold', fontSize: '0.82rem' } }, price),
                (if rem_text
                   h(:span, { style: { fontFamily: FONT_STD, fontSize: '0.82rem', fontWeight: 'bold', color: '#000000' } },
                     rem_text)
                 end),
              ].compact)
            end

            h(:div, {
                style: {
                  display: 'flex',
                  flexDirection: 'row',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '2px 4px',
                  borderBottom: '1px solid #e0e0e0',
                  gap: '0.5rem',
                },
              }, [
              h(:div, {
                  style: {
                    display: 'flex',
                    flexDirection: 'row',
                    alignItems: 'center',
                    gap: '0.6rem',
                    flexWrap: 'wrap',
                  },
                }, train_nodes),
              (if same_remaining
                 h(:span, {
                     style: {
                       fontFamily: FONT_STD,
                       fontSize: '0.85rem',
                       fontWeight: 'bold',
                       color: '#000000',
                       minWidth: '1.8rem',
                       textAlign: 'right',
                     },
                   }, common_rem)
               end),
            ].compact)
          end
        end

        visible_rows = phase_rows.take(4)
        hidden_rows = phase_rows.drop(4)

        rows_content = if hidden_rows.empty?
                         visible_rows
                       else
                         details = h(:details, { style: { width: '100%', marginTop: '2px' } }, [
                           h(:summary, {
                               style: {
                                 fontSize: '0.75rem',
                                 textAlign: 'center',
                                 color: COLOR_CASH,
                                 cursor: 'pointer',
                                 padding: '3px 4px',
                                 backgroundColor: '#f0f0f0',
                                 borderRadius: '3px',
                                 fontWeight: 'bold',
                                 listStyle: 'none',
                                 userSelect: 'none',
                               },
                             }, "▼ +#{hidden_rows.size} more..."),
                           h(:div, { style: { display: 'flex', flexDirection: 'column' } }, hidden_rows),
                         ])
                         visible_rows + [details]
                       end

        title_props = {
          attrs: { class: 'column-zone-market' },
          style: {
            padding: '0.3rem',
            backgroundColor: 'var(--bg-market-zone)',
            color: '#000000',
            fontFamily: FONT_STD,
            fontSize: '1.1rem',
            fontWeight: 'bold',
            letterSpacing: '1px',
            textAlign: 'center',
            borderBottom: '1px solid #b3b3b3',
          },
        }

        h('div#upcoming_trains.card.column-zone-market', { style: { minWidth: '240px', maxWidth: '340px' } }, [
          h('div.title', title_props, 'Upcoming Trains'),
          h(:div, { style: { padding: '2px 4px', display: 'flex', flexDirection: 'column' } }, rows_content),
        ])
      end
    end
  end
end
