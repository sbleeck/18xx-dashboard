# frozen_string_literal: true

# rubocop:disable Layout/LineLength

module Engine
  class Minor
    def par_via_exchange
      nil
    end

    def needs_token_to_par
      false
    end
  end
end

require 'lib/settings'
require 'lib/storage'
require 'view/link'
require 'view/share_calculation'
require 'view/game/bank'
require 'view/game/stock_market'
require 'view/game/tranches'
require 'view/game/actionable'
require 'lib/truncate'
require 'view/game/dashboard/row_animation'
require 'view/game/dashboard/dashboard_bank'
require 'view/game/dashboard/dashboard_upcoming_trains'
require 'view/game/dashboard/dashboard_card_animation'
require 'view/game/dashboard/dashboard_loan_animation'
require 'view/game/dashboard/dashboard_money_animation'
require 'view/game/dashboard/railcard_helper'
require 'view/game/dashboard/par_prompt_overlay'
require 'view/game/dashboard/history_overlay'

FLOATED = 2
UNFLOATED = 1
UNSTARTED = 0

module View
  module Game
    class DashboardGameStatus < Snabberb::Component
      include Lib::Settings
      include Actionable
      include View::ShareCalculation
      include View::Game::Dashboard::RailcardHelper

      needs :game, store: true
      needs :game_data, store: true

      PLAYER_COL_MAX_WIDTH = '4.5rem'

      FONT_STD = '"Helvetica Neue", Helvetica, Arial, sans-serif'
      FONT_MONEY = '"Courier New", Courier, monospace'
      COLOR_MONEY = '#4c1d95'
      FONT_CASH = '"Arial Black", Gadget, sans-serif'
      COLOR_CASH = '#4b0082'
      COLOR_BANK = '#f5cda8'
      COLOR_ACTIVE = '#ffffff'
      COLOR_INACTIVE = '#e0e0e0'
      COLOR_MAUVE = '#dda0dd'

      def active_entity
        step_entity = @game.round.active_step&.current_entity
        return step_entity if step_entity

        round_entity = (@game.round.current_entity if @game.round.respond_to?(:current_entity))
        return round_entity if round_entity

        @game.current_entity if @game.respond_to?(:current_entity)
      rescue NotImplementedError, StandardError
        nil
      end

      def active_player
        entity = active_entity
        entity&.player? ? entity : entity&.owner
      end

      def display_players
        return @display_players if @cached_game == @game && @display_players

        @cached_game = @game
        @display_players = initial_players
      end

      def initial_players
        # 1. Resolve from @game_data which maintains initial game creation order
        if @game_data
          raw_players = @game_data['players'] || @game_data[:players]
          if raw_players&.any?
            ordered = raw_players.map do |pd|
              if pd.is_a?(Hash)
                p_id = pd['id'] || pd[:id]
                p_name = pd['name'] || pd[:name]
                @game.players.find { |p| (p_id && p.id == p_id) || (p_name && p.name == p_name) }
              elsif pd.respond_to?(:id) && pd.respond_to?(:name)
                @game.players.find { |p| p.id == pd.id || p.name == pd.name }
              else
                p_str = pd.to_s
                @game.players.find { |p| p.name == p_str || p.id.to_s == p_str }
              end
            end.compact

            return ordered if ordered.size == @game.players.size
          end
        end

        # 2. Check engine methods for initial players if exposed
        %i[init_players initial_players original_players].each do |m|
          if @game.respond_to?(m)
            res = @game.public_send(m)
            return res if res&.size == @game.players.size
          end
        end

        # 3. Check engine instance variables
        %i[@init_players @initial_players @original_players].each do |iv|
          res = @game.instance_variable_get(iv)
          return res if res&.size == @game.players.size
        end

        # 4. Check if player IDs represent 0-indexed initial seat numbers
        if @game.players.all? { |p| p.id.is_a?(Integer) }
          sorted = @game.players.sort_by(&:id)
          return sorted if sorted.first&.id&.zero? || sorted.map(&:id) == (0...@game.players.size).to_a
        end

        @game.players
      end

      def render
        @spreadsheet_sort_by = Lib::Storage['spreadsheet_sort_by']
        @spreadsheet_sort_order = Lib::Storage['spreadsheet_sort_order']
        @hide_not_floated = Lib::Storage['spreadsheet_hide_not_floated']
        has_buy_phase = @game.respond_to?(:game_phases) && @game.game_phases.any? do |p|
          p[:status]&.any? { |s| s.include?('can_buy_companies') }
        end
        is_1817 = @game.class.name.include?('1817') || (@game.respond_to?(:title) && @game.title.to_s.include?('1817'))
        has_corp_companies = @game.respond_to?(:all_corporations) && @game.all_corporations.any? { |c| c.companies&.any? }
        @show_privates = has_buy_phase || is_1817 || has_corp_companies

        active_player_index = display_players.index(active_player)
        active_player_nth = active_player_index ? active_player_index + 2 : -1

        css = <<~CSS
                    :root {
                      --font-money: 'Courier New', monospace;
                      --font-standard: "Helvetica Neue", Helvetica, Arial, sans-serif;
                      --color-money-text: #4c1d95;
                      --accent-action-color: #2563eb;
                      --opacity-unopened-row: 0.45;
                      --bg-active-row: #ffffff;
                      --color-inactive: #e0e0e0;
                      --bg-market-zone: #e6f4ea;
                      --bg-corporate-zone: #f3e8ff;
                      --action-buy-edge: #16a34a;
                      --action-sell-edge: #dc2626;
                      --shadow-card: 0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24);
                    }
                    #spreadsheet table { border-collapse: collapse; border: 3px solid #333333; background-color: #{COLOR_INACTIVE}; }
                    #spreadsheet th, #spreadsheet td { border: 1px solid #b3b3b3 !important; vertical-align: middle !important; padding: 4px 2px !important; }
                    #spreadsheet thead tr:last-child th { border-bottom: 3px solid #333333 !important; }
                    #spreadsheet tr.last-player-row th, #spreadsheet tr.last-player-row td { border-bottom: 3px solid #333333 !important; }
                    #spreadsheet tr.last-minor-row th, #spreadsheet tr.last-minor-row td { border-bottom: 3px solid #333333 !important; }
                    .thick-right { border-right: 3px solid #333333 !important; }
                    .no-border { border: none !important; }
                    .money-value, .padded_number { text-align: right !important; padding-left: 0.45rem !important; padding-right: 0.45rem !important; box-sizing: border-box !important; }
                    .money-value { min-width: 4.35rem !important; width: 4.35rem !important; font-family: var(--font-money) !important; font-weight: bold !important; color: var(--color-money-text) !important; font-variant-numeric: tabular-nums !important; }
                    #spreadsheet .market-shares-col, #spreadsheet .market-price-col { width: 4.35rem !important; min-width: 4.35rem !important; max-width: 4.35rem !important; box-sizing: border-box !important; }
                    #spreadsheet .market-shares-col { text-align: center !important; }
                    #spreadsheet thead th.header-market { background-color: var(--bg-market-zone) !important; color: #111827 !important; }
                    #spreadsheet thead th.header-corporate { background-color: #e9d5ff !important; color: #4c1d95 !important; }
                    #spreadsheet thead th.header-player, #spreadsheet thead th.header-symbol { background-color: #e5e7eb !important; color: #111827 !important; }
                    .game-card { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 3.5rem; height: 1.45rem; font-size: 0.85rem; padding: 0 4px; margin: 2px; border: 1px solid #888888; border-radius: 4px; background-color: #fdfbf7; color: #000000; box-shadow: var(--shadow-card); transition: transform 0.1s ease; font-family: var(--font-standard); }
                    .game-card.clickable:hover { cursor: pointer; transform: translateY(-1px); box-shadow: 0 2px 5px rgba(0,0,0,0.2); }
                    .game-card.action-sell { border: 2px solid var(--action-sell-edge) !important; background-color: #fef2f2 !important; box-shadow: 0 0 0 1px var(--action-sell-edge) !important; }
                    .game-card.action-buy { border: 2px solid var(--action-buy-edge) !important; background-color: #e6f4ea !important; box-shadow: 0 0 0 1px var(--action-buy-edge) !important; }
                    .sell-restricted { text-decoration: line-through !important; opacity: 0.5 !important; cursor: not-allowed !important; }
                    .token-bond { display: inline-block; width: 12px; height: 12px; background-color: #b91c1c; border-radius: 2px; }
                    .align-top { vertical-align: top !important; }
                    /* Normal corporation rows use the same zone colours as the headers. */
                    #spreadsheet tbody td.column-zone-market {
                      background-color: var(--bg-market-zone) !important;
                    }
                    #spreadsheet tbody td.column-zone-corporate {
                      background-color: var(--bg-corporate-zone) !important;
                    }

                    tr.active-turn-focus { background-color: var(--bg-active-row) !important; }
                    tr.active-turn-focus th, tr.active-turn-focus td { box-shadow: inset 0 3px 0 var(--accent-action-color), inset 0 -3px 0 var(--accent-action-color) !important; }
                    tr.active-turn-focus th:first-child, tr.active-turn-focus td:first-child { box-shadow: inset 3px 3px 0 var(--accent-action-color), inset 0 -3px 0 var(--accent-action-color) !important; }
                    tr.active-turn-focus th:last-child, tr.active-turn-focus td:last-child { box-shadow: inset -3px 3px 0 var(--accent-action-color), inset 0 -3px 0 var(--accent-action-color) !important; }

                    /* Only corporations that are not open are greyed out. */
                    #spreadsheet tbody tr.company-row-unfloated > th,
                    #spreadsheet tbody tr.company-row-unfloated > td,
                    #spreadsheet tbody tr.company-row-closed > th,
                    #spreadsheet tbody tr.company-row-closed > td {
                      background-color: var(--color-inactive) !important;
                      color: #6b7280 !important;
                      opacity: 1 !important;
                      filter: grayscale(100%) !important;
                    }

                    /* In unopened rows the IPO remains green because its director share can still be bought. */
                    #spreadsheet tbody tr.company-row-unfloated > td.ipo-zone,
                    #spreadsheet tbody tr.company-row-closed > td.ipo-zone {
                      background-color: var(--bg-market-zone) !important;
                      color: #111827 !important;
                      filter: none !important;
                    }

                    /* The current corporation row is always fully white. */
                    #spreadsheet tbody tr.active-turn-focus > th,
                    #spreadsheet tbody tr.active-turn-focus > td {
                      background-color: #ffffff !important;
                      color: #000000 !important;
                      opacity: 1 !important;
                      filter: none !important;
                    }

                    /* The current player's complete column is always white. */
                    #spreadsheet tbody tr.company-row-unfloated > *:nth-child(#{active_player_nth}),
                    #spreadsheet tbody tr.company-row-closed > *:nth-child(#{active_player_nth}),
                    #spreadsheet tbody tr > *:nth-child(#{active_player_nth}) {
                      background-color: #ffffff !important;
                      color: #000000 !important;
                      opacity: 1 !important;
                      filter: none !important;
                    }
                    #spreadsheet thead th { font-weight: 700 !important; }
                    #spreadsheet th.header-cash, #spreadsheet td.corporation-cash { width: 4.35rem !important; min-width: 4.35rem !important; max-width: 4.35rem !important; }
                    #spreadsheet th.header-trains, #spreadsheet td.corporation-trains { min-width: 14.4rem !important; padding-left: 0 !important; padding-right: 0 !important; white-space: nowrap !important; }
                    .status-corp-wrapper:hover { z-index: 99999; }
                    .status-corp-tooltip, .status-company-tooltip, .cmd-corp-tooltip, .cmd-company-tooltip { display: none !important; }

                    .share-card-wrapper { position: relative; display: inline-flex; align-items: center; justify-content: center; }
          .share-card-wrapper[title]:not([title=""]):hover::after {
            content: attr(title);
            position: absolute;
            bottom: calc(100% + 4px);
            left: 50%;
            transform: translateX(-50%);
            background: rgba(15, 23, 42, 0.95);
            color: #ffffff;
            font-family: var(--font-standard);
            font-size: 0.85rem;
            font-weight: bold;
            line-height: 1.2;
            padding: 4px 8px;
            border-radius: 5px;
            white-space: pre;
            pointer-events: none;
            z-index: 99999;
            box-shadow: 0 3px 6px rgba(0,0,0,0.35);
          }

        CSS

        Lib::CardAnimation.check_and_animate(@game, has_treasury_column?)
        Lib::MarkerAnimation.check_and_animate(@game)

        h(:div, [
          h('div#spreadsheet', { style: { overflow: 'auto', marginTop: '1rem' } }, [
            h(:style, css),
            render_corporation_table,
          ]),
        ])
      end

      def render_corporation_table
        h(:table, table_props, [
          h(:thead, render_titles),
          h(:tbody, render_corporations + render_player_rows),
        ])
      end

      def render_player_rows
        rows = []

        cash_cells = [h('th.left', 'Cash')]
        display_players.each_with_index do |p, idx|
          clean_cash = @game.format_currency(p.cash)
          bg_color = p == active_player ? COLOR_ACTIVE : COLOR_INACTIVE
          is_last = idx == @game.players.size - 1
          cash_cells << h("td.padded_number.money-value#{'.thick-right' if is_last}",
                          { hook: Lib::MoneyAnimation.hook, style: { backgroundColor: bg_color } }, clean_cash)
        end
        rows << cash_cells

        props = { style: { color: 'red' } }
        cert_cells = [h('th.left', 'Cert')]
        display_players.each_with_index do |player, idx|
          cert_limit = @game.cert_limit(player)
          bg_color = player == active_player ? COLOR_ACTIVE : COLOR_INACTIVE
          num_certs = @game.num_certs(player)
          cell_props = num_certs > cert_limit ? props.merge(style: { backgroundColor: bg_color }) : { style: { backgroundColor: bg_color } }
          is_last = idx == @game.players.size - 1
          cert_cells << h("td.padded_number#{'.thick-right' if is_last}", cell_props, "#{num_certs}/#{cert_limit}")
        end
        rows << cert_cells

        if @game.respond_to?(:player_loans)
          loans_cells = [h('th.left', 'Loans')]
          display_players.each_with_index do |p, idx|
            bg_color = p == active_player ? COLOR_ACTIVE : COLOR_INACTIVE
            is_last = idx == @game.players.size - 1
            loans_cells << h("td.padded_number#{'.thick-right' if is_last}", { style: { backgroundColor: bg_color } }, @game.player_loans(p))
          end
          rows << loans_cells
        end

        comp_cells = [h('th.left', 'Privates')]
        display_players.each_with_index do |p, idx|
          bg_color = p == active_player ? COLOR_ACTIVE : COLOR_INACTIVE
          is_last = idx == @game.players.size - 1
          comp_cells << render_companies(p, bg_color, nil, is_last: is_last)
        end
        rows << comp_cells

        rows[0] << h(:td, {
                       attrs: { rowspan: rows.size, colspan: 30, class: 'no-border' },
                       style: { backgroundColor: '#ffffff', verticalAlign: 'top', paddingLeft: '1.5rem', textAlign: 'left' },
                     }, [render_extra_cards])

        rows.map.with_index do |row_cells, idx|
          r_props = tr_default_props
          r_props[:attrs] ||= {}
          r_props[:attrs][:class] = 'last-player-row' if idx == rows.size - 1
          h(:tr, r_props, row_cells)
        end
      end

      def render_corporations
        current_round = @game.turn_round_num
        corps = sorted_corporations

        corps.map.with_index do |corp_array, idx|
          current_corp = corp_array[1]
          next_corp = corps[idx + 1]&.last
          is_last_minor = current_corp.minor? && next_corp && !next_corp.minor?
          render_corporation(current_corp, corp_array[0], current_round, is_last_minor)
        end
      end

      def render_player_table
        h('div#player_table', { style: { float: 'left', marginRight: '1rem' } }, [
          h(:table, table_props, [
            h(:thead),
            h('tbody#player_details', [
              render_player_cash,
              render_player_loans,
              render_player_companies,
              render_player_certs,
            ]),
          ]),
        ])
      end

      def render_extra_cards
        children = []
        train_handler = lambda do |train, price = nil, variant = nil, source_type = 'fresh'|
          owner_entity = train.owner
          if owner_entity.respond_to?(:owner)
            owner_key = owner_entity.respond_to?(:id) ? owner_entity.id : 'depot'
            Lib::Storage["cmd_buy_train_menu_#{owner_key}_#{train.id}"] = true
            Lib::Storage["cmd_buy_train_price_#{owner_key}_#{train.id}"] = active_entity.cash
            update
          else
            price_to_pay = price || train.price
            variant_name = variant ? variant.to_s : train.name.to_s
            variant_param = (variant_name == train.name.to_s ? nil : variant_name)

            transfer = {
              kind: 'train',
              item_id: train.id.to_s,
              source_type: source_type == 'pool' ? 'train_pool' : 'train_fresh',
              source_id: nil,
              variant: variant&.to_s,
            }

            %x{
  if (typeof window !== 'undefined') {
    window._railcard_pending_transfer = #{transfer};
  }
}

            process_action(
              Engine::Action::BuyTrain.new(
                active_entity,
                train: train,
                price: price,
                variant: variant
              )
            )
          end
        end

        children << h(DashboardBank, game: @game, train_handler: train_handler)
        children << h(Tranches, game: @game) if @game.respond_to?(:tranches)
        children << h(DashboardUpcomingTrains, game: @game)
        h('div#extra_cards', { style: { marginBottom: '1rem' } }, children.compact)
      end

      def render_titles
        treasury_headers = []
        if has_treasury_column?
          header_name = any_reserved_shares? && !@game.separate_treasury? ? @game.ipo_reserved_name : 'Treasury'
          treasury_headers << h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link(header_name, :treasury))
        end

        extra = []
        if @game.respond_to?(:capitalization_type_desc)
          @is_escrow_game = @game.all_corporations.any? { |c| @game.capitalization_type_desc(c)&.include?('Escrow') }
          header_label = @is_escrow_game ? 'Escrow' : 'Capitalization'
          extra << h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link(header_label, :capitalization_type_desc))
        end
        extra << h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link('Loans', :loans)) if @game.total_loans&.nonzero?

        @extra_size = extra.size

        player_headers = display_players.map.with_index do |player, index|
          props = {
            attrs: { class: ('thick-right' if index == display_players.size - 1) },
            style: {
              width: PLAYER_COL_MAX_WIDTH,
              minWidth: PLAYER_COL_MAX_WIDTH,
              maxWidth: PLAYER_COL_MAX_WIDTH,
              position: 'relative',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              textAlign: 'left',
              paddingRight: '22px',
            },
          }
          props[:attrs][:class] = [props[:attrs][:class], 'header-player'].compact.join(' ')
          content = render_sort_link(player.name, player.id)
          if @game.respond_to?(:priority_deal_player) && player == @game.priority_deal_player
            content += [h(:svg, {
                            attrs: { viewBox: '0 0 16 16', width: '16', height: '16', title: 'Priority Deal' },
                            style: { position: 'absolute', right: '4px', top: '50%', transform: 'translateY(-50%)', fill: COLOR_CASH },
                          }, [
              h(:rect, attrs: { x: '0', y: '2', width: '6', height: '1' }),
              h(:rect, attrs: { x: '1', y: '3', width: '4', height: '7' }),
              h(:rect, attrs: { x: '11', y: '1', width: '2', height: '4' }),
              h(:rect, attrs: { x: '4', y: '5', width: '10', height: '5' }),
              h(:rect, attrs: { x: '1', y: '10', width: '14', height: '2' }),
              h(:polygon, attrs: { points: '14,10 16,12 14,12' }),
              h(:circle, attrs: { cx: '3.5', cy: '13.5', r: '1.5' }),
              h(:circle, attrs: { cx: '8.5', cy: '13.5', r: '1.5' }),
              h(:circle, attrs: { cx: '12.5', cy: '13.5', r: '1.5' }),
            ])]
          end
          h(:th, props, content)
        end

        corporation_headers = [
          *treasury_headers,
          h(:th, { attrs: { class: 'header-cash header-corporate' } }, render_sort_link('Cash', :cash)),
          h(:th, { attrs: { class: 'header-trains header-corporate' } }, render_sort_link('Trains', :trains)),
          h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link('Tokens', :tokens)),
          *extra,
        ]
        corporation_headers << h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link('Privates', :companies)) if @show_privates
        corporation_headers << h(:th, { attrs: { class: 'header-corporate' } }, render_sort_link('Last', :prev_revenue))

        [h(:tr, [
          h('th.thick-right.header-symbol', ''),
          *player_headers,
          h(:th, { attrs: { colspan: 2, class: 'thick-right header-market' } }, render_sort_link('Pool', :market_shares)),
          h(:th, { attrs: { colspan: 2, class: 'thick-right header-market' } }, render_sort_link('IPO', :ipo_shares)),
          *corporation_headers,
        ])]
      end

      def render_sort_link(text, _sort_by)
        [text]
      end

      def sort_order_icon
        return '↓' if @spreadsheet_sort_order == 'ASC'

        '↑'
      end

      def mark_sort_column(sort_by)
        Lib::Storage['spreadsheet_sort_by'] = sort_by
        update
      end

      def toggle_sort_order
        Lib::Storage['spreadsheet_sort_order'] = @spreadsheet_sort_order == 'ASC' ? 'DESC' : 'ASC'
        update
      end

      def render_toggle_not_floated_link
        toggle = lambda do
          Lib::Storage['spreadsheet_hide_not_floated'] = !@hide_not_floated
          update
        end

        h('span.small_font', [
          '(',
          h(:a, {
              attrs: { onclick: 'return false', title: @hide_not_floated ? 'Show all corporations' : 'Hide not floated corporations' },
              on: { click: toggle },
              style: { cursor: 'pointer', textDecoration: 'underline' },
            }, @hide_not_floated ? 'Show unfloated' : 'Hide unfloated'),
          ')',
        ])
      end

      def sorted_corporations
        operating_array = @game.round.operating? ? @game.round.entities : @game.operating_order
        operating_corporations = operating_array.each_with_index.to_h

        all_entities = @game.respond_to?(:minors) ? (@game.minors || []) : []
        all_entities += @game.all_corporations
        all_entities.reject! { |c| c.respond_to?(:closed?) && c.closed? }

        unfloated_corporations = (all_entities - operating_array)
          .select { |c| c.respond_to?(:sort_order_key) && c.sort_order_key }
          .sort
          .each_with_index.to_h

        result = all_entities.map do |c|
          operating_order = if (index = operating_corporations[c])
                              [FLOATED, index + 1]
                            elsif (index = unfloated_corporations[c])
                              [UNFLOATED, index + 1]
                            else
                              [UNSTARTED, 0]
                            end
          [operating_order, c]
        end

        result.sort_by! do |operating_order, corporation|
          is_minor = corporation.minor? ? 0 : 1
          minor_order = corporation.minor? ? operating_order[1] : 0
          major_status = corporation.minor? ? 0 : -operating_order[0]
          major_price = corporation.minor? ? 0 : -(corporation.share_price&.price || 0)
          major_secondary_order = corporation.minor? ? 0 : operating_order[1]
          [is_minor, minor_order, major_status, major_price, major_secondary_order]
        end

        result
      end

      def status_actions_for(entity)
        return [] unless entity

        actions = []
        if @game.round.respond_to?(:actions_for)
          begin
            actions.concat(@game.round.actions_for(entity) || [])
          rescue NotImplementedError, StandardError
          end
        end
        step = @game.round.active_step
        if actions.empty? && step&.respond_to?(:actions)
          begin
            actions.concat(step.actions(entity) || [])
          rescue NotImplementedError, StandardError
          end
        end
        actions.compact.map(&:to_s).uniq
      end

      def status_corporation_actions(corporation)
        actions = status_actions_for(corporation)
        owner = corporation.respond_to?(:owner) ? corporation.owner : nil
        actions.concat(status_actions_for(owner)) if owner && owner == active_player
        actions.uniq
      end

      def status_step_bundles(step, method_name, corporation)
        return [] unless step&.respond_to?(method_name)

        raw = begin
          step.public_send(method_name, corporation)
        rescue ArgumentError
          step.public_send(method_name)
        rescue StandardError
          []
        end
        Array(raw).compact.map do |item|
          item.respond_to?(:to_bundle) && !item.respond_to?(:num_shares) ? item.to_bundle : item
        end
      end

      def status_bundle_key(bundle)
        shares =
          if bundle.respond_to?(:shares)
            bundle.shares
          elsif bundle.respond_to?(:id)
            [bundle]
          else
            []
          end

        share_ids = shares.compact.map do |share|
          share.respond_to?(:id) ? share.id.to_s : share.object_id.to_s
        end.sort

        owner = bundle_owner(bundle)
        owner_key =
          if owner&.respond_to?(:id)
            owner.id.to_s
          else
            owner&.object_id.to_s
          end

        [owner_key, share_ids]
      end

      def status_issuable_bundles(step, corporation)
        bundles = status_step_bundles(step, :issuable_shares, corporation)
        bundles = status_step_bundles(step, :issuable_bundles, corporation) if bundles.empty?
        if bundles.empty? && @game.respond_to?(:issuable_shares)
          begin
            bundles = Array(@game.issuable_shares(corporation))
          rescue StandardError
            bundles = []
          end
        end
        if bundles.empty? && step&.respond_to?(:bundles_for_corporation)
          begin
            bundles = Array(step.bundles_for_corporation(corporation, corporation))
          rescue ArgumentError
            bundles = Array(step.bundles_for_corporation(corporation))
          rescue StandardError
            bundles = []
          end
        end
        if bundles.empty? && step&.respond_to?(:bundles)
          begin
            bundles = Array(step.bundles(corporation))
          rescue StandardError
            bundles = []
          end
        end
        if bundles.empty? && step&.respond_to?(:can_sell?)
          shares = corporation.respond_to?(:shares_of) ? corporation.shares_of(corporation) : []
          bundles = shares.map(&:to_bundle).select { |bundle| step.can_sell?(corporation, bundle) }
        end
        bundles.compact.map { |item| item.respond_to?(:to_bundle) && !item.respond_to?(:num_shares) ? item.to_bundle : item }
