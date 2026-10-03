# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    class DashboardBank < Snabberb::Component
      include Lib::Settings
      include Actionable
      include View::Game::Dashboard::RailcardHelper

      needs :game, store: true
      needs :train_handler, default: nil
      needs :show_loan_table, default: false, store: true

      FONT_STD = '"Helvetica Neue", Helvetica, Arial, sans-serif'
      FONT_MONEY = 'var(--font-money, "Courier New", monospace)'
      COLOR_MONEY = 'var(--color-money-text, #4c1d95)'
      COLOR_BANK_GREEN = 'var(--bg-market-zone, #e6f4ea)'

      def current_entity
        @game.round.active_step&.current_entity ||
          (@game.round.respond_to?(:current_entity) ? @game.round.current_entity : nil) ||
          @game.current_entity
      rescue NotImplementedError, StandardError
        nil
      end

      def actions_for(entity)
        return [] unless entity

        actions = []
        if @game.round.respond_to?(:actions_for)
          begin
            actions.concat(@game.round.actions_for(entity) || [])
          rescue NotImplementedError, StandardError
          end
        end
        step = @game.round.active_step
        if step&.respond_to?(:actions)
          begin
            actions.concat(step.actions(entity) || [])
          rescue NotImplementedError, StandardError
          end
        end
        if step&.respond_to?(:current_actions)
          begin
            actions.concat(step.current_actions || [])
          rescue NotImplementedError, StandardError
          end
        end
        actions.compact.map(&:to_s).uniq
      end

      def active_entity
        current_entity
      end

      def train_available_count(train, variant_name = nil, from_pool: false)
        return '∞' if train.respond_to?(:unlimited) && train.unlimited
        return 0 if train.respond_to?(:rusted) && train.rusted

        if from_pool || @game.depot.discarded.include?(train)
          @game.depot.discarded.count do |t|
            (!t.respond_to?(:rusted) || !t.rusted) && (t.name == train.name || t.sym == train.sym)
          end
        else
          count = @game.depot.upcoming.count do |t|
            (!t.respond_to?(:rusted) || !t.rusted) &&
              (t.name == train.name || t.sym == train.sym ||
                (variant_name && t.respond_to?(:variants) && t.variants&.key?(variant_name)))
          end
          count = 1 if count.zero? && train.owner == @game.depot && !@game.depot.discarded.include?(train)
          count
        end
      end

      def depot_pool_trains
        return [] unless @game.respond_to?(:depot) && @game.depot

        discarded = @game.depot.respond_to?(:discarded) ? (@game.depot.discarded || []) : []
        discarded.reject { |t| t.respond_to?(:rusted) && t.rusted }
                 .select { |t| train_available_count(t, from_pool: true).to_s != '0' }
                 .uniq(&:name)
      end

      def depot_fresh_trains
        return [] unless @game.respond_to?(:depot) && @game.depot

        upcoming = @game.depot.respond_to?(:upcoming) ? (@game.depot.upcoming || []) : []
        upcoming = upcoming.reject { |t| t.respond_to?(:rusted) && t.rusted }
        return [] if upcoming.empty?

        discarded = @game.depot.respond_to?(:discarded) ? (@game.depot.discarded || []) : []

        # Retain buyable step view across turns if available
        step = @game.round.active_step
        buy_step = step if step&.respond_to?(:buyable_trains)
        buy_step = @game.round.steps.find { |s| s.respond_to?(:buyable_trains) } if !buy_step && @game.round.respond_to?(:steps)

        if buy_step
          entity = active_entity || (@game.respond_to?(:current_entity) ? @game.current_entity : nil) || @game.corporations&.first
          if entity
            begin
              buyable = buy_step.buyable_trains(entity) || []
              fresh = buyable.select do |t|
                !discarded.include?(t) &&
                  (upcoming.include?(t) || ((t.respond_to?(:from_depot?) && t.from_depot?) || t.owner == @game.depot))
              end
              fresh = fresh.reject { |t| t.respond_to?(:rusted) && t.rusted }
              return fresh.uniq(&:name) if fresh.any?
            rescue StandardError
            end
          end
        end

        [upcoming.first].compact.uniq(&:name)
      end

      def render_train_cells(item, type, index)
        train = item[:train]
        variant_name = item[:variant_name]
        price = item[:price]

        step = @game.round.active_step
        train_buyable_step = step&.current_actions&.include?('buy_train')
        card_classes = %w[game-card card-train]
        click_handler = nil

        if train_buyable_step && active_entity&.corporation?
          can_afford = active_entity.cash >= price || active_entity.trains.empty?

          if can_afford
            card_classes << 'action-buy'
            card_classes << 'clickable'
            click_handler = lambda {
              variant_str = variant_name.to_s
              if @train_handler
                @train_handler.call(train, price, variant_str, type)
              else
                process_action(Engine::Action::BuyTrain.new(
                  active_entity,
                  train: train,
                  price: price,
                  variant: (variant_str == train.name.to_s ? nil : variant_str)
                ))
              end
            }
          end
        end

        available_count = train_available_count(train, variant_name, from_pool: (type == 'pool'))
        dom_id = "bank_train_#{type}_#{train.id}_#{variant_name.to_s.tr('/', '_')}"
        card_el = render_railcard(variant_name.to_s, card_classes, click_handler, entity: train)

        card_td = h('td.left', { key: "#{dom_id}_card", style: { padding: '4px 6px', verticalAlign: 'middle' } }, [
          h(:div, { attrs: { id: dom_id }, style: { display: 'inline-flex', alignItems: 'center' } }, [card_el]),
        ])

        info_td = h('td.right', { key: "#{dom_id}_info", style: { padding: '4px 6px', verticalAlign: 'middle', whiteSpace: 'nowrap' } }, [
          h(:span,
            { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '0.85rem', fontWeight: 'bold', fontVariantNumeric: 'tabular-nums' } }, @game.format_currency(price)),
          h(:span, { style: { fontFamily: FONT_STD, color: '#555555', fontSize: '0.75rem', marginLeft: '4px' } },
            "(#{available_count})"),
        ])

        [card_td, info_td]
      end

      def render_empty_train_cells(type, index)
        [
          h('td.left', { key: "empty_#{type}_card_#{index}", style: { padding: '4px 6px', verticalAlign: 'middle' } }, ''),
          h('td.right',
            { key: "empty_#{type}_info_#{index}", style: { padding: '4px 6px', verticalAlign: 'middle', whiteSpace: 'nowrap' } }, ''),
        ]
      end

      def render_trains_table
        pool_trains = depot_pool_trains
        fresh_trains = depot_fresh_trains

        return nil if pool_trains.empty? && fresh_trains.empty?

        pool_items = []
        pool_trains.each do |train|
          variants = if train.respond_to?(:names_to_prices) && train.names_to_prices && !train.names_to_prices.empty?
                       train.names_to_prices
                     else
                       { train.name => train.price }
                     end
          variants.each { |variant_name, price| pool_items << { train: train, variant_name: variant_name, price: price } }
        end

        fresh_items = []
        fresh_trains.each do |train|
          variants = if train.respond_to?(:names_to_prices) && train.names_to_prices && !train.names_to_prices.empty?
                       train.names_to_prices
                     else
                       { train.name => train.price }
                     end
          variants.each { |variant_name, price| fresh_items << { train: train, variant_name: variant_name, price: price } }
        end

        return nil if pool_items.empty? && fresh_items.empty?

        max_rows = [pool_items.size, fresh_items.size].max

        trs = [
          h(:tr, { key: 'bank_trains_header' }, [
            h(:th,
              { attrs: { colspan: 2 }, style: { width: '50%', textAlign: 'center', fontFamily: FONT_STD, fontSize: '0.8rem', fontWeight: 'bold' } }, 'Pool'),
            h(:th,
              { attrs: { colspan: 2 }, style: { width: '50%', textAlign: 'center', fontFamily: FONT_STD, fontSize: '0.8rem', fontWeight: 'bold' } }, 'Fresh'),
          ]),
        ]

        max_rows.times do |i|
          p_cells = pool_items[i] ? render_train_cells(pool_items[i], 'pool', i) : render_empty_train_cells('pool', i)
          f_cells = fresh_items[i] ? render_train_cells(fresh_items[i], 'fresh', i) : render_empty_train_cells('fresh', i)

          trs << h(:tr, { key: "bank_trains_row_#{i}" }, [p_cells[0], p_cells[1], f_cells[0], f_cells[1]])
        end

        h(:table, trs)
      end

      def render
        css = <<~CSS
          #spreadsheet #bank,
          #spreadsheet #bank table,
          #spreadsheet #bank tr,
          #spreadsheet #bank th,
          #spreadsheet #bank td,
          #bank,
          #bank table,
          #bank tr,
          #bank th,
          #bank td {
            background-color: #{COLOR_BANK_GREEN} !important;
          }
          #bank.card {
            border: 1px solid #9dc6a7 !important;
            background-color: #{COLOR_BANK_GREEN} !important;
            border-radius: 6px !important;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05) !important;
            overflow: hidden !important;
          }
          #bank table {
            border-collapse: collapse !important;
            border: 1px solid #a7d7b8 !important;
            background-color: #{COLOR_BANK_GREEN} !important;
            width: 100% !important;
            margin: 0 !important;
          }
          #bank table + table {
            margin-top: 4px !important;
          }
          #bank th, #bank td {
            border: 1px solid #c0e0ca !important;
            vertical-align: middle !important;
            padding: 4px 6px !important;
            background-color: #{COLOR_BANK_GREEN} !important;
          }
        CSS

        title_props = {
          attrs: { class: 'column-zone-market' },
          style: {
            padding: '0.35rem',
            backgroundColor: COLOR_BANK_GREEN,
            color: '#111827',
            fontFamily: FONT_STD,
            fontSize: '1rem',
            fontWeight: 'bold',
            letterSpacing: '0.5px',
            textAlign: 'center',
            borderBottom: '1px solid #a7d7b8',
          },
        }

        h('div#bank.card.column-zone-market', [
          h(:style, css),
          h('div.title', title_props, 'The Bank'),
          h(:div, { style: { padding: '0.3rem 0.4rem 0.4rem', backgroundColor: COLOR_BANK_GREEN } }, [
            render_bank_table,
            render_trains_table,
          ].compact),
        ])
      end

      def render_bank_table
        trs = []
        interest_change = (@game.interest_change if @game.respond_to?(:interest_change))

        if @game.game_end_check_values.include?(:bank)
          clean_bank_cash = @game.format_currency(@game.bank_cash)
          trs << h(:tr, [
            h('td.left', { style: { fontFamily: FONT_STD, width: '48%' } }, 'Cash'),
            h('td.right',
              { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY, fontVariantNumeric: 'tabular-nums', width: '52%' } }, clean_bank_cash),
          ])
        end

        has_loans = @game.respond_to?(:total_loans) && @game.total_loans&.nonzero?
        has_interest = @game.respond_to?(:interest_rate) && @game.interest_rate

        if has_interest || has_loans
          if (rate = @game.interest_rate)
            trs << h(:tr, [
              h('td.left', { style: { fontFamily: FONT_STD } }, 'Interest per Loan'),
              h('td.right',
                { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY, fontVariantNumeric: 'tabular-nums' } }, @game.format_currency(rate)),
            ])
            if @game.respond_to?(:future_interest_rate)
              trs << h(:tr, [
                h('td.left', { style: { fontFamily: FONT_STD } }, 'Future Interest'),
                h('td.right', { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY, fontVariantNumeric: 'tabular-nums' } },
                  @game.format_currency(@game.future_interest_rate)),
              ])
            end
          end

          entity = current_entity
          actions = actions_for(entity)
          can_take = actions.include?('take_loan') && @game.respond_to?(:loans) && @game.loans&.any?
          loan_val = @game.respond_to?(:loan_value) ? @game.loan_value(entity) : (@game.loans&.first&.amount || 0)
          taken = @game.respond_to?(:loans_taken) ? @game.loans_taken : 0
          total_available_loans = @game.respond_to?(:total_loans) ? @game.total_loans : 100
          total_dots = 100
          empty_count = [taken, total_dots].min
          available_dots = total_dots - empty_count

          loan_click = if can_take
                         lambda {
                           escaped_id = entity.id.to_s
                           target_selector = "#loan_empty_#{escaped_id}_0, #loans_#{escaped_id}"
                           Lib::LoanAnimation.fly('#bank_loan_active', target_selector) do
                             process_action(Engine::Action::TakeLoan.new(entity, loan: @game.loans.first))
                           end
                         }
                       end

          dots = []
          empty_count.times do
            dots << h(:span, {
                        style: {
                          display: 'inline-block',
                          width: '7px',
                          height: '7px',
                          border: '1px solid #dc3545',
                          borderRadius: '50%',
                          boxSizing: 'border-box',
                          pointerEvents: 'none',
                        },
                      })
          end

          available_dots.times do |i|
            d_attrs = {}
            d_attrs[:id] = 'bank_loan_active' if i.zero?
            dots << h(:span, {
                        attrs: d_attrs,
                        style: {
                          display: 'inline-block',
                          width: '7px',
                          height: '7px',
                          backgroundColor: '#dc3545',
                          borderRadius: '50%',
                          boxSizing: 'border-box',
                          pointerEvents: 'none',
                        },
                      })
          end

          loan_btn_props = {
            attrs: {
              id: (available_dots.zero? && can_take ? 'bank_loan_active' : 'bank_loan_btn'),
              type: 'button',
              title: can_take ? "Take loan for #{entity&.name} (#{@game.format_currency(loan_val)})" : "Loans taken: #{taken}/#{total_available_loans}",
            },
            style: {
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '100%',
              padding: '3px 4px',
              backgroundColor: can_take ? '#fef2f2' : COLOR_BANK_GREEN,
              border: can_take ? '2px solid #dc2626' : '1px solid #a7d7b8',
              borderRadius: '5px',
              cursor: can_take ? 'pointer' : 'default',
              boxShadow: can_take ? '0 1px 3px rgba(220,38,38,0.25)' : 'none',
              boxSizing: 'border-box',
            },
          }
          loan_btn_props[:on] = { click: loan_click } if loan_click

          trs << h(:tr, [
            h(:td, { attrs: { colspan: 2 }, style: { padding: '2px 0' } }, [
              h(:button, loan_btn_props, [
                h(:div, {
                    style: {
                      display: 'grid',
                      gridTemplateColumns: 'repeat(25, 7px)',
                      gridAutoRows: '7px',
                      gap: '2px',
                      justifyContent: 'center',
                      alignItems: 'center',
                      lineHeight: '0',
                      pointerEvents: 'none',
                    },
                  }, dots),
              ]),
            ]),
          ])

          if interest_change
            toggle_loan_table = lambda do
              store(:show_loan_table, !@show_loan_table)
            end

            btn_table_props = {
              attrs: { title: "#{@show_loan_table ? 'Hide' : 'Show'} loan table" },
              style: {
                width: '4rem',
                margin: '0',
                cursor: 'pointer',
                backgroundColor: '#ffffff',
                border: '1px solid #a7d7b8',
                borderRadius: '3px',
              },
              on: { click: toggle_loan_table },
            }
            trs << h(:tr, [
              h('td.left', { style: { fontFamily: FONT_STD } }, 'Loan Table'),
              h('td.right', [h(:button, btn_table_props, (@show_loan_table ? 'Hide' : 'Show').to_s)]),
            ])

            if @show_loan_table
              total = 0
              interest_change.last.each do |price, available|
                total += available
                trs << h(:tr, [
                  h('td.left', { style: { fontFamily: FONT_MONEY } }, @game.format_currency(price)),
                  h('td.right', { style: { fontFamily: FONT_MONEY } }, "#{available} (#{total})"),
                ])
              end
            end

            interest_change.first.each do |text, price_change|
              trs << h(:tr, [
                h('td.left', { style: { fontFamily: FONT_STD } }, text),
                h('td.right', { style: { fontFamily: FONT_MONEY } }, @game.format_currency(price_change)),
              ])
            end
          end

          if @game.respond_to?(:loan_value) && (lv = @game.loan_value)
            trs << h(:tr, [
              h('td.left', { style: { fontFamily: FONT_STD } }, 'Loan Value'),
              h('td.right',
                { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY, fontVariantNumeric: 'tabular-nums' } }, @game.format_currency(lv)),
            ])
          end
        end

        active_step = @game.round.active_step
        if active_step.respond_to?(:seed_money) && active_step.seed_money
          clean_seed = @game.format_currency(active_step.seed_money).gsub(/[^0-9]/, '')
          trs << h(:tr, [
            h('td.left', { style: { fontFamily: FONT_STD } }, 'Seed Money'),
            h('td.right',
              { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY, fontVariantNumeric: 'tabular-nums' } }, clean_seed),
          ])
        end

        if @game.respond_to?(:unstarted_corporation_summary) && (summary = @game.unstarted_corporation_summary) && !summary.empty?
          trs << h(:tr, [
            h('td.left', { style: { fontFamily: FONT_STD } }, 'Unstarted Corps'),
            h('td.right', { style: { fontFamily: FONT_STD } }, summary.first.to_s),
          ])
        end

        if @game.respond_to?(:other_bank_info) && @game.other_bank_info
          trs << h(:tr, [
            h('td.left', { style: { fontFamily: FONT_STD } }, @game.other_bank_info.first.to_s),
            h('td.right', { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY } }, @game.other_bank_info.last.to_s),
          ])
        end

        h(:table, trs)
      end

      def render_bank_train_rows
        active_trains = available_depot_trains
        return [] if active_trains.empty?

        step = @game.round.active_step
        train_buyable_step = step&.current_actions&.include?('buy_train')
        rows = []

        active_trains.each do |train|
          variants = if train.respond_to?(:names_to_prices) && train.names_to_prices && !train.names_to_prices.empty?
                       train.names_to_prices
                     else
                       { train.name => train.price }
                     end

          variants.each do |variant_name, price|
            card_classes = %w[game-card card-train]
            click_handler = nil

            if train_buyable_step && active_entity&.corporation?
              can_afford = active_entity.cash >= price || active_entity.trains.empty?

              if can_afford
                card_classes << 'action-buy'
                card_classes << 'clickable'
                click_handler = lambda {
                  variant_str = variant_name.to_s
                  if @train_handler
                    @train_handler.call(train, price, variant_str, 'fresh')
                  else
                    process_action(Engine::Action::BuyTrain.new(
                      active_entity,
                      train: train,
                      price: price,
                      variant: (variant_str == train.name.to_s ? nil : variant_str)
                    ))
                  end
                }
              end
            end

            available_count = train_available_count(train, variant_name)
            dom_id = "bank_train_#{train.id}_#{variant_name.to_s.tr('/', '_')}"
            card_el = render_railcard(variant_name.to_s, card_classes, click_handler, entity: train)

            rows << h(:tr, [
              h('td.left', { style: { padding: '4px 6px', verticalAlign: 'middle' } }, [
                h(:div, { attrs: { id: dom_id }, style: { display: 'inline-flex', alignItems: 'center' } }, [card_el]),
              ]),
              h('td.right', { style: { padding: '4px 6px', verticalAlign: 'middle', whiteSpace: 'nowrap' } }, [
                h(:span,
                  { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '0.85rem', fontWeight: 'bold', fontVariantNumeric: 'tabular-nums' } }, @game.format_currency(price)),
                h(:span, { style: { fontFamily: FONT_STD, color: '#555555', fontSize: '0.75rem', marginLeft: '4px' } },
                  "(#{available_count})"),
              ]),
            ])
          end
        end

        rows
      end
    end
  end
end