.uniq { |bundle| status_bundle_key(bundle) }
      end

      def explicit_redeemable_bundles(step, corporation)
        bundles = status_step_bundles(step, :redeemable_shares, corporation)
        bundles = status_step_bundles(step, :redeemable_bundles, corporation) if bundles.empty?
        if bundles.empty? && @game.respond_to?(:redeemable_shares)
          begin
            bundles = Array(@game.redeemable_shares(corporation))
          rescue StandardError
            bundles = []
          end
        end
        bundles.compact.map { |item| item.respond_to?(:to_bundle) && !item.respond_to?(:num_shares) ? item.to_bundle : item }
.uniq { |bundle| status_bundle_key(bundle) }
      end

      def status_redeemable_bundles(step, corporation)
        bundles = status_step_bundles(step, :redeemable_shares, corporation)
        bundles = status_step_bundles(step, :redeemable_bundles, corporation) if bundles.empty?
        bundles = status_step_bundles(step, :buyable_shares, corporation) if bundles.empty?
        if bundles.empty? && @game.respond_to?(:redeemable_shares)
          begin
            bundles = Array(@game.redeemable_shares(corporation))
          rescue StandardError
            bundles = []
          end
        end
        if bundles.empty? && step&.respond_to?(:can_buy?)
          shares = @game.share_pool.shares_by_corporation[corporation] || []
          bundles = shares.map(&:to_bundle).select { |bundle| step.can_buy?(corporation, bundle) }
        end
        bundles.compact.map { |item| item.respond_to?(:to_bundle) && !item.respond_to?(:num_shares) ? item.to_bundle : item }
.uniq { |bundle| status_bundle_key(bundle) }
      end

      def bundle_owner(bundle)
        return bundle.owner if bundle.respond_to?(:owner) && bundle.owner
        return bundle.shares.first.owner if bundle.respond_to?(:shares) && bundle.shares&.first&.respond_to?(:owner)

        nil
      end

      def bundle_from_pool?(bundle, corporation)
        return true if bundle_owner(bundle) == @game.share_pool

        pool_shares = @game.share_pool.shares_by_corporation[corporation] || []
        bundle_shares = bundle.respond_to?(:shares) ? bundle.shares : [bundle]
        bundle_shares.any? && bundle_shares.all? { |share| pool_shares.include?(share) }
      end

      def visual_operating_entity
        entity = @game.respond_to?(:current_entity) ? @game.current_entity : nil
        entity ||= @game.round.current_entity if @game.round.respond_to?(:current_entity)
        entity ||= active_entity
        entity
      rescue NotImplementedError, StandardError
        active_entity
      end

      def operated_this_or?(corporation, current_round)
        return false unless @game.round.operating?
        return false if corporation == visual_operating_entity
        return false unless corporation.respond_to?(:operating_history)

        corporation.operating_history.keys.include?(current_round)
      end

      def render_corporation(corporation, _operating_order, current_round, is_last_minor = false)
        return '' if @hide_not_floated && !@game.operating_order.include?(corporation)

        step = @game.round.active_step
        is_active_row = (active_entity == corporation)

        # Include actions exposed through either the corporation or its
        # controlling player.
        corp_actions = status_corporation_actions(corporation)

        corporation_controlled =
          is_active_row ||
          (corporation.respond_to?(:owner) && corporation.owner == active_player)
        issuable_bundles = status_issuable_bundles(step, corporation)
        issue_command =
          (corp_actions & %w[
            issue_shares
            reissue_shares
            reissue
            corporate_sell_shares
            issue
            sell_shares
          ]).any?

        can_issue =
          corporation_controlled &&
          issue_command &&
          issuable_bundles.any?

        explicit_redeem_bundles = explicit_redeemable_bundles(step, corporation)
        all_redeemable_bundles = status_redeemable_bundles(step, corporation)

        redeem_command =
          (corp_actions & %w[
            redeem
            redeem_shares
            corporate_buy_shares
          ]).any?

        can_redeem =
          corporation_controlled &&
          redeem_command &&
          all_redeemable_bundles.any?

        is_unfloated = corporation.respond_to?(:floated?) && !corporation.floated?
        is_directed = corporation.respond_to?(:owner) && (corporation.owner == active_player)

        tr_props = tr_default_props(is_active_row)
        tr_props[:attrs] ||= {}
        tr_props[:key] = corporation.id
        tr_props[:hook] = Lib::RowAnimation.hook(corporation.id)

        row_classes = []
        president_sold = corporation.respond_to?(:owner) && corporation.owner ? true : false
        president_available = if corporation.respond_to?(:minor?) && corporation.minor?
                                !president_sold
                              elsif corporation.respond_to?(:available?)
                                corporation.available?
                              elsif @game.respond_to?(:corporation_available?)
                                @game.corporation_available?(corporation)
                              else
                                true
                              end

        should_grey_unfloated = is_unfloated

        row_classes << 'company-row-unfloated' if should_grey_unfloated
        visual_current = @game.round.operating? && corporation == visual_operating_entity
        row_classes << 'active-turn-focus' if visual_current
        row_classes << 'directed-by-active-player' if is_directed && !visual_current
        row_classes << 'last-minor-row' if is_last_minor

        tr_props[:attrs][:class] = row_classes.join(' ') unless row_classes.empty?

        name_props = {
          attrs: { class: 'major-corporation-cell' },
          style: {
            padding: '0 !important',
            textAlign: 'center',
            verticalAlign: 'middle',
            position: 'relative',
          },
        }
        treasury = []

        if has_treasury_column?
          t_shares = treasury_shares_for(corporation)
          treasury_cards = []
          treasury_percent = t_shares.sum { |share| share.respond_to?(:percent) ? share.percent : (corporation.share_percent || 10) }
          unless @game.separate_treasury?
            treasury_percent += num_reserved_shares(corporation) * (corporation.respond_to?(:share_percent) ? corporation.share_percent : 10)
          end
          treasury_issuable_bundles = issuable_bundles.select { |b| bundle_owner(b) == corporation }
          can_issue_treasury = can_issue && (treasury_issuable_bundles.any? || (!@game.class.name.include?('1846') && !issuable_bundles.any? { |b| bundle_owner(b) != corporation } && !t_shares.empty?))

          if treasury_percent.positive?
            classes = ['game-card']
            classes << 'action-sell' if can_issue_treasury
            classes << 'clickable' if can_issue_treasury
            dropdowns = []
            click_handler = nil

            if can_issue_treasury
              click_handler = if treasury_issuable_bundles.size > 1
                                lambda {
                                  Lib::Storage['issue_menu_corp'] = corporation.id
                                  update
                                }
                              else
                                lambda { |_event|
                                  exec_issue_share_bundle(
                                    corporation, treasury_issuable_bundles.first || issuable_bundles.first, corp_actions,
                                    "#treasury_shares_#{corporation.id} .game-card",
                                    "#pool_shares_#{corporation.id}"
                                  )
                                }
                              end
            end

            if Lib::Storage['issue_menu_corp'] == corporation.id && can_issue_treasury
              options = (treasury_issuable_bundles.any? ? treasury_issuable_bundles : issuable_bundles).map do |bundle|
                pct = bundle.respond_to?(:percent) ? bundle.percent : bundle.shares.sum(&:percent)
                {
                  label: "Issue #{pct}%",
                  action: lambda { |_event|
                    Lib::Storage['issue_menu_corp'] = nil
                    exec_issue_share_bundle(
                      corporation, bundle, corp_actions,
                      "#treasury_shares_#{corporation.id} .game-card",
                      "#pool_shares_#{corporation.id}"
                    )
                  },
                }
              end
              dropdowns << render_choice_menu('Issue shares:', options, lambda {
                                                                          Lib::Storage['issue_menu_corp'] = nil
                                                                          update
                                                                        })
            end

            card = render_railcard("#{treasury_percent}%", classes, click_handler, nil, dropdowns)
            treasury_hover = share_denomination_tooltip(t_shares, corporation)
            treasury_cards << h(:div, { attrs: { class: 'share-card-wrapper', title: treasury_hover } }, [card])
          end

          treasury << h('td.column-zone-corporate', {
                          attrs: { id: "treasury_shares_#{corporation.id}" },
                          style: { textAlign: 'center', minWidth: '3.5rem', position: 'relative' },
                        }, treasury_cards)
        end

        extra = []
        if @game.respond_to?(:capitalization_type_desc)
          desc_text = @game.capitalization_type_desc(corporation)
          if @is_escrow_game && desc_text&.include?('Escrow')
            clean_digits = desc_text.scan(/\d+/).first || '0'
            extra << h('td.column-zone-corporate.money-value', {}, clean_digits)

          else
            extra << h('td.column-zone-corporate', {}, desc_text)
          end
        end
        extra << h('td.column-zone-corporate', { attrs: { id: "loans_#{corporation.id}" } }, [render_loan_dots(corporation)]) if @game.total_loans&.nonzero?

        pool_shares = if @game.share_pool.respond_to?(:shares_of)
                        @game.share_pool.shares_of(corporation)
                      else
                        @game.share_pool.shares_by_corporation[corporation] || []
                      end
        valid_pool_shares = []
        if active_player && step.respond_to?(:can_buy?)
          valid_pool_shares = pool_shares.select do |share|
            (share.respond_to?(:buyable) ? share.buyable : true) && step.can_buy?(active_player, share.to_bundle)
          rescue StandardError
            false
          end
        end
        player_can_buy_pool = valid_pool_shares.any?
        player_can_short = active_player && step.respond_to?(:can_short?) && step.can_short?(active_player, corporation)

        n_ipo_shares = corporation.minor? ? 0 : num_ipo_shares(corporation)
        n_market_shares = num_shares_of(@game.share_pool, corporation)

        players_row_content = []
        display_players.each do |p|
          is_active_col = (p == active_player) && !is_active_row
          bg_color = is_active_col ? COLOR_ACTIVE : 'inherit'
          step = @game.round.active_step

          player_shares = p.respond_to?(:shares_of) ? p.shares_of(corporation) : []
          bundles = []

          active_step_actions = if step.respond_to?(:actions)
                                  begin; step.actions(p) || []; rescue StandardError; []; end
                                elsif step.respond_to?(:current_actions)
                                  step.current_actions || []
                                else
                                  []
                                end

          can_sell_now = (p == active_player) && active_step_actions.include?('sell_shares')
          if @game.round.operating?
            emergency_active = if step.respond_to?(:can_sell_shares?)
                                 step.can_sell_shares?(p)
                               elsif step.respond_to?(:must_sell?)
                                 step.must_sell?(p)
                               elsif step.respond_to?(:must_buy_train?)
                                 step.must_buy_train?(active_entity)
                               elsif step.respond_to?(:cash_crisis?)
                                 step.cash_crisis?
                               elsif step.respond_to?(:emergency?)
                                 step.emergency?
                               else
                                 step.class.name.include?('BuyTrain') && active_step_actions.include?('sell_shares')
                               end
            can_sell_now = false unless emergency_active
          end

          if can_sell_now
            legal_bundles =
              if step.respond_to?(:sellable_bundles)
                step.sellable_bundles(p, corporation) || []
              elsif @game.respond_to?(:sellable_bundles)
                @game.sellable_bundles(p, corporation) || []
              elsif step.respond_to?(:bundles_for_corporation)
                step.bundles_for_corporation(p, corporation) || []
              else
                []
              end

            legal_bundles.each do |b|
              next if step.respond_to?(:can_sell?) && !step.can_sell?(p, b)

              bundles << {
                shares: b.shares,
                percent: b.percent,
                share_price: b.share_price,
                bundle: b,
              }
            end
          end
          can_sell = (p == active_player) && !bundles.empty?

          valid_player_buys = []
          if !can_sell && p != active_player && step.respond_to?(:can_buy?)
            player_shares.each do |s|
              valid_player_buys << s if step.can_buy?(active_player, s.to_bundle)
            end
          end
          can_buy_from_player = !valid_player_buys.empty?
          director_redeem_bundles = all_redeemable_bundles.select { |bundle| bundle_owner(bundle) == p }
          director_redeem_bundles = [] unless can_redeem && corporation.owner == p
          can_redeem_from_director = director_redeem_bundles.any?
          can_buy_from_player = false if can_redeem
          click_handler = nil

          if can_sell
            click_handler = if bundles.size > 1
                              lambda {
                                Lib::Storage['sell_menu_player'] = p.id
                                Lib::Storage['sell_menu_corp'] = corporation.id
                                update
                              }
                            else
                              lambda { |_event|
                                source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                                exec_sell_shares(source_selector, p, bundles.first, corporation.id)
                              }
                            end
          elsif can_redeem_from_director
            click_handler = if director_redeem_bundles.size > 1
                              lambda {
                                Lib::Storage['director_redeem_menu_corp'] = corporation.id
                                update
                              }
                            else
                              lambda { |_event|
                                exec_redeem_share_bundle(
                                  corporation, director_redeem_bundles.first, corp_actions,
                                  "#player_shares_#{p.id}_#{corporation.id} .game-card",
                                  "#treasury_shares_#{corporation.id}"
                                )
                              }
                            end
          elsif can_buy_from_player
            click_handler = if valid_player_buys.uniq { |s| s.to_bundle.percent }.size > 1
                              lambda {
                                Lib::Storage['buy_player_menu_player'] = p.id
                                Lib::Storage['buy_player_menu_corp'] = corporation.id
                                update
                              }
                            else
                              lambda {
                                bnd = valid_player_buys.first.to_bundle
                                source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                                exec_buy_shares(source_selector, active_player, bnd, corporation.id)
                              }
                            end
          end

          if corporation.minor?
            players_row_content << if corporation.owner == p
                                     card_classes = ['game-card']
                                     card_classes << 'action-sell' if can_sell
                                     card_classes << 'action-buy' if can_buy_from_player
                                     card_classes << 'clickable' if click_handler
                                     card_props = { attrs: { class: card_classes.join(' ') } }
                                     card_props[:on] = { click: click_handler } if click_handler

                                     minor_card = h(:div, card_props, '100%')
                                     minor_hover = share_denomination_tooltip(player_shares, corporation)
                                     wrapped_minor = h(:div, { attrs: { class: 'share-card-wrapper', title: minor_hover } }, [minor_card])
                                     h(:td, { style: { backgroundColor: bg_color, textAlign: 'center' } }, [wrapped_minor])

                                   else
                                     h(:td, { style: { backgroundColor: bg_color } }, '')
                                   end
          else

            raw_percent = p.respond_to?(:percent_of) ? (p.percent_of(corporation) || 0) : 0
            is_short = raw_percent.negative?
            if !is_short && corporation.respond_to?(:shorts)
              player_shorts = corporation.shorts.select { |s| s.owner == p }
              if player_shorts.any?
                is_short = true
                raw_percent = -player_shorts.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
              end
            end
            can_short_cell = (p == active_player) && !is_short && raw_percent.zero? && player_can_short

            if is_short
              cover_bundle = valid_pool_shares.first&.to_bundle
              can_cover = (p == active_player) && active_step_actions.include?('buy_shares') && !cover_bundle.nil?
              can_short_more = (p == active_player) && player_can_short

              click_handler = nil
              dropdowns = []
              card_classes = ['short-card']

              if can_cover && can_short_more
                card_classes << 'clickable'
                click_handler = lambda {
                  Lib::Storage["short_choice_menu_#{corporation.id}"] = p.id
                  update
                }
                if Lib::Storage["short_choice_menu_#{corporation.id}"] == p.id
                  share_val = corporation.share_price ? @game.format_currency(corporation.share_price.price) : ''
                  short_unit_pct = corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent : 10
                  options = [
                    {
                      label: "Buy to Cover #{short_unit_pct}% (-#{share_val})",
                      action: lambda { |_event|
                        `event.stopPropagation()`
                        Lib::Storage["short_choice_menu_#{corporation.id}"] = nil
                        source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                        exec_buy_shares(source_selector, p, cover_bundle, corporation.id)
                      },
                    },
                    {
                      label: "Short Additional #{short_unit_pct}% (+#{share_val})",
                      action: lambda { |_event|
                        `event.stopPropagation()`
                        Lib::Storage["short_choice_menu_#{corporation.id}"] = nil
                        source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                        exec_short_shares(source_selector, p, corporation)
                      },
                    },
                  ]

                  dropdowns << render_choice_menu("Position for #{corporation.name}:", options, lambda {
                    Lib::Storage["short_choice_menu_#{corporation.id}"] = nil
                    update
                  })
                end
              elsif can_cover
                card_classes << 'action-buy'
                card_classes << 'clickable'
                click_handler = lambda { |_event|
                  source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                  exec_buy_shares(source_selector, p, cover_bundle, corporation.id)
                }
              elsif can_short_more
                card_classes << 'action-sell'
                card_classes << 'clickable'
                click_handler = lambda { |_event|
                  source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                  exec_short_shares(source_selector, p, corporation)
                }
              end

              card = render_short_position_railcard(
                corporation,
                percent: raw_percent.abs,
                click_handler: click_handler,
                dropdown: dropdowns,
                card_classes: card_classes,
                wrapper_id: "player_short_#{p.id}_#{corporation.id}"
              )
              players_row_content << h(:td, {
                                         attrs: { id: "player_shares_#{p.id}_#{corporation.id}" },
                                         style: { backgroundColor: bg_color, textAlign: 'center', position: 'relative' },
                                       }, [card])
            elsif can_short_cell
              ghost_click = lambda { |_event|
                source_selector = "#pool_shares_#{corporation.id} .game-card"
                exec_short_shares(source_selector, p, corporation)
              }
              ghost_card = render_ghost_short_railcard(
                corporation,
                percent: corporation.respond_to?(:share_percent) ? corporation.share_percent : 10,
                click_handler: ghost_click,
                wrapper_id: "ghost_short_#{p.id}_#{corporation.id}"
              )
              players_row_content << h(:td, {
                                         attrs: { id: "player_shares_#{p.id}_#{corporation.id}" },
                                         style: { backgroundColor: bg_color, textAlign: 'center', position: 'relative' },
                                       }, [ghost_card])
            else
              n_shares = num_shares_of(p, corporation)
              just_sold = begin; step&.did_sell?(corporation, p); rescue StandardError; false; end

              if n_shares.zero? && !can_buy_from_player && !can_redeem_from_director && !just_sold
                players_row_content << h(:td, { attrs: { id: "player_shares_#{p.id}_#{corporation.id}" }, style: { backgroundColor: bg_color } }, '')
              else
                base_share_pct = corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent : 10
                holding_percent = if player_shares.any?
                                    player_shares.sum { |s| s.respond_to?(:percent) ? s.percent : base_share_pct }
                                  else
                                    n_shares * base_share_pct
                                  end
                percent = raw_percent.positive? ? raw_percent : holding_percent
                is_president = corporation.respond_to?(:president?) && corporation.president?(p)
                text = n_shares.zero? ? '0%' : "#{percent}%#{'P' if is_president}"
                text = '0%' if text.to_s.empty?

                card_classes = ['game-card']
                card_classes << 'action-sell' if can_sell
                card_classes << 'action-buy' if can_buy_from_player || can_redeem_from_director
                card_classes << 'clickable' if click_handler
                dropdowns = []

                if just_sold
                  dropdowns << h(:span, {
                                   attrs: { class: 'token-bond' },
                                   style: { position: 'absolute', top: '10px', right: '-7px', width: '8px', height: '8px', borderRadius: '50%', backgroundColor: '#dc2626', visibility: 'visible' },
                                 })
                end

                if Lib::Storage['sell_menu_player'] == p.id && Lib::Storage['sell_menu_corp'] == corporation.id && can_sell
                  options = bundles.map do |bundle|
                    {
                      label: "#{bundle[:percent]}%",
                      action: lambda { |_event|
                        Lib::Storage['sell_menu_player'] = nil
                        Lib::Storage['sell_menu_corp'] = nil
                        source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                        exec_sell_shares(source_selector, p, bundle, corporation.id)
                      },
                    }
                  end
                  cancel_handler = lambda {
                    Lib::Storage['sell_menu_player'] = nil
                    Lib::Storage['sell_menu_corp'] = nil
                    update
                  }
                  dropdowns << render_choice_menu('How many shares to sell?', options, cancel_handler)
                end

                if Lib::Storage['director_redeem_menu_corp'] == corporation.id && can_redeem_from_director
                  options = director_redeem_bundles.map do |bundle|
                    pct = bundle.respond_to?(:percent) ? bundle.percent : bundle.shares.sum(&:percent)
                    {
                      label: "Redeem #{pct}%",
                      action: lambda { |_event|
                        Lib::Storage['director_redeem_menu_corp'] = nil
                        exec_redeem_share_bundle(
                          corporation, bundle, corp_actions,
                          "#player_shares_#{p.id}_#{corporation.id} .game-card",
                          "#treasury_shares_#{corporation.id}"
                        )
                      },
                    }
                  end
                  dropdowns << render_choice_menu('Redeem from director:', options, lambda {
                                                                                      Lib::Storage['director_redeem_menu_corp'] = nil
                                                                                      update
                                                                                    })
                end

                if Lib::Storage['buy_player_menu_player'] == p.id && Lib::Storage['buy_player_menu_corp'] == corporation.id && can_buy_from_player
                  options = valid_player_buys.map do |share|
                    {
                      label: "Buy #{share.to_bundle.percent}%",
                      action: lambda {
                        Lib::Storage['buy_player_menu_player'] = nil
                        Lib::Storage['buy_player_menu_corp'] = nil
                        source_selector = "#player_shares_#{p.id}_#{corporation.id} .game-card"
                        exec_buy_shares(source_selector, active_player, share.to_bundle, corporation.id)
                      },
                    }
                  end
                  cancel_handler = lambda {
                    Lib::Storage['buy_player_menu_player'] = nil
                    Lib::Storage['buy_player_menu_corp'] = nil
                    update
                  }
                  dropdowns << render_choice_menu('Nationalize share bundle?', options, cancel_handler)
                end

                card = render_railcard(text, card_classes, click_handler, nil, dropdowns)
                player_hover = n_shares.zero? ? '' : share_denomination_tooltip(player_shares, corporation)
                card = h(:div, { attrs: { class: 'share-card-wrapper', title: player_hover } }, [card])
                card = h(:span, { style: { visibility: 'hidden', display: 'inline-block' } }, [card]) if n_shares.zero?
                players_row_content << h(:td, { attrs: { id: "player_shares_#{p.id}_#{corporation.id}" }, style: { backgroundColor: bg_color, textAlign: 'center', position: 'relative' } }, [card])
              end
            end
          end
        end

        n_market_shares = num_shares_of(@game.share_pool, corporation)
        pool_shares = if @game.share_pool.respond_to?(:shares_of)
                        @game.share_pool.shares_of(corporation)
                      else
                        @game.share_pool.shares_by_corporation[corporation] || []
                      end
        pool_redeem_bundles = (explicit_redeem_bundles + all_redeemable_bundles)
      .uniq { |bundle| status_bundle_key(bundle) }
          .select { |bundle| bundle_from_pool?(bundle, corporation) }
        if pool_redeem_bundles.empty? && explicit_redeem_bundles.any? && step.respond_to?(:can_buy?)
          pool_redeem_bundles = pool_shares.map(&:to_bundle).select do |bundle|
            step.can_buy?(corporation, bundle)
          rescue StandardError
            false
          end
        end

        affordable_pool_redeems = pool_redeem_bundles.select do |bundle|
          price = bundle.respond_to?(:price) ? bundle.price : nil
          price ||= bundle.share_price.price * bundle.num_shares if bundle.respond_to?(:share_price) && bundle.share_price && bundle.respond_to?(:num_shares)
          price ||= corporation.share_price.price * bundle.shares.size if corporation.share_price && bundle.respond_to?(:shares)
          corporation.cash >= (price || 0)
        end
        corporation_can_redeem_pool = can_redeem && affordable_pool_redeems.any?

        valid_pool_shares = []
        if active_player && step.respond_to?(:can_buy?)
          valid_pool_shares = pool_shares.select do |share|
            (share.respond_to?(:buyable) ? share.buyable : true) && step.can_buy?(active_player, share.to_bundle)
          rescue StandardError
            false
          end
        end
        player_can_buy_pool = valid_pool_shares.any?

        corporation_share_destination = if has_treasury_column?
                                          "#treasury_shares_#{corporation.id}"
                                        else
                                          "#ipo_shares_#{corporation.id}"
                                        end

        base_share_pct = corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent : 10
        pool_percent = pool_shares.sum do |share|
          if share.respond_to?(:percent)
            share.percent
          else
            base_share_pct
          end
        end

        pool_share_text = if corporation.minor? || pool_percent.zero?
                            ''
                          else
                            "#{'*' if corporation.respond_to?(:receivership?) && corporation.receivership?}#{pool_percent}%"
                          end
        pool_click_handler = nil
        if player_can_buy_pool && corporation_can_redeem_pool
          pool_click_handler = lambda {
            Lib::Storage['pool_buyer_menu_corp'] = corporation.id
            update
          }
        elsif player_can_buy_pool && player_can_short
          pool_click_handler = lambda {
            Lib::Storage['pool_action_menu_corp'] = corporation.id
            update
          }
        elsif corporation_can_redeem_pool
          pool_click_handler = if affordable_pool_redeems.size > 1
                                 lambda {
                                   Lib::Storage['redeem_menu_corp'] = corporation.id
                                   update
                                 }
                               else
                                 lambda { |_event|
                                   exec_redeem_share_bundle(
                                     corporation, affordable_pool_redeems.first, corp_actions,
                                     "#pool_shares_#{corporation.id} .game-card",
                                     corporation_share_destination
                                   )
                                 }
                               end
        elsif player_can_buy_pool
          pool_click_handler = if valid_pool_shares.uniq { |share| share.to_bundle.percent }.size > 1
                                 lambda {
                                   Lib::Storage['buy_pool_menu_corp'] = corporation.id
                                   update
                                 }
                               else
                                 ->(_event) { exec_buy_shares("#pool_shares_#{corporation.id} .game-card", active_player, valid_pool_shares.first.to_bundle, corporation.id) }
                               end
        end

        pool_cell_children = []
        unless pool_share_text.empty?
          classes = ['game-card']
          classes << 'action-buy' if player_can_buy_pool || corporation_can_redeem_pool
          classes << 'clickable' if pool_click_handler
          dropdowns = []

          if Lib::Storage['pool_buyer_menu_corp'] == corporation.id && player_can_buy_pool && corporation_can_redeem_pool
            buyer_options = [
              {
                label: "Player: #{active_player.name}",
                action: lambda { |_event|
                  `event.stopPropagation()`
                  Lib::Storage['pool_buyer_menu_corp'] = nil

                  if player_can_short
                    Lib::Storage['pool_action_menu_corp'] = corporation.id
                    update
                  elsif valid_pool_shares.uniq { |share| share.to_bundle.percent }.size > 1

                    Lib::Storage['buy_pool_menu_corp'] = corporation.id
                    update
                  else
                    source_selector = "#pool_shares_#{corporation.id} .game-card"
                    exec_buy_shares(source_selector, active_player, valid_pool_shares.first.to_bundle, corporation.id)
                  end
                },
              },
              {
                label: "Corporation: #{corporation.name}",
                action: lambda { |_event|
                  `event.stopPropagation()`
                  Lib::Storage['pool_buyer_menu_corp'] = nil
                  if affordable_pool_redeems.size > 1
                    Lib::Storage['redeem_menu_corp'] = corporation.id
                    update
                  else
                    exec_redeem_share_bundle(
                      corporation,
                      affordable_pool_redeems.first,
                      corp_actions,
                      "#pool_shares_#{corporation.id} .game-card",
                      corporation_share_destination
                    )
                  end
                },
              },
            ]
            dropdowns << render_choice_menu('Who is buying?', buyer_options, lambda {
                                                                               Lib::Storage['pool_buyer_menu_corp'] = nil
                                                                               update
                                                                             })
          end

          if Lib::Storage['pool_action_menu_corp'] == corporation.id && player_can_buy_pool && player_can_short
            share_val = corporation.share_price ? @game.format_currency(corporation.share_price.price) : ''
            options = [
              {
                label: "Buy #{valid_pool_shares.first.to_bundle.percent}% from Pool (-#{share_val})",
                action: lambda { |_event|
                  `event.stopPropagation()`
                  Lib::Storage['pool_action_menu_corp'] = nil
                  source_selector = "#pool_shares_#{corporation.id} .game-card"
                  exec_buy_shares(source_selector, active_player, valid_pool_shares.first.to_bundle, corporation.id)
                },
              },
              {
                label: "Sell Short #{corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent : 10}% (+#{share_val})",
                action: lambda { |_event|
                  `event.stopPropagation()`
                  Lib::Storage['pool_action_menu_corp'] = nil
                  source_selector = "#pool_shares_#{corporation.id} .game-card"
                  exec_short_shares(source_selector, active_player, corporation)
                },
              },
            ]
            dropdowns << render_choice_menu("Pool action for #{corporation.name}:", options, lambda {
                                                                                               Lib::Storage['pool_action_menu_corp'] = nil
                                                                                               update
                                                                                             })
          end

          if Lib::Storage['buy_pool_menu_corp'] == corporation.id && !valid_pool_shares.empty?
            options = valid_pool_shares.uniq { |share| share.to_bundle.percent }.map do |share|
              bundle = share.to_bundle
              {
                label: "Buy #{bundle.percent}%",
                action: lambda { |_event|
                  `event.stopPropagation()`
                  Lib::Storage['buy_pool_menu_corp'] = nil
                  source_selector = "#pool_shares_#{corporation.id} .game-card"
                  exec_buy_shares(source_selector, active_player, bundle, corporation.id)
                },
              }
            end
            cancel_handler = lambda {
              Lib::Storage['buy_pool_menu_corp'] = nil
              update
            }
            dropdowns << render_choice_menu('Buy from Pool:', options, cancel_handler)
          end

          pool_card = render_railcard(pool_share_text, classes, pool_click_handler, nil, dropdowns)
          pool_hover = share_denomination_tooltip(pool_shares, corporation)
          pool_cell_children << h(:div, { attrs: { class: 'share-card-wrapper', title: pool_hover } }, [pool_card])
        end

        ipo_actual_shares = if corporation.minor?
                              []
                            elsif corporation.respond_to?(:ipo_shares) && corporation.ipo_shares
                              corporation.ipo_shares
                            elsif @game.separate_treasury?
                              @game.bank.shares_of(corporation)
                            elsif corporation.respond_to?(:shares_of)
                              corporation.shares_of(corporation)
                            else
                              []
                            end
        base_share_pct = corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent : 10
        ipo_percent = if corporation.minor? || n_ipo_shares <= 0
                        0
                      elsif ipo_actual_shares.respond_to?(:any?) && ipo_actual_shares.any?
                        total = ipo_actual_shares.sum { |s| s.respond_to?(:percent) ? s.percent : base_share_pct }
                        total -= num_reserved_shares(corporation) * base_share_pct if num_reserved_shares(corporation).positive?
                        [total, 0].max
                      else
                        n_ipo_shares * base_share_pct
                      end
        ipo_share_text = corporation.minor? || ipo_percent.zero? || n_ipo_shares <= 0 ? '' : "#{ipo_percent}%"
        ipo_click_handler = nil
        valid_ipo_shares = []

        player_actions = if active_player && @game.round.respond_to?(:actions_for)
                           begin; @game.round.actions_for(active_player); rescue StandardError; []; end
                         elsif step.respond_to?(:actions)
                           begin; step.actions(active_player) || []; rescue StandardError; []; end
                         elsif step.respond_to?(:current_actions)
                           step.current_actions || []
                         else
                           []
                         end || []

        is_corp = corporation.respond_to?(:corporation?) &&
                  corporation.corporation? &&
                  (!corporation.respond_to?(:minor?) || !corporation.minor?) &&
                  (!corporation.respond_to?(:ipoed) || !corporation.ipoed)

        corp_available = if corporation.respond_to?(:available?)
                           corporation.available?
                         elsif @game.respond_to?(:corporation_available?)
                           @game.corporation_available?(corporation)
                         else
                           true
                         end

        can_par = is_corp &&
                  active_player &&
                  player_actions.include?('par') &&
                  corp_available &&
                  (!@game.respond_to?(:can_par?) || @game.can_par?(corporation, active_player)) &&
                  (!step.respond_to?(:can_par?) || begin; step.can_par?(corporation, active_player); rescue ArgumentError; step.can_par?(active_player, corporation); end)

        can_bid = active_player && player_actions.include?('bid') && (
          if step.respond_to?(:can_bid?)
            begin; step.can_bid?(active_player, corporation); rescue ArgumentError; step.can_bid?(corporation); end
          elsif is_corp && @game.respond_to?(:can_par?)
            @game.can_par?(corporation, active_player)
          else
            corporation.respond_to?(:ipoed) ? !corporation.ipoed : true
          end
        )
        ipo_issuable_bundles = issuable_bundles.select do |b|
          shares = b.respond_to?(:shares) ? b.shares : [b]
          ipo_shares = corporation.respond_to?(:ipo_shares) ? corporation.ipo_shares : []
          shares.any? { |s| ipo_shares.include?(s) } || (bundle_owner(b) && bundle_owner(b) != corporation)
        end
        ipo_issuable_bundles = issuable_bundles if ipo_issuable_bundles.empty? && (!has_treasury_column? || @game.class.name.include?('1846') || treasury_shares_for(corporation).empty?)

        issue_from_ipo = can_issue && n_ipo_shares.positive? && ipo_issuable_bundles.any?
        if issue_from_ipo
          ipo_click_handler = if ipo_issuable_bundles.size > 1
                                lambda {
                                  Lib::Storage['issue_ipo_menu_corp'] = corporation.id
                                  update
                                }
                              else
                                lambda { |_event|
                                  exec_issue_share_bundle(
                                    corporation,
                                    ipo_issuable_bundles.first,
                                    corp_actions,
                                    "#ipo_shares_#{corporation.id} .game-card",
                                    "#pool_shares_#{corporation.id}"
                                  )
                                }
                              end
        elsif can_par
          par_prices = if step.respond_to?(:get_par_prices_with_help)
                         step.get_par_prices_with_help(active_player, corporation).sort_by(&:price)
                       elsif step.respond_to?(:get_par_prices)
                         step.get_par_prices(active_player, corporation).sort_by(&:price)
                       elsif @game.respond_to?(:par_prices)
                         @game.par_prices(corporation).sort_by(&:price)
                       else
                         @game.stock_market.par_prices.sort_by(&:price)
                       end
          if @game.respond_to?(:par_chart)
            par_prices = par_prices.reject do |sp|
              slots = @game.par_chart[sp]
              slots && slots.none?(&:nil?)
            end
          end

          pres_share = corporation.respond_to?(:presidents_share) && corporation.presidents_share ? corporation.presidents_share : (corporation.respond_to?(:shares) && corporation.shares&.first)
          shares_multiplier = if pres_share.respond_to?(:multiplier) && pres_share.multiplier
                                pres_share.multiplier
                              elsif pres_share.respond_to?(:percent) && corporation.respond_to?(:share_percent) && corporation.share_percent&.positive?
                                (pres_share.percent / corporation.share_percent).to_i
                              elsif pres_share.respond_to?(:percent)
                                (pres_share.percent / 10).to_i
                              else
                                2
                              end

          if step.respond_to?(:par_shares)
            bundle = begin; step.par_shares(corporation); rescue ArgumentError; step.par_shares(active_player, corporation); end
            if bundle
              shares_multiplier = if bundle.respond_to?(:num_shares)
                                    bundle.num_shares
                                  else
                                    (bundle.respond_to?(:shares) && bundle.shares ? bundle.shares.size : shares_multiplier)
                                  end
            end
          end
          shares_multiplier = 1 if shares_multiplier.to_i <= 0

          player_cash = active_player.respond_to?(:cash) ? (active_player.cash || 0) : 0
          par_prices = par_prices.select do |sp|
            price_val = sp.respond_to?(:price) ? sp.price : sp.to_i
            player_cash >= (price_val * shares_multiplier)
          end

          unless par_prices.empty?
            ipo_click_handler = lambda {
              Lib::Storage['par_menu_corp'] = corporation.id
              update
            }
          end
        elsif can_bid
          ipo_click_handler = lambda {
            store(:selected_corporation, corporation)
            store(:selected_company, nil)
            Lib::Storage['selected_bid_corp'] = corporation.id
            Lib::Storage["bid_price_#{corporation.id}"] = nil
            update
          }
        elsif step.respond_to?(:can_buy?) && active_player
          ipo_shares = corporation.respond_to?(:ipo_shares) ? corporation.ipo_shares : []
          valid_ipo_shares = ipo_shares.select { |s| (s.respond_to?(:buyable) ? s.buyable : true) && step.can_buy?(active_player, s.to_bundle) }

          unless valid_ipo_shares.empty?
            ipo_click_handler = if valid_ipo_shares.uniq { |s| s.to_bundle.percent }.size > 1
                                  lambda {
                                    Lib::Storage['buy_ipo_menu_corp'] = corporation.id
                                    update
                                  }
                                else
                                  lambda { |_event|
                                    source_selector = "#ipo_shares_#{corporation.id} .game-card"
                                    exec_buy_shares(source_selector, active_player, valid_ipo_shares.first.to_bundle, corporation.id)
                                  }
                                end
          end
        end

        ipo_cell_children = []
        unless ipo_share_text.empty?
          card_classes = ['game-card']
          card_classes << 'action-sell' if issue_from_ipo
          card_classes << 'action-buy' if ipo_click_handler && !issue_from_ipo
          card_classes << 'clickable' if ipo_click_handler

          dropdowns = []
          if Lib::Storage['issue_ipo_menu_corp'] == corporation.id && issue_from_ipo
            options = (ipo_issuable_bundles || issuable_bundles).map do |bundle|
              pct = bundle.respond_to?(:percent) ? bundle.percent : bundle.shares.sum(&:percent)
              {
                label: "Issue #{pct}%",
                action: lambda { |_event|
                  Lib::Storage['issue_ipo_menu_corp'] = nil
                  exec_issue_share_bundle(
                    corporation,
                    bundle,
                    corp_actions,
                    "#ipo_shares_#{corporation.id} .game-card",
                    "#pool_shares_#{corporation.id}"
                  )
                },
              }
            end
            dropdowns << render_choice_menu('Issue shares:', options, lambda {
                                                                        Lib::Storage['issue_ipo_menu_corp'] = nil
                                                                        update
                                                                      })
          end
          if Lib::Storage['buy_ipo_menu_corp'] == corporation.id && !valid_ipo_shares.empty?
            options = valid_ipo_shares.uniq { |share| share.to_bundle.percent }.map do |share|
              {
                label: "Buy #{share.to_bundle.percent}%",
                action: lambda { |_event|
                  Lib::Storage['buy_ipo_menu_corp'] = nil
                  source_selector = "#ipo_shares_#{corporation.id} .game-card"
                  exec_buy_shares_simple(source_selector, active_player, share.to_bundle, corporation.id)
                },
              }
            end
            cancel_handler = lambda {
              Lib::Storage['buy_ipo_menu_corp'] = nil
              update
            }
            dropdowns << render_choice_menu('Buy from IPO:', options, cancel_handler)
          end

          ipo_card = render_railcard(ipo_share_text, card_classes, ipo_click_handler, nil, dropdowns)

          ipo_hover = share_denomination_tooltip(ipo_actual_shares, corporation)
          ipo_cell_children << h(:div, { attrs: { class: 'share-card-wrapper', title: ipo_hover } }, [ipo_card])
        end

        border_style = "1px solid #{color_for(:font2)}"
        market_style = {}
        if corporation.share_price&.highlight? &&
           (m_color = StockMarket::COLOR_MAP[@game.class::STOCKMARKET_COLORS[corporation.share_price.type]])
          market_style[:backgroundColor] = m_color
          market_style[:color] = contrast_on(m_color)
        end
        is_operating = @game.operating_order.include?(corporation)
        clean_market_price = corporation.share_price && is_operating ? @game.format_currency(corporation.share_price.price) : ''
        clean_par_price = corporation.par_price ? @game.format_currency(corporation.par_price.price) : ''

        pool_row_content = [
            h('td.column-zone-market.market-shares-col', { attrs: { id: "pool_shares_#{corporation.id}" }, style: { position: 'relative', textAlign: 'center', borderLeft: border_style } }, pool_cell_children),
            h('td.padded_number.column-zone-market.money-value.market-price-col', { style: market_style.merge(borderRight: border_style) }, clean_market_price),
          ]

        bank_row_content = [
          h('td.column-zone-market.ipo-zone.market-shares-col', { attrs: { id: "ipo_shares_#{corporation.id}" }, style: { position: 'relative', textAlign: 'center' } }, ipo_cell_children),
          h('td.padded_number.column-zone-market.ipo-zone.money-value.market-price-col', { style: { borderRight: border_style } }, clean_par_price),
        ]

        train_buyable_step = step&.current_actions&.include?('buy_train')
        train_discardable_step = step&.current_actions&.include?('discard_train')
        step_buyable_trains = train_buyable_step && active_entity && step.respond_to?(:buyable_trains) ? step.buyable_trains(active_entity) : nil
        corp_owner = ->(corp) { step.respond_to?(:corp_owner) ? step.corp_owner(corp) : corp&.owner }
        same_player = active_entity && corporation != active_entity && corp_owner.call(corporation) && corp_owner.call(corporation) == corp_owner.call(active_entity)

        train_cards = corporation.trains.map do |t|
          card_classes = ['game-card']
          train_click_handler = nil
          menu_dropdown = nil

          is_buyable_other_train = if !same_player
                                     false
                                   elsif step_buyable_trains
                                     step_buyable_trains.include?(t)
                                   elsif train_buyable_step
                                     !step.respond_to?(:can_buy_train?) || step.can_buy_train?(active_entity, t)
                                   else
                                     false
                                   end

          if is_buyable_other_train
            card_classes << 'action-buy'
            card_classes << 'clickable'
            min_price = 1
            max_price = if step.respond_to?(:max_price)
                          step.max_price(active_entity, t)
                        else
                          (active_entity.respond_to?(:cash) ? active_entity.cash : 9999)
                        end

            train_click_handler = lambda {
              `var p = document.getElementById('railcard-portal'); if (p) { p.style.display = 'none'; p.innerHTML = ''; }`
              menu_title = "Buy #{t.name} from #{corporation.name} (#{min_price}-#{max_price}):"
              default_price = min_price

              show_price_dialog(menu_title, min_price, max_price, default_price, lambda { |price_val|
                escaped_train_wrapper_id = `CSS.escape('train_wrapper_' + #{corporation.id} + '_' + #{t.id})`
                source_selector = "##{escaped_train_wrapper_id} .game-card"
                exec_buy_corporate_train(source_selector, active_entity, t, price_val)
              })
            }
          elsif train_discardable_step && active_entity == corporation
            card_classes << 'action-sell'
            card_classes << 'clickable'

            train_click_handler = lambda {
              process_action(Engine::Action::DiscardTrain.new(active_entity, train: t))
            }
          end

          wrapper_id = "train_wrapper_#{corporation.id}_#{t.id}"
          render_railcard(t.obsolete ? "(#{t.name})" : t.name, card_classes, train_click_handler, nil, menu_dropdown, wrapper_id)
        end

        raw_limit = begin
          @game.train_limit(corporation)
        rescue StandardError
          4
        end
        raw_limit = 4 if raw_limit.nil? || (raw_limit.respond_to?(:infinite?) && raw_limit.infinite?)
        limit = [raw_limit.to_i, 4].min
        empty_count = [[limit - corporation.trains.size, 0].max, 4].min

        empty_count = [limit - corporation.trains.size, 0].max
        empty_count.times do |slot_index|
          attrs = { class: 'empty-train-slot' }
          attrs[:id] = "train_drop_#{corporation.id}" if slot_index.zero?
          train_cards << h(:div, { attrs: attrs, style: { width: '3.5rem', height: '1.45rem', backgroundColor: 'transparent', border: '1px dashed #999', borderRadius: '15px', margin: '2px', boxSizing: 'border-box', display: 'inline-flex', verticalAlign: 'middle' } })
        end

        clean_corp_cash = @game.format_currency(corporation.cash)
        last_rev = corporation.operating_history.values.last&.revenue
        clean_rev = last_rev ? @game.format_currency(last_rev) : ''

        corporation_row_content = [
          *treasury,
          h('td.padded_number.column-zone-corporate.money-value.corporation-cash', { hook: Lib::MoneyAnimation.hook }, clean_corp_cash),
          h('td.column-zone-corporate.corporation-trains', { attrs: { id: "trains_#{corporation.id}" } }, train_cards),
          h('td.column-zone-corporate', {}, [render_unplaced_tokens(corporation)]),
          *extra,
        ]
        corporation_row_content << render_companies(corporation, nil, 'column-zone-corporate') if @show_privates

        last_run = corporation.operating_history.values.last
        div = if last_run.respond_to?(:dividend)
                last_run.dividend
              else
                (last_run.is_a?(Hash) ? last_run[:dividend] : nil)
              end
        div_kind = (div.respond_to?(:kind) ? div.kind : div).to_s.downcase

        held = if last_run.respond_to?(:withheld?)
                 last_run.withheld?
               elsif last_run.respond_to?(:withhold?)
                 last_run.withhold?
               else
                 div_kind.start_with?('withhold', 'held', 'hold')
               end

        half_held = last_run.respond_to?(:half?) ? last_run.half? : div_kind.start_with?('half', 'split')
        held = false if clean_rev.empty?
        half_held = false if clean_rev.empty? || held

        font_color = '#dc2626' if held
        font_color = '#d97706' if half_held

        rev_class = "td.padded_number.column-zone-corporate#{'.money-value' unless font_color}"
        rev_props = { hook: Lib::MoneyAnimation.hook }
        rev_props[:style] = { color: font_color, fontFamily: 'var(--font-money)', fontWeight: 'bold', fontVariantNumeric: 'tabular-nums' }.compact
        corporation_row_content << h(rev_class, rev_props, clean_rev)

        row_content = []
        row_content.concat(players_row_content)
        row_content.concat(pool_row_content)
        row_content.concat(bank_row_content)
        row_content.concat(corporation_row_content)

        major_card = render_major_railcard(
          corporation,
          nil,
          ['major-railcard'],
          "status_major_#{corporation.id}"
        )

        h(:tr, tr_props, [
          h(:th, name_props, [major_card].compact),
          *row_content,
        ])
      end

      def render_unplaced_tokens(corporation)
        return h(:span, { attrs: { id: "tokens_#{corporation.id}" } }, '') unless corporation.respond_to?(:tokens)

        unplaced = corporation.tokens.select do |t|
          has_hex = t.respond_to?(:hex) && t.hex
          is_placed = t.respond_to?(:placed?) && t.placed?
          !has_hex && !is_placed
        end
        return h(:span, { attrs: { id: "tokens_#{corporation.id}" } }, '') if unplaced.empty?

        logo_src = begin; setting_for(:simple_logos, @game) ? corporation.simple_logo : corporation.logo; rescue StandardError; nil; end

        tooltip_style = <<~CSS
          .unplaced-token-wrapper { position: relative; display: inline-flex; align-items: center; justify-content: center; cursor: help; margin: 2px; }
          .unplaced-token-wrapper[title]:not([title=""]):hover::after {
            content: attr(title);
            position: absolute;
            bottom: calc(100% + 4px);
            left: 50%;
            transform: translateX(-50%);
            background: rgba(15, 23, 42, 0.95);
            color: #ffffff;
            font-family: var(--font-money, monospace);
            font-size: 1.44rem;
            font-weight: bold;
            line-height: 1;
            padding: 4px 10px;
            border-radius: 5px;
            white-space: nowrap;
            pointer-events: none;
            z-index: 99999;
            box-shadow: 0 3px 6px rgba(0,0,0,0.35);
          }
        CSS

        token_icons = unplaced.map do |token|
          raw_cost = if token.respond_to?(:price) && !token.price.nil?
                       token.price
                     elsif token.respond_to?(:cost) && !token.cost.nil?
                       token.cost
                     elsif token.instance_variable_defined?(:@price) && !token.instance_variable_get(:@price).nil?
                       token.instance_variable_get(:@price)
                     elsif corporation.respond_to?(:token_price)
                       begin; corporation.token_price(token); rescue StandardError; nil; end
                     elsif @game.respond_to?(:token_cost)
                       begin; @game.token_cost(token); rescue StandardError; nil; end
                     end

          cost = raw_cost ? raw_cost.to_s : ''
          wrapper_props = { attrs: { class: 'unplaced-token-wrapper', title: cost } }

          if logo_src
            img_style = { width: '20px', height: '20px', borderRadius: '50%', boxSizing: 'border-box', display: 'block', border: '1px solid #333', backgroundColor: corporation.color || '#fff', pointerEvents: 'none' }
            h(:div, wrapper_props, [h(:img, { attrs: { src: logo_src }, style: img_style })])
          else
            div_style = { width: '20px', height: '20px', borderRadius: '50%', boxSizing: 'border-box', display: 'block', border: '1px solid #333', lineHeight: '18px', textAlign: 'center', backgroundColor: corporation.color || '#4169e1', color: corporation.text_color || '#fff', fontSize: '0.55rem', fontWeight: 'bold', pointerEvents: 'none' }
            h(:div, wrapper_props, [h(:div, { style: div_style }, corporation.id.to_s[0..2])])
          end
        end

        h(:div, { attrs: { id: "tokens_#{corporation.id}" }, style: { display: 'flex', flexDirection: 'row', justifyContent: 'center', flexWrap: 'wrap' } }, [h(:style, tooltip_style), *token_icons])
      end

      def share_denomination_tooltip(shares, corporation)
        shares_list = Array(shares).compact
        return '' if shares_list.size <= 1

        counts = Hash.new(0)
        shares_list.each do |share|
          raw_pct = if share.respond_to?(:percent) && share.percent
                      share.percent
                    elsif corporation&.respond_to?(:share_percent) && corporation.share_percent
                      corporation.share_percent
                    else
                      10
                    end
          counts[raw_pct] += 1
        end

        return '' if counts.empty? || counts.values.sum <= 1

        entries = counts.sort_by { |pct, _| -pct }.map do |pct, count|
          pct_str = (pct.to_f % 1).zero? ? "#{pct.to_i}%" : "#{pct.to_f.round(1)}%"
          "#{count} x #{pct_str}"
        end

        case entries.size
        when 1
          entries.first
        when 2
          entries.join(' and ')
        else
          "#{entries[0...-1].join(', ')} and #{entries.last}"
        end
      end

      def exec_short_shares(source_selector, player, corporation)
        action = if defined?(Engine::Action::Short)
                   Engine::Action::Short.new(player, corporation: corporation)
                 else
                   Engine::Action::BuyShares.new(player, bundle: corporation.shares.first.to_bundle)
                 end
        process_action(action)
      end

      def render_corp_tokens(corporation)
        return h(:span, '') unless corporation.respond_to?(:tokens)

        tokens = corporation.tokens
        return h(:span, '') if tokens.empty?

        logo_src = begin; setting_for(:simple_logos, @game) ? corporation.simple_logo : corporation.logo; rescue StandardError; nil; end

        token_icons = tokens.map do |token|
          is_placed = token.respond_to?(:hex) && token.hex
          style = { width: '20px', height: '20px', margin: '2px', borderRadius: '50%', boxSizing: 'border-box', display: 'inline-block', border: '1px solid #333', opacity: is_placed ? '1' : '0.3' }

          if logo_src
            style[:backgroundColor] = corporation.color || '#fff'
            h(:img, { attrs: { src: logo_src }, style: style })
          else
            style[:lineHeight] = '18px'
            style[:textAlign] = 'center'
            style[:backgroundColor] = corporation.color || '#4169e1'
            style[:color] = corporation.text_color || '#fff'
            style[:fontSize] = '0.55rem'
            style[:fontWeight] = 'bold'
            h(:div, { style: style }, corporation.id.to_s[0..2])
          end
        end

        h(:div, { style: { display: 'flex', flexDirection: 'row', justifyContent: 'center', flexWrap: 'wrap' } }, token_icons)
      end

      def render_loan_dots(entity)
        return h(:div, '') if !entity.respond_to?(:loans) || !@game.respond_to?(:maximum_loans)

        taken = entity.loans.size
        maximum = @game.maximum_loans(entity)
        # Cap excessive or indefinite loan slots (e.g. PSR or games with unlimited loans) to max 10
        maximum = [maximum, 10].min if maximum > 10
        actions = status_actions_for(entity)
        if entity == active_entity && @game.round.active_step&.respond_to?(:current_actions)
          actions = (actions + (@game.round.active_step.current_actions || [])).uniq
        end
        can_take = actions.include?('take_loan') && @game.respond_to?(:loans) && @game.loans&.any?
        can_repay = actions.include?('payoff_loan') && entity.loans.any?
        dots = []

        taken.times do |index|
          dot_props = { attrs: { id: "loan_dot_#{entity.id}_#{index}" }, style: { display: 'inline-block', width: '8px', height: '8px', backgroundColor: '#dc3545', borderRadius: '50%', margin: '0 2px', pointerEvents: 'none' } }
          dots << h(:span, dot_props)
        end

        [maximum - taken, 0].max.times do |index|
          dot_props = { attrs: { id: "loan_empty_#{entity.id}_#{index}" }, style: { display: 'inline-block', width: '8px', height: '8px', border: '1px solid #dc3545', borderRadius: '50%', margin: '0 2px', boxSizing: 'border-box', pointerEvents: 'none' } }
          dots << h(:span, dot_props)
        end

        interest = @game.respond_to?(:interest_owed) ? @game.interest_owed(entity) : 0
        dots << h(:span, { style: { marginLeft: '4px', fontSize: '0.75rem', fontWeight: 'bold', pointerEvents: 'none' } }, @game.format_currency(interest))

        wrapper_props = {
          attrs: {
            id: "loan_wrapper_#{entity.id}",
            title: can_repay ? "Payoff Loan for #{entity.name}" : '',
          },
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: can_repay ? 'pointer' : 'default',
            padding: '2px 6px',
            backgroundColor: can_repay ? '#fef2f2' : 'transparent',
            border: can_repay ? '2px solid #dc2626' : '1px solid transparent',
            borderRadius: '4px',
            boxShadow: can_repay ? '0 1px 3px rgba(220,38,38,0.25)' : 'none',
            boxSizing: 'border-box',
          },
        }

        if can_repay
          wrapper_props[:on] = {
            click: lambda { |_event|
              `if (event) { event.stopPropagation(); event.preventDefault(); }`
              source_id = "#loan_dot_#{entity.id}_#{taken - 1}"
              Lib::LoanAnimation.fly(source_id, '#bank_loan_active') do
                process_action(Engine::Action::PayoffLoan.new(entity, loan: entity.loans.last))
              end
            },
          }
        end

        h(:div, wrapper_props, dots)
      end

      def render_companies(entity, bg_color = nil, custom_class = nil, is_last: false)
        props = { attrs: { id: "companies_#{entity.id}", class: ['align-top', custom_class, ('thick-right' if is_last)].compact.join(' ') } }
        props[:style] = entity.player? ? { maxWidth: PLAYER_COL_MAX_WIDTH, whiteSpace: 'normal', textAlign: 'right', minWidth: min_width(entity) } : {}
        props[:style][:backgroundColor] = bg_color if bg_color

        companies_list = entity.respond_to?(:companies) ? entity.companies : []
        companies_list = companies_list.reject { |c| c.respond_to?(:closed?) && c.closed? }

        step = @game.round.active_step
        active_ent = active_entity
        actions = active_ent && @game.round.respond_to?(:actions_for) ? @game.round.actions_for(active_ent) : (step&.current_actions || [])
        company_buyable_step = actions.include?('buy_company')

        special_actions = actions - %w[lay_tile place_token run_routes dividend payout withhold half split buy_train pass buy_company merge choose end_game bankrupt]
        valid_special_actions = special_actions.map do |action_name|
          action_class = begin; Engine::Action.const_get(action_name.split('_').map(&:capitalize).join); rescue NameError; nil; end
          next nil unless action_class

          required_args = action_class.const_defined?(:REQUIRED_ARGS) ? action_class::REQUIRED_ARGS : []
          required_args.include?(:company) ? [action_name, action_class] : nil
        end.compact

        company_cards = companies_list.map do |c|
          card_classes = ['game-card']
          company_click_handler = nil
          menu_dropdown = nil
          not_own_company = active_ent && entity != active_ent

          buy_company_step = nil
          is_buyable = false
          if @game.round.respond_to?(:steps)
            buy_company_step = @game.round.steps.find do |s|
              (s.respond_to?(:buyable_companies) && s.buyable_companies(active_ent).include?(c)) ||
                (s.respond_to?(:can_buy_company?) && s.can_buy_company?(active_ent, c))
            end
            is_buyable = true if buy_company_step
          end

          unless is_buyable
            buy_company_step = step
            is_buyable = if step.respond_to?(:buyable_companies)
                           step.buyable_companies(active_ent).include?(c)
                         elsif step.respond_to?(:can_buy_company?)
                           step.can_buy_company?(active_ent, c)
                         elsif c.respond_to?(:owned_by?)
                           !c.owned_by?(active_ent)
                         else
                           c.owner != active_ent
                         end
          end

          is_buyable = false if active_ent.respond_to?(:corporation?) && active_ent.corporation? && (!c.owner || c.owner != active_ent.owner)

          matching_special_action = valid_special_actions.find do |_, _action_class|
            targets = if step.respond_to?(:available_targets)
                        step.available_targets(active_ent) || []
                      else
                        (step.respond_to?(:companies) ? (step.companies || []) : [])
                      end
            targets.include?(c)
          end

          if matching_special_action
            card_classes << 'action-buy'
            card_classes << 'clickable'
            company_click_handler = lambda {
              process_action(matching_special_action[1].new(active_ent, company: c))
            }
          elsif company_buyable_step && not_own_company && is_buyable
            card_classes << 'action-buy'
            card_classes << 'clickable'
            min_price = if buy_company_step.respond_to?(:min_price)
                          buy_company_step.min_price(c)
                        else
                          (c.respond_to?(:min_price) ? c.min_price : 1)
                        end
            max_price = if buy_company_step.respond_to?(:max_price)
                          buy_company_step.max_price(active_ent, c)
                        elsif c.respond_to?(:max_price)
                          c.max_price
                        else
                          (active_ent.respond_to?(:cash) ? active_ent.cash : 9999)
                        end

            company_click_handler = lambda {
              `var p = document.getElementById('railcard-portal'); if (p) { p.style.display = 'none'; p.innerHTML = ''; }`
              menu_title = "Buy #{c.name} (#{min_price}-#{max_price}):"
              default_price = [active_ent.respond_to?(:cash) ? active_ent.cash : min_price, max_price].min
              default_price = [default_price, min_price].max

              show_price_dialog(menu_title, min_price, max_price, default_price, lambda { |price_val|
                process_action(Engine::Action::BuyCompany.new(active_ent, company: c, price: price_val))
              })
            }
          end
          tooltip_card = if active_ent
                           begin
                             build_company_tooltip(c)
                           rescue StandardError
                             nil
                           end
                         end
          wrapper_id = "company_wrapper_#{entity.id}_#{c.id}"
          wrapper_classes = ['status-company-wrapper']
          render_railcard(c.sym, card_classes, company_click_handler, tooltip_card, menu_dropdown, wrapper_id, wrapper_classes)
        end
        h(:td, props, company_cards)
      end

      def render_player_companies
        h(:tr, tr_default_props, [
          h('th.left', 'Companies'),
          *display_players.map.with_index do |p, idx|
            is_active_col = (p == active_player)
            bg_color = is_active_col ? COLOR_ACTIVE : COLOR_INACTIVE
            is_last = idx == @game.players.size - 1
            h("td.align-top#{'.thick-right' if is_last}", { style: { backgroundColor: bg_color } }, [render_companies(p)])
          end,
          h(:td, { attrs: { colspan: 30 }, style: { border: 'none' } }, ''),
        ])
      end

      def exec_issue_share_bundle(corporation, bundle, corp_actions = nil, source_selector = nil, target_selector = nil)
        actions = corp_actions || status_corporation_actions(corporation)
        shares = bundle.respond_to?(:shares) ? bundle.shares : [bundle]
        share_price = (bundle.respond_to?(:share_price) && bundle.share_price) || corporation.share_price
        percent = bundle.respond_to?(:percent) ? bundle.percent : shares.sum(&:percent)
        action = if actions.include?('issue_shares') && defined?(Engine::Action::IssueShares)
                   Engine::Action::IssueShares.new(corporation, shares: shares)
                 elsif actions.include?('issue') && defined?(Engine::Action::Issue)
                   Engine::Action::Issue.new(corporation, bundle: bundle)
                 elsif actions.include?('reissue_shares') && defined?(Engine::Action::ReissueShares)
                   Engine::Action::ReissueShares.new(corporation, bundle: bundle)
                 elsif actions.include?('reissue') && defined?(Engine::Action::Reissue)
                   Engine::Action::Reissue.new(corporation, bundle: bundle)
                 elsif actions.include?('corporate_sell_shares') && defined?(Engine::Action::CorporateSellShares)
                   Engine::Action::CorporateSellShares.new(corporation, bundle: bundle)
                 else
                   Engine::Action::SellShares.new(
                   corporation,
                   shares: shares,
                   share_price: share_price,
                   percent: percent
                 )
                 end

        process_action(action)
      end

      def exec_redeem_share_bundle(
        corporation,
        bundle,
        corp_actions = nil,
        source_selector = nil,
        target_selector = nil
      )
        actions = corp_actions || status_corporation_actions(corporation)

        bundle =
          if defined?(Engine::ShareBundle) &&
             bundle.is_a?(Engine::ShareBundle)
            bundle
          elsif bundle.respond_to?(:to_bundle)
            bundle.to_bundle
          else
            Engine::ShareBundle.new(Array(bundle))
          end

        shares = bundle.shares.flatten.compact
        share_price =
          if bundle.respond_to?(:share_price) && bundle.share_price
            bundle.share_price
          else
            corporation.share_price
          end
        percent =
          if bundle.respond_to?(:percent)
            bundle.percent
          else
            shares.sum(&:percent)
          end

        action_kwargs = {
          shares: shares,
          share_price: share_price,
          percent: percent,
        }.compact

        action =
          if actions.include?('redeem_shares') &&
             defined?(Engine::Action::RedeemShares)
            Engine::Action::RedeemShares.new(
              corporation,
              **action_kwargs
            )
          elsif actions.include?('redeem') &&
                defined?(Engine::Action::Redeem)
            Engine::Action::Redeem.new(
              corporation,
              **action_kwargs
            )
          elsif actions.include?('corporate_buy_shares') &&
                defined?(Engine::Action::CorporateBuyShares)
            Engine::Action::CorporateBuyShares.new(
              corporation,
              bundle: bundle
            )
          else
            Engine::Action::BuyShares.new(
              corporation,
              bundle: bundle
            )
          end

        process_action(action)
      end

      def render_player_cash
        h(:tr, tr_default_props, [
          h('th.left', 'Cash'),
          *display_players.map do |p|
            clean_cash = @game.format_currency(p.cash)
            is_active_col = (p == active_player)
            bg_color = is_active_col ? COLOR_ACTIVE : COLOR_INACTIVE
            h('td.padded_number.money-value', { hook: Lib::MoneyAnimation.hook, style: { backgroundColor: bg_color } }, clean_cash)
          end,
        ])
      end

      def render_player_certs
        cert_limit = @game.cert_limit
        props = { style: { color: 'red' } }
        h(:tr, tr_default_props, [
          h('th.left', 'Cert'),
          *display_players.map.with_index do |player, idx|
            is_active_col = (player == active_player)
            bg_color = is_active_col ? COLOR_ACTIVE : COLOR_INACTIVE
            num_certs = @game.num_certs(player)
            cell_props = num_certs > cert_limit ? props.merge(style: { backgroundColor: bg_color }) : { style: { backgroundColor: bg_color } }
            is_last = idx == @game.players.size - 1
            h("td.padded_number#{'.thick-right' if is_last}", cell_props, "#{num_certs}/#{cert_limit}")
          end,
          h(:td, { attrs: { colspan: 30 }, style: { border: 'none' } }, ''),
        ])
      end

      def render_player_loans
        return '' unless @game.respond_to?(:player_loans)

        h(:tr, tr_default_props, [
          h('th.left', 'Loans'),
          *display_players.map.with_index do |p, idx|
            is_active_col = (p == active_player)
            bg_color = is_active_col ? COLOR_ACTIVE : COLOR_INACTIVE
            is_last = idx == @game.players.size - 1
            h("td.padded_number#{'.thick-right' if is_last}", { style: { backgroundColor: bg_color } }, @game.player_loans(p))
          end,
          h(:td, { attrs: { colspan: 30 }, style: { border: 'none' } }, ''),
        ])
      end

      def tr_default_props(is_active_row = false)
        {
          style: {
            backgroundColor: is_active_row ? COLOR_ACTIVE : COLOR_INACTIVE,
            color: '#000000',
            fontFamily: FONT_STD,
          },
        }
      end

      def money_props(extra_style = {})
        { style: { fontFamily: FONT_MONEY, fontWeight: 'bold' }.merge(extra_style) }
      end

      def table_props
        {
          style: {
            borderCollapse: 'collapse',
            textAlign: 'center',
            whiteSpace: 'nowrap',
          },
        }
      end

      def exec_sell_shares(source_selector, player, target_bundle, corporation_id)
        bundle = target_bundle[:bundle]
        shares = bundle.respond_to?(:shares) ? bundle.shares : [bundle]
        percent = bundle.respond_to?(:percent) ? bundle.percent : shares.sum(&:percent)

        %x{
    if (typeof window !== 'undefined') {
      window._railcard_pending_source = #{source_selector};
    }
  }

        process_action(
          Engine::Action::SellShares.new(
            player,
            bundle: bundle,
            shares: shares,
            share_price: (bundle.share_price if bundle.respond_to?(:share_price)),
            percent: percent
          )
        )
      end

      def exec_buy_shares(source_selector, player, bnd, corporation_id)
        bundle = bnd.respond_to?(:to_bundle) && !bnd.respond_to?(:num_shares) ? bnd.to_bundle : bnd
        shares = bundle.respond_to?(:shares) ? bundle.shares : [bundle]
        percent = bundle.respond_to?(:percent) ? bundle.percent : shares.sum(&:percent)
        share_price = bundle.respond_to?(:share_price) ? bundle.share_price : nil

        %x{
    if (typeof window !== 'undefined') {
      window._railcard_pending_source = #{source_selector};
    }
  }

        process_action(
          Engine::Action::BuyShares.new(
            player,
            bundle: bundle,
            shares: shares,
            share_price: share_price,
            percent: percent
          )
        )
      end

      def exec_buy_shares_simple(source_selector, player, bnd, corporation_id)
        bundle = bnd.respond_to?(:to_bundle) && !bnd.respond_to?(:num_shares) ? bnd.to_bundle : bnd
        shares = bundle.respond_to?(:shares) ? bundle.shares : [bundle]
        percent = bundle.respond_to?(:percent) ? bundle.percent : shares.sum(&:percent)
        share_price = bundle.respond_to?(:share_price) ? bundle.share_price : nil

        %x{
    if (typeof window !== 'undefined') {
      window._railcard_pending_source = #{source_selector};
    }
  }

        process_action(
          Engine::Action::BuyShares.new(
            player,
            bundle: bundle,
            shares: shares,
            share_price: share_price,
            percent: percent
          )
        )
      end

      def exec_buy_corporate_train(source_selector, active_entity, train, price_value)
        process_action(Engine::Action::BuyTrain.new(
           active_entity,
           train: train,
           price: price_value
         ))
      end

      def pd_props
        { style: { backgroundColor: 'salmon', color: 'black' } }
      end

      def render_choice_menu(title, options, cancel_handler)
        menu_elements = [
          h(:div, { style: { fontSize: '0.75rem', fontWeight: 'bold', marginBottom: '0.4rem', color: '#333', whiteSpace: 'nowrap' } }, title),
        ]

        options.each do |opt|
          menu_elements << h(:button, {
                               style: { display: 'block', width: '100%', marginBottom: '0.2rem', cursor: 'pointer', fontSize: '0.75rem', fontWeight: 'bold', padding: '3px 6px', backgroundColor: '#ffffff', border: '1px solid #cc0000', borderRadius: '3px' },
                               on: {
                                 click: lambda { |event|
                                   `event.stopPropagation()`
                                   opt[:action].arity.zero? ? opt[:action].call : opt[:action].call(event)
                                 },
                               },
                             }, opt[:label])
        end

        menu_elements << h(:button, {
                             style: { display: 'block', width: '100%', cursor: 'pointer', fontSize: '0.75rem', padding: '3px 6px', backgroundColor: '#e0e0e0', border: '1px solid #999', borderRadius: '3px', marginTop: '0.2rem' },
                             on: {
                               click: lambda { |event|
                                 `event.stopPropagation()`
                                 cancel_handler.arity.zero? ? cancel_handler.call : cancel_handler.call(event)
                               },
                             },
                           }, 'Cancel')

        h(:div, {
            style: { position: 'absolute', top: '105%', left: '50%', transform: 'translateX(-50%)', backgroundColor: '#ffffff', border: '2px solid #333333', borderRadius: '4px', padding: '0.5rem', zIndex: '9999', boxShadow: '0px 4px 10px rgba(0,0,0,0.3)' },
          }, menu_elements)
      end

      private

      def has_treasury_column?
        storage_key = "dashboard_treasury_column_#{@game.class.name}"
        treasury_required = @game.separate_treasury? || any_reserved_shares?
        Lib::Storage[storage_key] = true if treasury_required
        [true, 'true'].include?(Lib::Storage[storage_key])
      end

      def treasury_shares_for(corporation)
        return corporation.shares_of(corporation) if @game.separate_treasury? && corporation.respond_to?(:shares_of)

        []
      end

      def num_ipo_shares(corporation)
        if @game.separate_treasury?
          num_shares_of(@game.bank, corporation) - num_reserved_shares(corporation)
        elsif corporation.respond_to?(:num_ipo_shares)
          corporation.num_ipo_shares - num_reserved_shares(corporation)
        elsif corporation.respond_to?(:ipo_shares) && corporation.ipo_shares
          corporation.ipo_shares.size - num_reserved_shares(corporation)
        else
          num_shares_of(corporation, corporation) - num_reserved_shares(corporation)
        end
      end

      def num_reserved_shares(corporation)
        return 0 unless corporation.respond_to?(:num_ipo_reserved_shares)

        corporation.num_ipo_reserved_shares || 0
      end

      def any_reserved_shares?
        @game.all_corporations.any? { |c| num_reserved_shares(c).positive? }
      end

      def min_width(entity)
        PLAYER_COL_MAX_WIDTH if entity.companies.size > 1 || @game.format_currency(entity.value).size > 6
      end
    end
  end
end

# rubocop:enable Layout/LineLength
