# frozen_string_literal: true

# backtick_javascript: true

# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'view/game/abilities'
require 'view/game/buy_companies'
require 'view/game/dashboard/results_overlay'
require 'view/game/dashboard/dashboard_card_animation'
require 'view/game/dashboard/dashboard_loan_animation'
require 'view/game/history_and_undo'
require 'view/game/dashboard/railcard_helper'
require 'view/game/round/operating'
require 'view/game/dashboard/actions_monitor_overlay'
require 'view/game/dashboard/manual_route_overlay'
require 'view/game/dashboard/draft_overlay'
require 'view/game/dashboard/history_overlay'
require 'view/game/dashboard/move_history_overlay'

class String
  def player?
    false
  end
end

module Engine
  class Minor
    def player?
      false
    end
  end

  class Hex
    def to_s
      if respond_to?(:name) && name
        name.to_s
      else
        (respond_to?(:id) && id ? id.to_s : super)
      end
    end
  end
end

module View
  module Game
    ManualRouteOverlay = Dashboard::ManualRouteOverlay

    class DashboardCommandColumn < Snabberb::Component
      include Actionable
      include Lib::Settings
      include View::Game::Dashboard::RailcardHelper

      FONT_MONEY = '"Courier New", Courier, monospace'
      COLOR_MONEY = '#4c1d95'

      SCREAMING_PALETTE = ['#ff1493', '#00ffff', '#7fff00', '#ff00ff'].freeze
      needs :game, store: true
      needs :game_data, store: true, default: nil
      needs :routes, store: true, default: []
      needs :selected_route, store: true, default: nil
      needs :last_routed_action_id, store: true, default: nil
      needs :last_entity, store: true, default: nil
      needs :cmd_router_running, store: true, default: false
      needs :show_manual_routes, store: true, default: false
      # needs :show_actions_monitor, store: true, default: false
      needs :show_move_history, store: true, default: false
      needs :show_history_overlay, store: true, default: false

      def current_entity
        @game.round.active_step&.current_entity ||
          (@game.round.respond_to?(:current_entity) ? @game.round.current_entity : nil) ||
          @game.current_entity
      rescue NotImplementedError, StandardError
        nil
      end

      def active_routes
        @routes.select { |r| r.chains.any? }
      end

      def actions_for(entity)
        return [] unless entity && @game.round.respond_to?(:actions_for)

        @game.round.actions_for(entity) || []
      rescue NotImplementedError, StandardError
        []
      end

      def active_step_for(entity)
        return nil unless @game.round.respond_to?(:active_step)

        begin
          @game.round.active_step(entity)
        rescue ArgumentError
          @game.round.active_step
        rescue NotImplementedError, StandardError
          nil
        end
      end

      def corporate_action_entities
        step = @game.round.active_step
        return [] unless step

        p = active_player
        candidates = if @game.round.stock?
                       (@game.respond_to?(:corporations) ? @game.corporations : []).select do |c|
                         c.respond_to?(:owner) && c.owner && p && c.owner == p
                       end
                     else
                       [
                         current_entity,
                         step&.current_entity,
                         *(@game.respond_to?(:corporations) ? @game.corporations : []),
                       ].compact.uniq
                     end

        candidates.select { |candidate| corporation_or_minor?(candidate) }.map do |candidate|
          candidate_actions = actions_for(candidate)
          player_actions = p ? actions_for(p) : []

          has_shares = false
          if candidate.respond_to?(:corporation?) && candidate.corporation?
            has_shares = (step.respond_to?(:redeemable_shares) && begin; step.redeemable_shares(candidate)&.any?; rescue StandardError; false; end) ||
                         (step.respond_to?(:issuable_shares) && begin; step.issuable_shares(candidate)&.any?; rescue StandardError; false; end)
          end

          relevant_actions =
            (candidate_actions + player_actions) &
            %w[
              issue_shares reissue_shares reissue
              redeem redeem_shares
            ]
          [candidate, candidate_actions] if relevant_actions.any? || has_shares
        end.compact
      end

      def active_player
        entity = current_entity
        return nil unless entity

        if entity.respond_to?(:player?) && entity.player?
          entity
        elsif entity.respond_to?(:player) && entity.player
          entity.player
        elsif entity.respond_to?(:owner) && entity.owner.respond_to?(:player?) && entity.owner.player?
          entity.owner
        end
      end

      def company?(entity)
        return false unless entity

        entity.is_a?(Engine::Company) ||
          (entity.respond_to?(:company?) && entity.company?) ||
          (!entity.respond_to?(:corporation?) && !entity.respond_to?(:minor?) && (entity.respond_to?(:value) || entity.respond_to?(:desc)))
      end

      def corporation_or_minor?(entity)
        return false unless entity

        (entity.respond_to?(:corporation?) && entity.corporation?) ||
          (entity.respond_to?(:minor?) && entity.minor?) ||
          (defined?(Engine::Corporation) && entity.is_a?(Engine::Corporation)) ||
          (defined?(Engine::Minor) && entity.is_a?(Engine::Minor))
      end

      def home_token_step?(step, actions)
        actions.include?('place_token') && (
          step&.class&.name =~ /HomeToken|Home/i ||
          (step.respond_to?(:description) && step.description =~ /Home/i) ||
          (step.respond_to?(:home_token?) && step.home_token?)
        )
      end

      def render_action_row(label, children)
        is_arr = `Array.isArray(#{children})`
        items = (is_arr ? children : [children]).compact
        return nil if items.empty?

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'flex-start',
              gap: '0.4rem',
              width: '100%',
              maxWidth: '100%',
              margin: '0 auto',
            },
          }, [
          h(:span, { style: { fontSize: '0.92rem', fontWeight: 'bold', color: '#333', minWidth: '6.5rem', textAlign: 'left', flexShrink: '0' } }, label),
          h(:div, { style: { display: 'flex', flexDirection: 'row', flexWrap: 'nowrap', alignItems: 'center', gap: '0.3rem', overflowX: 'auto', maxWidth: '100%' } }, items),
        ])
      end

      def render_generic_choice(step, entity)
        return nil unless step && entity

        prompt = if step.respond_to?(:choice_name) && step.choice_name
                   step.choice_name
                 elsif step.respond_to?(:description) && step.description
                   step.description
                 else
                   'Choice:'
                 end

        raw_choices = begin
          if step.respond_to?(:choices_for)
            begin
              step.choices_for(entity)
            rescue ArgumentError
              step.choices_for
            end
          elsif step.respond_to?(:choices)
            begin
              step.choices(entity)
            rescue ArgumentError
              step.choices
            end
          end
        rescue StandardError
          nil
        end

        return nil unless raw_choices && !raw_choices.empty?

        label = prompt.to_s.strip
        label = "#{label}:" unless label.end_with?(':', '?')

        button_style = {
          padding: '0 12px',
          height: '1.65rem',
          fontSize: '0.85rem',
          fontWeight: 'bold',
          backgroundColor: '#f8fafc',
          color: '#0f172a',
          border: '1px solid #cbd5e1',
          borderRadius: '4px',
          cursor: 'pointer',
          boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          lineHeight: '1',
        }

        buttons = if raw_choices.is_a?(Hash)
                    raw_choices.map do |val, text|
                      btn_click = -> { process_action(Engine::Action::Choose.new(entity, choice: val)) }
                      h(:button, {
                          style: button_style,
                          on: { click: btn_click },
                        }, text.to_s)
                    end
                  elsif raw_choices.is_a?(Array)
                    raw_choices.map do |val|
                      btn_click = -> { process_action(Engine::Action::Choose.new(entity, choice: val)) }
                      h(:button, {
                          style: button_style,
                          on: { click: btn_click },
                        }, val.to_s)
                    end
                  else
                    []
                  end

        return nil if buttons.empty?

        render_action_row(label, buttons)
      end

      def render_generic_fallback(step, entity, actions)
        return nil unless step && entity

        if step.respond_to?(:choices) || step.respond_to?(:choices_for)
          choice_node = render_generic_choice(step, entity)
          return choice_node if choice_node
        end

        unhandled = actions - %w[pass undo redo]
        return nil if unhandled.empty?

        desc = if step.respond_to?(:description) && step.description
                 step.description
               else
                 "Pending: #{unhandled.join(', ')}"
               end

        render_action_row('Action Required:', [
          h(:span, { style: { fontSize: '0.88rem', color: '#475569', fontStyle: 'italic' } }, desc),
        ])
      end

      def render_zone3_abilities(entity)
        return nil unless entity

        active_ability_companies = (@game.companies || []).select do |c|
          next false if c.respond_to?(:closed?) && c.closed?

          is_owner = c.owner == entity || (entity.respond_to?(:owner) && c.owner && c.owner == entity.owner)
          next false unless is_owner

          c_actions = begin
            @game.round.actions_for(c)
          rescue StandardError
            []
          end || []

          next false if c_actions.empty?
          next false if @game.respond_to?(:entity_can_use_company?) && !@game.entity_can_use_company?(entity, c)

          true
        end

        return nil if active_ability_companies.empty?

        ability_boxes = active_ability_companies.map do |c|
          card_text = (c.sym || c.name).to_s

          click_handler = lambda {
            c_actions = begin
              @game.round.actions_for(c)
            rescue StandardError
              []
            end || []

            if c_actions.include?('buy_shares') && (ability = @game.abilities(c, :exchange))
              step = @game.round.active_step(c)
              valid_shares = []
              if step.respond_to?(:can_gain?)
                @game.exchange_corporations(ability).each do |corp|
                  ipo_share = corp.shares.find { |s| !s.president }
                  valid_shares << ipo_share if ipo_share && ability.from.include?(:ipo) && step.can_gain?(c.owner, ipo_share, exchange: true)

                  pool_share = @game.share_pool.shares_by_corporation[corp]&.first
                  valid_shares << pool_share if pool_share && ability.from.include?(:market) && step.can_gain?(c.owner, pool_share, exchange: true)

                  reserved = corp.reserved_shares&.first
                  valid_shares << reserved if reserved && ability.from.include?(:reserved) && step.can_gain?(c.owner, reserved, exchange: true)
                end
              end
              if valid_shares.any?
                process_action(Engine::Action::BuyShares.new(c, bundle: valid_shares.first.to_bundle))
                Engine::Action::BuyShares.new(c, shares: valid_shares.first)
                next
              end
            end

            if c_actions.include?('sell_company')
              process_action(Engine::Action::SellCompany.new(entity, company: c, price: c.value))
              next
            end

            if c_actions.include?('purchase_train')
              process_action(Engine::Action::PurchaseTrain.new(c))
              next
            end

            if c_actions.include?('manual_close_company')
              process_action(Engine::Action::ManualCloseCompany.new(c))
              next
            end

            store(:selected_company, c)
            active_a = (c.respond_to?(:all_abilities) ? c.all_abilities : []).dup.concat(c.abilities || []).find do |a|
              !((a.respond_to?(:passive?) && a.passive?) || (a.respond_to?(:passive) && a.passive) || (a.respond_to?(:closed?) && a.closed?) || (a.respond_to?(:used?) && a.used?))
            end

            if active_a && !%i[tile_lay token teleport hex_bonus choose_ability assign_corporation].include?(active_a.type)
              begin
                process_action(Engine::Action::UseAbility.new(c, ability: active_a, company: c))
              rescue StandardError
                begin
                  process_action(Engine::Action::UseAbility.new(entity, ability: active_a, company: c))
                rescue StandardError
                end
              end
            end
          }

          c_hexes = resolve_target_hexes(c)
          wrap_node = render_railcard(
            card_text,
            %w[game-card action-buy clickable],
            click_handler,
            build_company_tooltip(c),
            nil,
            "cmd_company_#{c.id}",
            %w[cmd-company-wrapper status-company-wrapper]
          )
          if c_hexes.any?
            c_hex_names = c_hexes.map do |h|
              if h.respond_to?(:name) && h.name
                h.name.to_s
              else
                (h.respond_to?(:id) && h.id ? h.id.to_s : h.to_s)
              end
            end
            h(:div, {
                style: { display: 'inline-block' },
                on: {
                  mouseenter: lambda {
                    `window.highlightMapHexes && window.highlightMapHexes(#{c_hex_names})`
                    nil
                  },
                  mouseleave: lambda {
                    `window.clearMapHexHighlights && window.clearMapHexHighlights()`
                    nil
                  },
                },
              }, [wrap_node])
          else
            wrap_node
          end
        end

        h(:div, {
            style: {
              width: '100%',
              display: 'flex',
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: '0.4rem',
              height: '1.8rem',
            },
          }, [
          h(:span, { style: { fontSize: '0.92rem', fontWeight: 'bold', color: '#333', flexShrink: '0' } }, 'Abilities:'),
          h(:div, { style: { display: 'flex', flexDirection: 'row', alignItems: 'center', gap: '0.3rem', flexWrap: 'wrap' } }, ability_boxes),
        ])
      end

      def render
        step = @game.round.active_step
        entity = current_entity
        entity_id = entity&.id
        is_move_history_open = @show_move_history == true || Lib::Storage['cmd_move_history_overlay'] == true || Lib::Storage['cmd_move_history_overlay'] == 'true'
        is_history_open = @show_history_overlay == true || Lib::Storage['cmd_history_overlay'] == true || Lib::Storage['cmd_history_overlay'] == 'true'
        preserve_command_panel = is_move_history_open || is_history_open

        if !preserve_command_panel && Lib::Storage['cmd_last_entity_id']&.to_s != entity_id&.to_s
          Lib::Storage['cmd_last_entity_id'] = entity_id
          @routes = []
          store(:routes, @routes, skip: true)
          store(:show_manual_routes, false, skip: true)
        end

        last_action = @game.respond_to?(:raw_actions) && @game.raw_actions ? @game.raw_actions.last : nil
        last_action_id = if last_action.is_a?(Hash)
                           last_action['id'] || last_action[:id] || 0
                         elsif last_action.respond_to?(:id)
                           last_action.id
                         elsif @game_data && @game_data['actions']
                           @game_data['actions'].last&.fetch('id', 0) || 0

                         else
                           0
                         end

        actions = actions_for(entity)

        is_draft = step&.class&.name =~ /Draft/i ||
                   (step.respond_to?(:description) && step.description =~ /Draft/i) ||
                   (@game.respond_to?(:round) && @game.round.class.name =~ /Draft/i)

        is_home_token = home_token_step?(step, actions)

        phase = :waiting
        if actions.include?('lay_tile')
          phase = :build_track
        elsif is_home_token
          phase = :home_token
        elsif actions.include?('place_token')
          phase = :place_token
        elsif actions.include?('run_routes')
          phase = :run_routes
        elsif actions.include?('dividend') || actions.include?('payout') || actions.include?('withhold') || actions.include?('half') || actions.include?('split')
          phase = :dividend
        elsif actions.include?('buy_train')
          phase = :buy_train
        elsif actions.include?('buy_token')
          phase = :buy_token
        elsif actions.include?('issue_shares') || actions.include?('reissue_shares') || actions.include?('reissue')
          phase = :issue_shares
        elsif actions.include?('redeem_shares') || actions.include?('redeem')
          phase = :redeem
        elsif actions.include?('par') && (
          (step&.respond_to?(:corporation_pending_par) && step&.corporation_pending_par) ||
          (step&.respond_to?(:corporation) && step&.corporation) ||
          (step&.respond_to?(:par_corporation) && step&.par_corporation) ||
          (step&.respond_to?(:corporations) && step.corporations&.one?) ||
          (step&.current_entity || current_entity)&.corporation?
        )
          phase = :par
        elsif actions.include?('corporate_buy_shares') || actions.include?('buy_shares')
          phase = :buy_shares
        elsif is_draft
          phase = :choose
        elsif actions.include?('choose')
          phase = :choose
        elsif actions.include?('bid')
          is_acq = @game.round.class.name =~ /Acquisition|Merger/i ||
                   step&.class&.name =~ /Acquire|Acquisition/i ||
                   (step.respond_to?(:description) && step.description =~ /Acquire/i)
          phase = is_acq ? :acquisition : :bid
        elsif actions.include?('assign')
          phase = :assign
        elsif actions.include?('merge') || actions.include?('convert')
          phase = :merge
        elsif actions.include?('take_loan') || actions.include?('payoff_loan')
          phase = :loan
        end

        player_name = entity&.owner&.name || ''

        if entity.respond_to?(:color)
          bg_color = entity.color || '#4169e1'
          text_color = entity.text_color || 'white'
        else
          bg_color = '#333333'
          text_color = 'white'
          player_name = entity&.name || ''
        end

        base_revenue = 0
        if active_routes.any? && !@cmd_router_running
          active_routes.each do |r|
            base_revenue += r.revenue if r.chains.any?
          rescue Engine::GameError, StandardError
          end
        end
        if phase == :dividend && base_revenue.zero? && entity.respond_to?(:operating_history)
          operating = entity.operating_history || {}
          base_revenue = (operating[operating.keys.max]&.revenue || 0).to_i
        end

        storage_key = "rev_override_#{entity&.id}"
        last_base_key = "last_base_rev_#{entity&.id}"
        if Lib::Storage[last_base_key]&.to_i != base_revenue
          Lib::Storage[storage_key] = base_revenue
          Lib::Storage[last_base_key] = base_revenue
        end

        current_revenue = Lib::Storage[storage_key].to_i
        formatted_revenue = @game.respond_to?(:format_revenue_currency) ? @game.format_revenue_currency(current_revenue) : @game.format_currency(current_revenue)

        game_finished = @game.finished
        is_draft_round = is_draft ||
                          (@game.round.class.name =~ /Draft|Auction/i) ||
                          (step&.class&.name =~ /Draft|Auction|Waterfall/i)

        is_stock_round = begin
          @game.round.is_a?(Engine::Round::Stock)
        rescue StandardError
          false
        end ||
                         (@game.round.class.name =~ /Stock/i) ||
                         (@game.round.respond_to?(:stock?) && @game.round.stock?)

        player_display_name = active_player&.name || (entity.respond_to?(:name) ? entity.name : nil) || player_name

        if is_stock_round || is_draft_round || (entity.respond_to?(:player?) && entity.player?)
          zone_1 = h(:div, { style: { flex: '0 0 20%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '0.5rem', borderRight: '1px solid #ccc', boxSizing: 'border-box' } }, [
            h(:div, { style: { fontSize: '1.6rem', fontWeight: 'bold', color: '#000000', textAlign: 'center', wordBreak: 'break-word', lineHeight: '1.2' } }, player_display_name),
          ])
        else
          phase_labels = {
            waiting: 'WAITING',
            build_track: 'LAY TILE',
            home_token: 'CHOOSE HOME',
            place_token: 'PLACE TOKEN',
            buy_token: 'BUY TOKENS',
            run_routes: 'RUN ROUTES',
            dividend: 'DIVIDEND',
            buy_train: 'BUY TRAIN',
            discard_train: 'DISCARD TRAIN',
            issue_shares: 'ISSUE SHARES',
            redeem: 'REDEEM SHARES',
            choose: (is_draft ? 'DRAFT' : 'CHOOSE'),
            bid: 'AUCTION',
            par: 'PAR PRICE',
            merge: 'MERGER',
            loan: 'LOAN',
            buy_shares: 'BUY SHARES',
            assign: 'ASSIGN',
            acquisition: 'ACQUISITION',
          }
          phase_text = phase_labels[phase] || 'ACTION REQUIRED'

          logo_src = begin
            setting_for(:simple_logos, @game) ? entity&.simple_logo : entity&.logo
          rescue StandardError
            nil
          end

          # logo_element = if logo_src
          #                  h(:img, { attrs: { src: logo_src }, style: { width: '75px', height: '75px', objectFit: 'contain', marginRight: '0.75rem', flexShrink: '0' } }, end
          #                else
          logo_element = if logo_src
                           h(:img, { attrs: { src: logo_src }, style: { width: '75px', height: '75px', objectFit: 'contain', marginRight: '0.75rem', flexShrink: '0' } })
                         else
                           h(:div, { style: { width: '75px', height: '75px', fontSize: '1.5rem', fontWeight: 'bold', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: bg_color, color: text_color, borderRadius: '6px', marginRight: '0.75rem', flexShrink: '0' } }, entity&.id || 'N/A')
                         end

          zone_1 = h(:div, { style: { flex: '0 0 22%', display: 'flex', flexDirection: 'row', alignItems: 'center', padding: '0.4rem', borderRight: '1px solid #ccc', boxSizing: 'border-box', overflow: 'hidden' } }, [
            logo_element,
            h(:div, { style: { display: 'flex', flexDirection: 'column', justifyContent: 'center', overflow: 'hidden' } }, [
              h(:div, { style: { fontSize: '1.5rem', fontWeight: 'bold', color: '#000000', lineHeight: '1.2', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } }, player_name),
            ]),
          ])
        end

        show_manual_routes = @show_manual_routes || Lib::Storage['cmd_manual_routes'] == true || Lib::Storage['cmd_manual_routes'] == 'true'
        zone_2_content = []
        if game_finished
          zone_2_content << h(:div, {
                                style: {
                                  width: '100%',
                                  height: '100%',
                                  display: 'flex',
                                  flexDirection: 'row',
                                  alignItems: 'center',
                                  justifyContent: 'center',
                                  gap: '0.75rem',
                                },
                              }, [
            h(:strong, { style: { fontSize: '1rem', color: '#0f172a' } }, 'End of Game'),
            h(:button, {
                style: {
                  height: '1.65rem',
                  padding: '0 12px',
                  fontSize: '0.82rem',
                  fontWeight: 'bold',
                  backgroundColor: '#16a34a',
                  color: '#ffffff',
                  border: 'none',
                  borderRadius: '4px',
                  cursor: 'pointer',
                },
                on: {
                  click: lambda {
                    Lib::Storage['show_results_overlay'] = true
                    update
                  },
                },
              }, 'Show Results'),
            (Lib::Storage['show_results_overlay'] ? h(View::Game::Dashboard::ResultsOverlay, game: @game) : nil),
          ].compact)
        end

        if !game_finished && phase == :run_routes
          if @cmd_router_running
            zone_2_content << h(:div, { style: { padding: '0.2rem', textAlign: 'center', color: '#666', fontStyle: 'italic', fontSize: '0.9rem' } }, '🔄 Computing optimal network tracks...')
          elsif show_manual_routes
            zone_2_content << render_action_row('Revenue:', [
              h(:div, { style: { fontSize: '1.2rem', fontWeight: 'bold', color: COLOR_MONEY, fontFamily: FONT_MONEY, minWidth: '4.5rem', textAlign: 'center', height: '1.8rem', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' } }, formatted_revenue),
              h(:button, {
                  style: {
                    padding: '0 8px',
                    height: '1.8rem',
                    fontSize: '0.8rem',
                    fontWeight: 'bold',
                    backgroundColor: '#64748b',
                    color: '#fff',
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    marginLeft: '0.4rem',
                    display: 'inline-flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                  },
                  on: {
                    click: lambda {
                      if (@routes.nil? || @routes.empty?) && entity
                        @routes = @game.routes_for(entity)
                        store(:routes, @routes)
                      end
                      target_route = @selected_route || @routes&.first
                      store(:selected_route, target_route) if target_route
                      store(:show_manual_routes, true)
                      Lib::Storage['cmd_manual_routes'] = true
                      update
                    },
                  },
                }, 'Close Manual'),
            ])
          else
            spinner_items = [
              h(:button, {
                  style: { width: '1.8rem', height: '1.8rem', fontSize: '1.1rem', fontWeight: 'bold', cursor: 'pointer', backgroundColor: '#e0e0e0', border: '1px solid #999', borderRadius: '4px', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', padding: '0', lineHeight: '1' },
                  on: {
                    click: lambda {
                      Lib::Storage[storage_key] = [current_revenue - 10, 0].max
                      update
                    },
                  },
                }, '-'),
              h(:div, { style: { fontSize: '1.2rem', fontWeight: 'bold', color: COLOR_MONEY, fontFamily: FONT_MONEY, minWidth: '4.5rem', textAlign: 'center', height: '1.8rem', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', lineHeight: '1' } }, formatted_revenue),
              h(:button, {
                  style: { width: '1.8rem', height: '1.8rem', fontSize: '1.1rem', fontWeight: 'bold', cursor: 'pointer', backgroundColor: '#e0e0e0', border: '1px solid #999', borderRadius: '4px', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', padding: '0', lineHeight: '1' },
                  on: {
                    click: lambda {
                      Lib::Storage[storage_key] = current_revenue + 10
                      update
                    },
                  },
                }, '+'),
              h(:button, {
                  style: {
                    padding: '0 8px',
                    height: '1.8rem',
                    fontSize: '0.8rem',
                    fontWeight: 'bold',
                    backgroundColor: '#2563eb',
                    color: '#fff',
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    marginLeft: '0.4rem',
                    display: 'inline-flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    lineHeight: '1',
                  },
                  on: {
                    click: lambda {
                      store(:show_manual_routes, true)
                      Lib::Storage['cmd_manual_routes'] = true
                      update
                    },
                  },
                }, 'Calculate Manually'),
            ]

            zone_2_content << render_action_row('Revenue:', spinner_items)
          end
        elsif phase == :dividend
          raw_options = if step.respond_to?(:dividend_options)
                          step.dividend_options(entity)
                        elsif step.respond_to?(:dividend_types)
                          step.dividend_types
                        else
                          []
                        end
          options = (raw_options.is_a?(Hash) ? raw_options.keys : Array(raw_options)).map(&:to_s)
          half_kind = options.include?('split') ? 'split' : 'half'

          zone_2_content << h(:div, { style: { display: 'flex', flexDirection: 'row', justifyContent: 'center', gap: '0.5rem', width: '100%', maxWidth: '520px', margin: '0 auto' } }, [
            (h(:button, { style: { flex: '1', padding: '0.45rem 0.6rem', fontSize: '1.1rem', fontWeight: 'bold', backgroundColor: '#28a745', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }, on: { click: -> { process_action(Engine::Action::Dividend.new(entity, kind: 'payout', extra_revenue: current_revenue - base_revenue)) } } }, 'Pay Out Full') if actions.include?('payout') || options.include?('payout') || actions.include?('dividend')),
            (h(:button, { style: { flex: '1', padding: '0.45rem 0.6rem', fontSize: '1.1rem', fontWeight: 'bold', backgroundColor: '#007bff', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }, on: { click: -> { process_action(Engine::Action::Dividend.new(entity, kind: 'withhold', extra_revenue: current_revenue - base_revenue)) } } }, 'Hold Revenue') if actions.include?('withhold') || options.include?('withhold') || actions.include?('dividend')),
            (h(:button, { style: { flex: '1', padding: '0.45rem 0.6rem', fontSize: '1.1rem', fontWeight: 'bold', backgroundColor: '#007bff', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }, on: { click: -> { process_action(Engine::Action::Dividend.new(entity, kind: half_kind, extra_revenue: current_revenue - base_revenue)) } } }, 'Split / Half') if actions.include?('half') || actions.include?('split') || options.include?('half') || options.include?('split')),
          ].compact)
        end

        unless game_finished
          ground_truth_actions = begin
            render_ground_truth_actions(actions, step)
          rescue StandardError => e
            `console.error("Dashboard command action rendering failed:", #{e.message})`

            h(
              :div,
              {
                attrs: { class: 'dashboard-command-render-fallback' },
                style: {
                  width: '100%',
                  padding: '0.35rem',
                  color: '#64748b',
                  fontSize: '0.85rem',
                  fontStyle: 'italic',
                },
              },
              'No dashboard action controls available for this step.'
            )
          end

          zone_2_content << ground_truth_actions if ground_truth_actions
        end

        zone_2 = h(:div, { style: { flex: '1 1 56%', display: 'flex', flexDirection: 'column', alignItems: 'flex-start', justifyContent: 'flex-start', gap: '0.25rem', padding: '0.25rem 0.5rem', borderRight: '1px solid #ccc', boxSizing: 'border-box', overflowY: 'auto' } }, zone_2_content.compact)

        advance_text = 'Pass'
        advance_color = '#e0e0e0'
        advance_text_color = '#a0a0a0'
        advance_disabled = true
        advance_action = -> {}

        if actions.include?('pass')
          advance_disabled = false
          advance_color = '#fd7e14'
          advance_text_color = '#fff'
          advance_action = -> { process_action(Engine::Action::Pass.new(entity)) }

          case phase
          when :build_track then advance_text = 'Skip Build'
          when :place_token then advance_text = 'Skip Token'
          when :buy_train then advance_text = 'Done Buying'
          when :issue_shares then advance_text = 'Skip Issue'
          when :redeem then advance_text = 'Skip Redeem'
          when :par then advance_text = 'Skip Par'
          when :merge then advance_text = 'Done / Pass'
          when :loan then advance_text = 'Done / Pass'
          when :buy_shares then advance_text = 'Done / Pass'
          when :choose, :bid, :acquisition then advance_text = is_draft ? 'Pass / Blank' : 'Pass'
          when :assign
            offer_for_sale = begin
              step.respond_to?(:merger_auto_pass_entity) && step.merger_auto_pass_entity
            rescue StandardError
              nil
            end
            if offer_for_sale && step&.class&.name =~ /Acquire|Acquisition/i
              advance_text = 'Pass (Do Not Offer)'
            else
              rem_val = remaining_subsidiary_cost(step, entity)
              advance_text = rem_val && rem_val.positive? ? "OK (Pay #{@game.format_currency(rem_val)})" : 'OK'
              advance_color = '#16a34a'
            end
          end
        elsif phase == :run_routes && actions.include?('run_routes') && !@cmd_router_running
          advance_disabled = false
          advance_color = '#fd7e14'
          advance_text_color = '#fff'
          advance_text = "Submit #{formatted_revenue}"
          advance_action = lambda {
            routes_to_submit = active_routes
            process_action(Engine::Action::RunRoutes.new(
              entity,
              routes: routes_to_submit,
              extra_revenue: @game.extra_revenue(entity, routes_to_submit) + (current_revenue - base_revenue)
            ))
          }
        elsif phase == :dividend
          dividend_options = step.respond_to?(:dividend_options) ? step.dividend_options(entity).map(&:to_s) : []
          if actions.include?('payout') || dividend_options.include?('payout') || actions.include?('dividend')
            advance_disabled = false
            advance_color = '#28a745'
            advance_text_color = '#fff'
            advance_text = 'Pay Out Full'
            advance_action = lambda {
              process_action(Engine::Action::Dividend.new(
                entity,
                kind: 'payout',
                extra_revenue: current_revenue - base_revenue
              ))
            }
          end
        end

        has_abilities = !game_finished && !actions.include?('choose') && entity && (@game.companies || []).any? do |c|
          next false if c.respond_to?(:closed?) && c.closed?

          is_owner = c.owner == entity || (entity.respond_to?(:owner) && c.owner && c.owner == entity.owner)
          next false unless is_owner

          abilities = (c.respond_to?(:all_abilities) ? c.all_abilities : []).dup
          abilities.concat(c.abilities || []) if c.respond_to?(:abilities)

          abilities.any? do |a|
            next false if a.respond_to?(:passive?) && a.passive?
            next false if a.respond_to?(:passive) && a.passive
            next false if a.respond_to?(:closed?) && a.closed?
            next false if a.respond_to?(:used?) && a.used?

            true
          end
        end

        zone_3 = h(:div, { style: { flex: '0 0 22%', display: 'flex', flexDirection: 'column', padding: '0.4rem', boxSizing: 'border-box', overflowY: 'auto', position: 'relative' } }, [
          h(:style, {}, '
            .cmd-company-wrapper:hover .cmd-company-tooltip,
            .status-company-wrapper:hover .status-company-tooltip,
            .cmd-corp-wrapper:hover .cmd-corp-tooltip,
            .status-corp-wrapper:hover .status-corp-tooltip,
            .cmd-company-tooltip,
            .status-company-tooltip,
            .cmd-corp-tooltip,
            .status-corp-tooltip {
              display: none !important;
            }
          '),

          h(:div, { style: { flex: '0 0 auto', width: '100%', marginBottom: '0.3rem' } }, [
            (render_zone3_abilities(entity) if has_abilities),
          ].compact),

          h(:div, { style: { width: '100%', marginTop: 'auto', display: 'flex', flexDirection: 'column', gap: '0.35rem', alignItems: 'center' } }, [
            h(:button, {
                style: {
                  width: '100%',
                  height: '1.45rem',
                  minHeight: '1.45rem',
                  maxHeight: '1.45rem',
                  padding: '0',
                  fontSize: '0.85rem',
                  fontWeight: 'bold',
                  backgroundColor: advance_color,
                  color: advance_text_color,
                  border: 'none',
                  borderRadius: '4px',
                  cursor: advance_disabled ? 'not-allowed' : 'pointer',
                  boxShadow: advance_disabled ? 'none' : '0 1px 3px rgba(0,0,0,0.1)',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  lineHeight: '1',
                },
                attrs: { disabled: advance_disabled },
                on: { click: advance_action },
              }, advance_text),
            h(:div, { style: { width: '100%', display: 'flex', flexDirection: 'row', alignItems: 'center', justifyContent: 'flex-start', gap: '0.35rem' } }, [
              h(:div, { attrs: { class: 'cmd-undo-redo-wrapper' }, style: { flex: '0 0 auto' } }, [
                h(:style, {}, '
                  .cmd-undo-redo-wrapper #history,
                  .cmd-undo-redo-wrapper .history,
                  .cmd-undo-redo-wrapper input,
                  .cmd-undo-redo-wrapper button:not(#undo):not(#redo) {
                    display: none !important;
                  }
                  .cmd-undo-redo-wrapper,
                  .cmd-undo-redo-wrapper * {
                    box-sizing: border-box !important;
                  }
                  .cmd-undo-redo-wrapper,
                  .cmd-undo-redo-wrapper div,
                  .cmd-undo-redo-wrapper #history_and_undo,
                  .cmd-undo-redo-wrapper .history_and_undo {
                    display: flex !important;
                    flex-direction: row !important;
                    flex-wrap: nowrap !important;
                    align-items: center !important;
                    justify-content: flex-start !important;
                    gap: 0.35rem !important;
                    width: auto !important;
                    min-width: auto !important;
                    max-width: max-content !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    border: none !important;
                    background: transparent !important;
                    box-shadow: none !important;
                  }
                  .cmd-undo-redo-wrapper button#undo,
                  .cmd-undo-redo-wrapper button#redo {
                    display: inline-flex !important;
                    flex: 0 0 3.2rem !important;
                    width: 3.2rem !important;
                    min-width: 3.2rem !important;
                    max-width: 3.2rem !important;
                    height: 1.45rem !important;
                    min-height: 1.45rem !important;
                    max-height: 1.45rem !important;
                    justify-content: center !important;
                    align-items: center !important;
                    padding: 0 4px !important;
                    font-size: 0.82rem !important;
                    font-weight: bold !important;
                    background-color: #f8f9fa !important;
                    color: #212529 !important;
                    border: 1px solid #ced4da !important;
                    border-radius: 4px !important;
                    cursor: pointer !important;
                    margin: 0 !important;
                    line-height: 1 !important;
                    box-shadow: 0 1px 2px rgba(0,0,0,0.05) !important;
                  }
                  .cmd-undo-redo-wrapper button#undo:hover:not(:disabled),
                  .cmd-undo-redo-wrapper button#redo:hover:not(:disabled) {
                    background-color: #e9ecef !important;
                    border-color: #adb5bd !important;
                  }
                  .cmd-undo-redo-wrapper button#undo:disabled,
                  .cmd-undo-redo-wrapper button#redo:disabled {
                    background-color: #f1f3f5 !important;
                    color: #adb5bd !important;
                    cursor: not-allowed !important;
                    opacity: 0.6 !important;
                    box-shadow: none !important;
                  }
                '),
                h(HistoryAndUndo, last_action_id: last_action_id),
              ]),
              h(:button, {
                  attrs: { id: 'cmd_move_history_btn', title: 'Open Move History Log' },
                  style: {
                    flex: '0 0 auto',
                    height: '1.45rem',
                    minHeight: '1.45rem',
                    maxHeight: '1.45rem',
                    padding: '0 7px',
                    fontSize: '0.8rem',
                    fontWeight: 'bold',
                    backgroundColor: is_move_history_open ? '#0f172a' : '#f8f9fa',
                    color: is_move_history_open ? '#ffffff' : '#212529',
                    border: is_move_history_open ? '1px solid #0f172a' : '1px solid #ced4da',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    display: 'inline-flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    lineHeight: '1',
                    boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                    margin: '0',
                  },
                  on: {
                    click: lambda {
                      new_val = !is_move_history_open
                      Lib::Storage['cmd_move_history_overlay'] = new_val ? true : nil
                      store(:show_move_history, new_val)
                      update
                    },
                  },
                }, '📜 Moves'),
              h(:button, {
                  attrs: { id: 'cmd_history_nav_btn', title: 'Open Visual History Navigation' },
                  style: {
                    flex: '0 0 auto',
                    height: '1.45rem',
                    minHeight: '1.45rem',
                    maxHeight: '1.45rem',
                    padding: '0 7px',
                    fontSize: '0.8rem',
                    fontWeight: 'bold',
                    backgroundColor: is_history_open ? '#0f172a' : '#f8f9fa',
                    color: is_history_open ? '#ffffff' : '#212529',
                    border: is_history_open ? '1px solid #0f172a' : '1px solid #ced4da',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    display: 'inline-flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    lineHeight: '1',
                    boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                    margin: '0',
                  },
                  on: {
                    click: lambda {
                      new_val = !is_history_open
                      Lib::Storage['cmd_history_overlay'] = new_val ? true : nil
                      store(:show_history_overlay, new_val)
                      update
                    },
                  },
                }, '⏱ Hist'),
            ]),
          ]),
        ])
        current_action_id = @game.respond_to?(:raw_actions) && @game.raw_actions ? @game.raw_actions.size : last_action_id
        routed_token = "#{entity&.id}_#{current_action_id}"

        if phase == :run_routes && @last_routed_action_id != routed_token && !@cmd_router_running
          store(:last_routed_action_id, routed_token, skip: true)
          store(:cmd_router_running, true, skip: false)

          @routes.each(&:reset!) if @routes&.any?
          @game.reset_adjustable_trains!(entity, @routes) if @game.respond_to?(:reset_adjustable_trains!)
          @routes = []
          store(:routes, @routes, skip: true)
          store(:selected_route, nil, skip: true)

          lambda {
            `setTimeout(function() {`
            begin
              flash_cb = lambda do |msg|
                store(:flash_opts, { message: msg }, skip: false)
              end
              router = Engine::AutoRouter.new(@game, flash_cb)
              router_entity = @game.current_entity || entity
              p_timeout = setting_for(:path_timeout).to_i
              p_timeout = 10_000 if p_timeout.zero?
              r_timeout = setting_for(:route_timeout).to_i
              r_timeout = 10_000 if r_timeout.zero?

              router.compute(
                router_entity,
                routes: [],
                path_timeout: p_timeout,
                route_timeout: r_timeout,
                callback: lambda do |computed_routes|
                  routes_list = computed_routes || []
                  store(:routes, routes_list, skip: true)
                  store(:selected_route, routes_list.first, skip: true)

                  auto_rev = 0
                  routes_list.each do |r|
                    auto_rev += r.revenue if r.chains.any?
                  rescue Engine::GameError, StandardError
                  end

                  storage_key = "rev_override_#{entity&.id}"
                  last_base_key = "last_base_rev_#{entity&.id}"
                  Lib::Storage[storage_key] = auto_rev
                  Lib::Storage[last_base_key] = auto_rev

                  store(:cmd_router_running, false)
                  update
                end
              )
            rescue Exception
              store(:cmd_router_running, false)
              update
            end
            `}, 50);`
          }.call
        end

        overlays = []
        overlays << h(View::Game::Dashboard::ManualRouteOverlay, game: @game, entity: entity, routes: @routes, selected_route: @selected_route) if show_manual_routes

        if is_move_history_open
          close_move_hist = lambda {
            Lib::Storage['cmd_move_history_overlay'] = nil
            store(:show_move_history, false)
            update
          }
          overlays << h(View::Game::Dashboard::MoveHistoryOverlay, game: @game, game_data: @game_data, on_close: close_move_hist)
        end

        if is_history_open
          close_hist = lambda {
            Lib::Storage['cmd_history_overlay'] = nil
            store(:show_history_overlay, false)
            update
          }
          overlays << h(View::Game::Dashboard::HistoryOverlay, game: @game, game_data: @game_data, on_close: close_hist)
        end

        # Keep the command bar as the component root. DashboardVisualizer uses direct-child
        # selectors for its three zones; wrapping the bar when an overlay opens causes that
        # selector to hide the entire command panel. Fixed-position overlays can safely be
        # appended as additional children without changing the three-zone structure.
        h(:div, {
            attrs: { id: 'dashboard-command-panel-bar' },
            style: {
              display: 'flex',
              flexDirection: 'row',
              width: '100%',
              height: '100%',
              boxSizing: 'border-box',
              backgroundColor: '#fff',
              position: 'relative',
              zIndex: 99_999,
              overflow: 'visible',
              pointerEvents: 'auto',
            },
          }, [zone_1, zone_2, zone_3, *overlays].compact)
      end

      def render_merger_step(step, entity, actions)
        return nil unless entity && step

        components = []
        top_buttons = []

        if actions.include?('convert')
          top_buttons << h(:button, {
                             style: { padding: '0.3rem 0.6rem', fontSize: '0.9rem', fontWeight: 'bold', backgroundColor: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' },
                             on: { click: -> { process_action(Engine::Action::Convert.new(entity)) } },
                           }, 'Convert')
        end

        show_merge = Lib::Storage['show_merge_candidates'] || !actions.include?('convert')

        if actions.include?('merge')
          top_buttons << h(:button, {
                             style: { padding: '0.3rem 0.6rem', fontSize: '0.9rem', fontWeight: 'bold', backgroundColor: show_merge ? '#16a34a' : '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' },
                             on: {
                               click: lambda {
                                 Lib::Storage['show_merge_candidates'] = true
                                 update
                               },
                             },
                           }, 'Merge')
        end

        if actions.include?('take_loan')
          escaped_id = entity.id.to_s
          loan_amount = @game.respond_to?(:loan_value) ? @game.loan_value(entity) : (@game.loans.first&.amount || 0)
          btn_text = loan_amount.positive? ? "Take Loan (#{@game.format_currency(loan_amount)})" : 'Take Loan'
          click_take = lambda {
            target_selector = "#loan_empty_#{escaped_id}_0, #loans_#{escaped_id}"
            Lib::LoanAnimation.fly('#bank_loan_active', target_selector) do
              process_action(Engine::Action::TakeLoan.new(entity, loan: @game.loans.first))
            end
          }
          top_buttons << h(:button, {
                             style: { padding: '0.3rem 0.6rem', fontSize: '0.9rem', fontWeight: 'bold', fontFamily: loan_amount.positive? ? FONT_MONEY : 'inherit', backgroundColor: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' },
                             on: { click: click_take },
                           }, btn_text)
        end

        if actions.include?('payoff_loan')
          escaped_id = entity.id.to_s
          taken = entity.respond_to?(:loans) && entity.loans ? entity.loans.size : 1
          source_selector = "#loan_dot_#{escaped_id}_#{[taken - 1, 0].max}, #loans_#{escaped_id}"
          loan_to_pay = entity.respond_to?(:loans) && entity.loans ? (entity.loans.last || entity.loans.first) : nil
          click_payoff = lambda {
            Lib::LoanAnimation.fly(source_selector, '#bank_loan_active') do
              process_action(Engine::Action::PayoffLoan.new(entity, loan: loan_to_pay))
            end
          }
          top_buttons << h(:button, {
                             style: { padding: '0.3rem 0.6rem', fontSize: '0.9rem', fontWeight: 'bold', backgroundColor: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' },
                             on: { click: click_payoff },
                           }, 'Payoff Loan')
        end

        components << render_action_row('Action:', top_buttons) if top_buttons.any?

        if actions.include?('merge') && show_merge
          mergeables = if step.respond_to?(:mergeable_candidates)
                         step.mergeable_candidates(entity)
                       elsif step.respond_to?(:mergeable)
                         step.mergeable(entity)
                       elsif step.respond_to?(:mergeable_entities)
                         step.mergeable_entities(entity)
                       else
                         []
                       end

          if mergeables.any?
            merge_boxes = mergeables.map do |target|
              click_handler = lambda {
                kwargs = target.respond_to?(:minor?) && target.minor? ? { minor: target } : { corporation: target }
                process_action(Engine::Action::Merge.new(entity, **kwargs))
              }

              render_major_railcard(
  target,
  click_handler,
  %w[major-railcard action-buy clickable],
  "cmd_merge_target_#{target.id}"
)
            end
            components << h(:div, { style: { fontSize: '0.85rem', fontWeight: 'bold', color: '#333', marginTop: '0.2rem', marginBottom: '0.2rem' } }, "Corporations that can merge with #{entity.name}:")
            components << h(:div, { style: { display: 'flex', flexDirection: 'row', flexWrap: 'wrap', gap: '0.3rem' } }, merge_boxes)
          end
        end

        if actions.include?('buy_shares') || actions.include?('corporate_buy_shares')
          buyable = if step.respond_to?(:buyable_shares)
                      step.buyable_shares(entity)
                    elsif step.respond_to?(:buyable_bundles)
                      step.buyable_bundles(entity)
                    elsif @game.respond_to?(:redeemable_shares)
                      @game.redeemable_shares(entity)
                    else
                      []
                    end

          if buyable.any?
            buy_boxes = buyable.map do |raw_bundle|
              bundle = raw_bundle.respond_to?(:to_bundle) && !raw_bundle.respond_to?(:num_shares) ? raw_bundle.to_bundle : raw_bundle
              num_shares = if bundle.respond_to?(:num_shares)
                             bundle.num_shares
                           else
                             (bundle.respond_to?(:shares) ? bundle.shares.size : 1)
                           end
              pct = bundle.respond_to?(:percent) ? bundle.percent : (num_shares * 10)
              price = if bundle.respond_to?(:price)
                        bundle.price
                      else
                        (bundle.respond_to?(:share_price) ? bundle.share_price.price * num_shares : 0)
                      end

              click_handler = lambda {
                action_class = actions.include?('corporate_buy_shares') ? Engine::Action::CorporateBuyShares : Engine::Action::BuyShares
                process_action(action_class.new(entity, bundle: bundle))
              }
              card = render_railcard("#{pct}%", %w[game-card action-buy clickable], click_handler)
              h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.3rem', margin: '0 0.2rem' } }, [
                card,
                h(:span, { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY, fontWeight: 'bold', fontSize: '0.85rem', whiteSpace: 'nowrap' } }, @game.format_currency(price)),
              ])
            end
            components << render_action_row('Buy Treasury Share:', buy_boxes)
          else
            components << render_action_row('Buy Treasury Share:', [h(:span, { style: { fontStyle: 'italic', color: '#666', fontSize: '0.85rem' } }, 'No shares available')])
          end
        end

        h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.4rem', width: '100%' } }, components)
      end

      def render_par_step(step, entity, corporation)
        return h(:div) unless step && corporation

        par_nodes = if step.respond_to?(:get_par_prices_with_help)
                      step.get_par_prices_with_help(entity, corporation)
                    elsif step.respond_to?(:get_par_prices)
                      step.get_par_prices(entity, corporation)
                    elsif step.respond_to?(:par_prices)
                      begin
                        step.par_prices(entity, corporation)
                      rescue ArgumentError
                        step.par_prices(corporation)
                      end
                    elsif @game.respond_to?(:par_prices)
                      @game.par_prices(corporation)
                    else
                      @game.stock_market.par_prices
                    end

        if @game.respond_to?(:par_chart)
          par_nodes = par_nodes.reject do |node|
            p_obj = node.is_a?(Array) ? node.first : node
            slots = @game.par_chart[p_obj]
            slots && slots.none?(&:nil?)
          end
        end

        corp_badge = render_major_railcard(
    corporation,
    nil,
    ['major-railcard'],
    "cmd_par_corporation_#{corporation.id}"
  )

        buttons = par_nodes.map do |node|
          price = node.is_a?(Array) ? node[0] : node
          help = node.is_a?(Array) ? node[1] : nil
          price_val = price.respond_to?(:price) ? price.price : price

          price_str = @game.format_currency(price_val)
          label = help ? "#{price_str} (#{help})" : price_str

          multiplier = if corporation.respond_to?(:presidents_percent) && corporation.respond_to?(:share_percent)
                         (corporation.presidents_percent / corporation.share_percent).to_i
                       elsif corporation.respond_to?(:shares) && corporation.shares.first&.president
                         corporation.shares.first.num_shares || 2
                       else
                         2
                       end
          cost = price_val * multiplier
          can_afford = (entity.respond_to?(:cash) ? entity.cash : 0) >= cost

          click_handler = lambda {
            slot = (@game.par_chart[price].index(nil) if @game.respond_to?(:par_chart) && @game.par_chart[price])
            args = { corporation: corporation, share_price: price }
            args[:slot] = slot if slot
            process_action(Engine::Action::Par.new(entity, **args))
          }

          h(:button, {
              attrs: { disabled: !can_afford },
              style: {
                height: '1.45rem',
                padding: '0 8px',
                fontSize: '0.82rem',
                fontWeight: 'bold',
                fontFamily: FONT_MONEY,
                backgroundColor: can_afford ? '#f8f9fa' : '#e9ecef',
                color: can_afford ? COLOR_MONEY : '#9ca3af',
                border: can_afford ? "1px solid #{COLOR_MONEY}" : '1px solid #ced4da',
                borderRadius: '4px',
                cursor: can_afford ? 'pointer' : 'not-allowed',
                opacity: can_afford ? '1' : '0.6',
                whiteSpace: 'nowrap',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                boxShadow: can_afford ? '0 1px 2px rgba(0,0,0,0.05)' : 'none',
              },
              on: can_afford ? { click: click_handler } : {},
            }, label)
        end

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'column',
              gap: '0.35rem',
              width: '100%',
              alignItems: 'flex-start',
            },
          }, [
          render_action_row('Select Par Price:', [corp_badge, *buttons]),
        ])
      end

      def render_buyable_companies(step, entity)
        return nil unless entity

        operating_player = if entity.respond_to?(:player?) && entity.player?
                             entity
                           elsif entity.respond_to?(:owner) && entity.owner
                             entity.owner
                           end

        return nil unless operating_player

        buy_company_step = nil
        if @game.round.respond_to?(:steps)
          buy_company_step = @game.round.steps.find do |s|
            s.respond_to?(:buyable_companies) || s.respond_to?(:can_buy_company?)
          end
        end
        buy_company_step ||= step

        all_companies = if buy_company_step.respond_to?(:buyable_companies)
                          buy_company_step.buyable_companies(entity) || []
                        elsif buy_company_step.respond_to?(:can_buy_company?) && @game.respond_to?(:companies)
                          @game.companies.select { |c| buy_company_step.can_buy_company?(entity, c) }
                        else
                          []
                        end

        companies = all_companies.reject { |c| c.respond_to?(:closed?) && c.closed? }.select do |c|
          c.owner && c.owner == operating_player && c.owner != entity
        end

        return nil if companies.empty?

        company_boxes = companies.map do |c|
          owner_name = c.owner&.name || 'Bank'
          next nil if c.owner == entity

          min_price = if buy_company_step.respond_to?(:min_price)
                        buy_company_step.min_price(c)
                      else
                        (c.respond_to?(:min_price) ? c.min_price : 1)
                      end
          max_price = if buy_company_step.respond_to?(:max_price)
                        buy_company_step.max_price(entity, c)
                      elsif c.respond_to?(:max_price)
                        c.max_price
                      else
                        (entity.respond_to?(:cash) ? entity.cash : 0)
                      end

          wrapper_id = "cmd_buy_company_#{c.id}"
          company_click_handler = lambda {
            `var p = document.getElementById('railcard-portal'); if (p) { p.style.display = 'none'; p.innerHTML = ''; }`
            menu_title = "Buy #{c.name} from #{owner_name} (#{min_price}-#{max_price}):"
            default_price = [entity.respond_to?(:cash) ? entity.cash : min_price, max_price].min
            default_price = [default_price, min_price].max

            show_price_dialog(
              menu_title,
              min_price,
              max_price,
              default_price,
              lambda { |price_val|
                source_owner = c.owner

                source_type =
                  if source_owner&.respond_to?(:player?) && source_owner.player?
                    :player
                  elsif source_owner&.respond_to?(:corporation?) && source_owner.corporation?
                    :corporation
                  elsif source_owner&.respond_to?(:minor?) && source_owner.minor?
                    :corporation
                  else
                    :bank
                  end

                remember_card_transfer(
                  kind: :company,
                  item_id: c.id,
                  source_type: source_type,
                  source_id: (source_owner.id if source_owner&.respond_to?(:id))
                )

                process_action(
                  Engine::Action::BuyCompany.new(
                    entity,
                    company: c,
                    price: price_val
                  )
                )
              }
            )
          }

          card_text = (c.sym || c.name).to_s
          tooltip = build_company_tooltip(c)
          wrapper_classes = tooltip ? %w[cmd-company-wrapper status-company-wrapper] : nil

          render_railcard(card_text, %w[game-card action-buy clickable], company_click_handler, tooltip, nil, wrapper_id, wrapper_classes, entity: c)
        end.compact

        return nil if company_boxes.empty?

        render_action_row('Buy Privates:', company_boxes)
      end

      def render_discard_trains(step, entity)
        return nil unless entity && step

        discardable = if step.respond_to?(:discardable_trains)
                        step.discardable_trains(entity)
                      elsif entity.respond_to?(:trains)
                        entity.trains
                      else
                        []
                      end

        train_boxes = (discardable || []).map do |train|
          wrapper_id = "cmd_discard_train_#{train.id}"

          click_handler = lambda {
            remember_card_transfer(
              kind: :train,
              item_id: train.id,
              source_type: :corporation,
              source_id: entity.id,
              variant: train.name
            )

            process_action(
              Engine::Action::DiscardTrain.new(
                entity,
                train: train
              )
            )
          }

          render_railcard(
            train.name,
            %w[game-card action-sell clickable card-train],
            click_handler,
            nil,
            nil,
            wrapper_id
          )
        end

        return nil if train_boxes.empty?

        render_action_row('Discard:', train_boxes)
      end

      def render_loan_actions(_step, entity, actions)
        return nil unless entity && (%w[take_loan payoff_loan] & actions).any?

        buttons = []
        escaped_id = entity.id.to_s

        if actions.include?('take_loan') && @game.respond_to?(:loans) && @game.loans&.any?
          loan_amount = @game.respond_to?(:loan_value) ? @game.loan_value(entity) : (@game.loans.first&.amount || 0)
          btn_text = loan_amount.positive? ? "Take Loan (#{@game.format_currency(loan_amount)})" : 'Take Loan'
          click_take = lambda {
            target_selector = "#loan_empty_#{escaped_id}_0, #loans_#{escaped_id}"
            Lib::LoanAnimation.fly('#bank_loan_active', target_selector) do
              process_action(Engine::Action::TakeLoan.new(entity, loan: @game.loans.first))
            end
          }
          buttons << h(:button, {
                         style: {
                           padding: '0 12px',
                           height: '1.65rem',
                           fontSize: '0.85rem',
                           fontWeight: 'bold',
                           fontFamily: loan_amount.positive? ? FONT_MONEY : 'inherit',
                           backgroundColor: '#dc2626',
                           color: '#fff',
                           border: 'none',
                           borderRadius: '4px',
                           cursor: 'pointer',
                           boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                           display: 'inline-flex',
                           alignItems: 'center',
                           justifyContent: 'center',
                           lineHeight: '1',
                         },
                         on: { click: click_take },
                       }, btn_text)
        end

        if actions.include?('payoff_loan') && entity.respond_to?(:loans) && entity.loans&.any?
          taken = entity.loans.size
          source_selector = "#loan_dot_#{escaped_id}_#{[taken - 1, 0].max}, #loans_#{escaped_id}"
          loan_to_pay = entity.loans.last || entity.loans.first
          click_payoff = lambda {
            Lib::LoanAnimation.fly(source_selector, '#bank_loan_active') do
              process_action(Engine::Action::PayoffLoan.new(entity, loan: loan_to_pay))
            end
          }
          buttons << h(:button, {
                         style: {
                           padding: '0 12px',
                           height: '1.65rem',
                           fontSize: '0.85rem',
                           fontWeight: 'bold',
                           backgroundColor: '#2563eb',
                           color: '#fff',
                           border: 'none',
                           borderRadius: '4px',
                           cursor: 'pointer',
                           boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                           display: 'inline-flex',
                           alignItems: 'center',
                           justifyContent: 'center',
                           lineHeight: '1',
                         },
                         on: { click: click_payoff },
                       }, 'Repay Loan')
        end

        return nil if buttons.empty?

        render_action_row('Loans:', buttons)
      end

      def render_surrender_trains(actions, step, entity)
        return nil unless entity && step

        trains = if step.respond_to?(:scrappable_trains)
                   step.scrappable_trains(entity)
                 elsif step.respond_to?(:surrenderable_trains)
                   step.surrenderable_trains(entity)
                 elsif step.respond_to?(:trains)
                   step.trains(entity)
                 elsif entity.respond_to?(:trains)
                   entity.trains
                 else
                   []
                 end

        action_class = if actions.include?('surrender_train')
                         Engine::Action::SurrenderTrain
                       elsif actions.include?('surrender')
                         Engine::Action::Surrender
                       else
                         Engine::Action::ScrapTrain
                       end

        train_boxes = (trains || []).map do |train|
          click_handler = -> { process_action(action_class.new(entity, train: train)) }

          btn_text = if step.respond_to?(:button_text)
                       step.button_text(train)
                     elsif step.respond_to?(:surrender_button_text)
                       step.surrender_button_text(train)
                     elsif step.respond_to?(:scrap_button_text)
                       step.scrap_button_text(train)
                     end

          cost_str = ''
          if btn_text
            if (m = btn_text.match(/\(([^)]+)\)/))
              cost_str = "(#{m[1]})"
            elsif (m = btn_text.match(/([+-]?\d+\w*)/))
              cost_str = "(#{m[1]})"
            end
          end

          if cost_str.empty?
            cost = nil
            if step.respond_to?(:surrender_cost)
              cost = step.surrender_cost(train)
            elsif step.respond_to?(:cost)
              cost = step.cost(train)
            elsif step.respond_to?(:scrap_cost)
              cost = step.scrap_cost(train)
            elsif @game.respond_to?(:surrender_cost)
              cost = @game.surrender_cost(train)
            elsif @game.respond_to?(:scrap_cost)
              cost = @game.scrap_cost(train)
            end

            cost_str = "(#{@game.format_currency(cost)})" if cost && !cost.zero?
          end

          card = render_railcard(train.name, %w[game-card action-sell clickable card-train], click_handler)
          if cost_str.empty?
            card
          else
            h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.3rem', margin: '0 0.2rem' } }, [
              card,
              h(:span, { style: { fontFamily: FONT_MONEY, color: '#dc2626', fontWeight: 'bold', fontSize: '0.85rem', whiteSpace: 'nowrap' } }, cost_str),
            ])
          end
        end

        return nil if train_boxes.empty?

        render_action_row('Surrender:', train_boxes)
      end

      def render_home_token_step(_step, entity)
        return nil unless entity

        target_hexes = resolve_target_hexes(entity)
        hex_info = target_hexes.any? ? " (#{target_hexes.join(', ')})" : ''

        hover_events = {}
        if target_hexes.any?
          hover_events = {
            mouseenter: lambda {
              `window.highlightMapHexes && window.highlightMapHexes(#{target_hexes})`
              nil
            },
            mouseleave: lambda {
              `window.clearMapHexHighlights && window.clearMapHexHighlights()`
              nil
            },
          }
        end

        instruction = h(:span, {
                          style: {
                            fontSize: '0.88rem',
                            color: '#1e293b',
                            fontWeight: '600',
                            display: 'inline-flex',
                            alignItems: 'center',
                            gap: '0.35rem',
                            cursor: target_hexes.any? ? 'pointer' : 'default',
                          },
                          on: hover_events,
                        }, [
          h(:span, { style: { fontSize: '1rem' } }, '📍'),
          h(:span, "Lay token#{hex_info}"),
        ])

        render_action_row('Home Token:', instruction)
      end

      def render_buy_tokens(step, entity)
        return nil unless entity && step

        tokens = if step.respond_to?(:buyable_tokens)
                   step.buyable_tokens(entity) || []
                 elsif step.respond_to?(:available_tokens)
                   step.available_tokens(entity) || []
                 elsif step.respond_to?(:tokens)
                   step.tokens(entity) || []
                 else
                   []
                 end

        return nil if tokens.empty?

        token_cost_fn = lambda do |num|
          if step.respond_to?(:token_cost)
            begin
              step.token_cost(entity) * num
            rescue ArgumentError
              step.token_cost * num
            end
          elsif step.respond_to?(:price_for_tokens)
            step.price_for_tokens(entity, num)
          elsif tokens.first.respond_to?(:price) && tokens.first.price
            tokens.first.price * num
          else
            0
          end
        end

        buttons = tokens.map.with_index(1) do |token, num|
          price = token_cost_fn.call(num)
          price_str = price.positive? ? @game.format_currency(price) : 'Free'
          can_afford = (entity.respond_to?(:cash) ? entity.cash : 0) >= price

          click_handler = lambda {
            process_action(Engine::Action::BuyToken.new(entity, token: token, price: price))
          }

          card_classes = %w[game-card action-buy]
          card_classes << 'clickable' if can_afford
          card = render_railcard(num.to_s, card_classes, (can_afford ? click_handler : nil))

          h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.3rem', margin: '0 0.2rem' } }, [
            card,
            h(:span, {
                style: {
                  fontFamily: FONT_MONEY,
                  color: can_afford ? COLOR_MONEY : '#9ca3af',
                  fontWeight: 'bold',
                  fontSize: '0.85rem',
                  whiteSpace: 'nowrap',
                },
              }, price_str),
          ])
        end

        render_action_row('Number of Tokens to Buy:', buttons)
      end

      def render_buyable_trains(step, entity)
        return nil unless entity && step

        train_boxes = []
        depot = @game.depot

        step_buyable = (step.buyable_trains(entity) || [] if step.respond_to?(:buyable_trains))

        must_buy = if step.respond_to?(:must_buy_train?)
                     step.must_buy_train?(entity)
                   else
                     entity.respond_to?(:trains) && entity.trains.empty?
                   end

        if depot
          buyable_depot = if step_buyable
                            step_buyable.select do |t|
                              t.owner == depot || t.owner.nil? || t.owner == @game.bank ||
                                (depot.respond_to?(:depot_trains) && depot.depot_trains.include?(t))
                            end
                          else
                            [depot.upcoming.first].compact
                          end
          unique_depot_trains = buyable_depot.uniq { |t| [depot.discarded.include?(t) ? :pool : :bank, t.name] }

          unique_depot_trains.each do |train|
            variants = train.respond_to?(:names_to_prices) && train.names_to_prices && !train.names_to_prices.empty? ? train.names_to_prices : { train.name => train.price }
            is_pool = depot.discarded.include?(train)
            source_tag = is_pool ? 'Pool' : 'Bank'

            variants.each do |variant_name, price|
              can_afford = (entity.respond_to?(:cash) ? entity.cash : 0) >= price || must_buy
              next unless can_afford

              can_buy_step = if step.respond_to?(:can_buy_train?)
                               begin
                                 step.can_buy_train?(entity, train)
                               rescue ArgumentError
                                 begin
                                   step.can_buy_train?(entity)
                                 rescue ArgumentError
                                   step.can_buy_train?
                                 end
                               rescue StandardError
                                 true
                               end
                             else
                               true
                             end
              next unless can_buy_step

              variant_str = variant_name.to_s
              variant_param = (variant_str == train.name.to_s ? nil : variant_str)

              wrapper_id = "cmd_train_#{train.id}_#{variant_str.tr('/', '_')}"
              click_handler = lambda {
                remember_card_transfer(
    kind: :train,
    item_id: train.id,
    source_type: (is_pool ? :train_pool : :train_fresh),
    variant: variant_str
  )

                process_action(
                  Engine::Action::BuyTrain.new(
                    entity,
                    train: train,
                    price: price,
                    variant: variant_param
                  )
                )
              }
              train_classes = %w[game-card action-buy clickable card-train]
              card = render_railcard(variant_str, train_classes, click_handler, nil, nil, wrapper_id)
              price_str = @game.format_currency(price)
              train_boxes << h(:div, { style: { display: 'flex', flexDirection: 'row', alignItems: 'center', gap: '0.4rem' } }, [
                card,
                h(:span, { style: { fontSize: '0.85rem', color: '#475569', fontWeight: 'bold', whiteSpace: 'nowrap' } }, source_tag),
                h(:span, { style: { fontFamily: FONT_MONEY, color: can_afford ? COLOR_MONEY : '#9ca3af', fontWeight: 'bold', fontSize: '0.85rem', whiteSpace: 'nowrap' } }, price_str),
              ])
            end
          end
        end

        corp_owner = lambda do |corp|
          step.respond_to?(:corp_owner) ? step.corp_owner(corp) : corp.owner
        end

        available_other = if step_buyable
                            step_buyable.reject { |t| buyable_depot&.include?(t) }.group_by(&:owner)
                          else
                            {}
                          end
        available_other = available_other.select do |owner, _|
          owner && owner != depot && owner != @game.bank && corp_owner.call(owner) == corp_owner.call(entity)
        end

        available_other.each do |c, trains|
          trains.uniq(&:name).each do |t|
            min_price = 1
            max_price = if step.respond_to?(:max_price)
                          step.max_price(entity, t)
                        else
                          (entity.respond_to?(:cash) ? entity.cash : 9999)
                        end

            wrapper_id = "cmd_other_train_#{c.id}_#{t.id}"

            train_click_handler = lambda {
              `var p = document.getElementById('railcard-portal'); if (p) { p.style.display = 'none'; p.innerHTML = ''; }`

              menu_title = "Buy #{t.name} from #{c.name} (#{min_price}-#{max_price}):"

              show_price_dialog(
                menu_title,
                min_price,
                max_price,
                min_price,
                lambda { |price_val|
                  remember_card_transfer(
                    kind: :train,
                    item_id: t.id,
                    source_type: :corporation,
                    source_id: c.id,
                    variant: t.name
                  )

                  process_action(
                    Engine::Action::BuyTrain.new(
                      entity,
                      train: t,
                      price: price_val
                    )
                  )
                }
              )
            }

            card = render_railcard(t.name, %w[game-card action-buy clickable card-train], train_click_handler, nil, nil, wrapper_id)
            train_boxes << h(:div, { style: { display: 'flex', flexDirection: 'row', alignItems: 'center', gap: '0.4rem' } }, [
   card,
   h(:span, { style: { fontSize: '0.85rem', color: '#475569', fontWeight: 'bold', whiteSpace: 'nowrap' } }, (c.id || c.name).to_s),
 ])
          end
        end

        return nil if train_boxes.empty?

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'row',
              alignItems: 'flex-start',
              justifyContent: 'flex-start',
              gap: '0.4rem',
              width: '100%',
              maxWidth: '100%',
              margin: '0 auto',
            },
          }, [
          h(:span, {
              style: {
                fontSize: '0.92rem',
                fontWeight: 'bold',
                color: '#333',
                minWidth: '6.5rem',
                textAlign: 'left',
                flexShrink: '0',
                height: '1.45rem',
                display: 'inline-flex',
                alignItems: 'center',
              },
            }, 'Buy Train:'),
          h(:div, { style: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: '0.3rem', width: '100%' } }, train_boxes),
        ])
      end

      def render_issue_shares(step, entity)
        entity ||= current_entity
        return nil unless entity && step

        entity_actions = actions_for(entity)
        player_actions = active_player ? actions_for(active_player) : []

        step_actions =
          if step.respond_to?(:current_actions)
            step.current_actions || []
          else
            []
          end

        available_actions =
          (entity_actions + player_actions + step_actions)
            .compact
            .map(&:to_s)
            .uniq

        issuable_bundles = begin
          bundles = if step.respond_to?(:issuable_shares)
                      begin
                        step.issuable_shares(entity)
                      rescue ArgumentError
                        step.issuable_shares
                      end
                    elsif step.respond_to?(:issuable_bundles)
                      begin
                        step.issuable_bundles(entity)
                      rescue ArgumentError
                        step.issuable_bundles
                      end
                    elsif @game.respond_to?(:issuable_shares)
                      @game.issuable_shares(entity)
                    elsif step.respond_to?(:bundles_for_corporation)
                      begin
                        step.bundles_for_corporation(entity, entity)
                      rescue ArgumentError
                        step.bundles_for_corporation(entity)
                      end
                    elsif step.respond_to?(:bundles)
                      step.bundles(entity)
                    else
                      []
                    end || []

          if bundles.empty? && step.respond_to?(:can_sell?)
            t_shares = entity.respond_to?(:shares_of) ? entity.shares_of(entity) : []
            bundles = t_shares.map(&:to_bundle).select { |b| step.can_sell?(entity, b) }
          end
          bundles
        rescue StandardError
          []
        end || []

        rows = []

        can_issue = (
          available_actions &
                  %w[
                    issue_shares
                    reissue_shares
                    reissue
                    corporate_sell_shares
                    sell_shares
                  ]
        ).any?

        if issuable_bundles.any? && can_issue
          issue_buttons = issuable_bundles.map do |raw_bundle|
            bundle =
              if defined?(Engine::ShareBundle) &&
                 raw_bundle.is_a?(Engine::ShareBundle)
                raw_bundle
              elsif raw_bundle.respond_to?(:to_bundle)
                raw_bundle.to_bundle
              else
                Engine::ShareBundle.new(Array(raw_bundle))
              end

            shares = bundle.shares.flatten.compact
            num = bundle.num_shares

            shares =
              if defined?(Engine::ShareBundle) &&
              bundle.is_a?(Engine::ShareBundle)
                bundle.shares
              elsif bundle.respond_to?(:shares)
                bundle.shares
              elsif bundle.is_a?(Array)
                bundle.flat_map do |item|
                  if defined?(Engine::ShareBundle) &&
                  item.is_a?(Engine::ShareBundle)
                    item.shares
                  elsif item.respond_to?(:shares)
                    item.shares
                  else
                    item
                  end
                end
              else
                [bundle]
              end

            shares = shares.flatten.compact

            num =
              if bundle.respond_to?(:num_shares)
                bundle.num_shares
              else
                shares.size
              end

            price =
              if bundle.respond_to?(:price)
                bundle.price
              elsif bundle.respond_to?(:share_price) && bundle.share_price
                bundle.share_price.price * num
              elsif entity.respond_to?(:share_price) && entity.share_price
                entity.share_price.price * num
              else
                0
              end

            share_price =
              if bundle.respond_to?(:share_price) && bundle.share_price
                bundle.share_price
              elsif entity.respond_to?(:share_price)
                entity.share_price
              end

            percent =
              (bundle.percent if bundle.respond_to?(:percent))

            pct_str = percent ? "#{percent}%" : "#{num}S"
            price_str = @game.format_currency(price)

            wrapper_id = "cmd_issue_#{entity.id}_#{num}_#{percent || 'shares'}"

            click_handler = lambda do
              acting_entity =
                if entity.respond_to?(:corporation?) && entity.corporation?
                  entity
                else
                  @game.current_entity || current_entity
                end

              all_actions = (
                actions_for(acting_entity) +
                actions_for(entity) +
                (
                  if step.respond_to?(:current_actions)
                    step.current_actions || []
                  else
                    []
                  end
                )
              ).uniq

              if all_actions.include?('reissue_shares') &&
  defined?(Engine::Action::ReissueShares)
                process_action(
                Engine::Action::ReissueShares.new(
                acting_entity,
                shares: shares
              )
              )
              elsif all_actions.include?('issue_shares') &&
  defined?(Engine::Action::IssueShares)
                process_action(
                Engine::Action::IssueShares.new(
                acting_entity,
                shares: shares
              )
              )
              elsif all_actions.include?('corporate_sell_shares') &&
  defined?(Engine::Action::CorporateSellShares)
                process_action(
                Engine::Action::CorporateSellShares.new(
                acting_entity,
                shares: shares
              )
              )
              else
                process_action(
                Engine::Action::SellShares.new(
                acting_entity,
                shares: shares
              )
              )
              end
            end

            card = render_railcard(
              pct_str,
              %w[game-card action-sell clickable],
              click_handler
            )

            h(
              :div,
              {
                style: {
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: '0.3rem',
                  margin: '0 0.2rem',
                },
              },
              [
                card,
                h(
                  :span,
                  {
                    style: {
                      fontFamily: FONT_MONEY,
                      color: COLOR_MONEY,
                      fontWeight: 'bold',
                      fontSize: '0.85rem',
                      whiteSpace: 'nowrap',
                    },
                  },
                  price_str
                ),
              ]
            )
          end

          corp_tag = @game.round.stock? ? " (#{entity.name})" : ''
          rows << render_action_row("Issue#{corp_tag}:", issue_buttons)

        elsif (
          entity_actions &
          %w[
            issue_shares
            reissue_shares
            reissue
          ]
        ).any?
          rows << render_action_row(
            'Issue:',
            [
              h(
                :span,
                {
                  style: {
                    color: '#888',
                    fontStyle: 'italic',
                    fontSize: '0.85rem',
                  },
                },
                'No issuable shares available'
              ),
            ]
          )
        end

        redeemable_bundles = begin
          bundles = if step.respond_to?(:redeemable_shares)
                      begin
                        step.redeemable_shares(entity)
                      rescue ArgumentError
                        step.redeemable_shares
                      end
                    elsif step.respond_to?(:redeemable_bundles)
                      begin
                        step.redeemable_bundles(entity)
                      rescue ArgumentError
                        step.redeemable_bundles
                      end
                    elsif @game.respond_to?(:redeemable_shares)
                      @game.redeemable_shares(entity)
                    elsif step.respond_to?(:buyable_shares)
                      begin
                        step.buyable_shares(entity)
                      rescue ArgumentError
                        step.buyable_shares
                      end
                    else
                      []
                    end || []

          if bundles.empty? && step.respond_to?(:can_buy?)
            pool_shares = @game.share_pool.shares_by_corporation[entity] || []
            bundles = pool_shares.map(&:to_bundle).select { |b| step.can_buy?(entity, b) }
          end
          bundles
        rescue StandardError
          []
        end || []

        can_redeem = (available_actions & %w[redeem redeem_shares corporate_buy_shares buy_shares]).any?
        if redeemable_bundles.any? && can_redeem
          redeem_buttons = redeemable_bundles.map do |raw_bundle|
            bundle = if raw_bundle.is_a?(Engine::ShareBundle)
                       raw_bundle
                     elsif raw_bundle.respond_to?(:to_bundle)
                       raw_bundle.to_bundle
                     else
                       Engine::ShareBundle.new(Array(raw_bundle))
                     end
            num = if bundle.respond_to?(:num_shares)
                    bundle.num_shares
                  else
                    (bundle.respond_to?(:shares) ? bundle.shares.size : 1)
                  end
            pct_str = bundle.respond_to?(:percent) && bundle.percent ? "#{bundle.percent}%" : "#{num}S"
            price = if bundle.respond_to?(:price)
                      bundle.price
                    elsif bundle.respond_to?(:share_price) && bundle.share_price
                      bundle.share_price.price * num
                    elsif entity.respond_to?(:share_price) && entity.share_price
                      entity.share_price.price * num
                    else
                      0
                    end

            share_price = if bundle.respond_to?(:share_price) && bundle.share_price
                            bundle.share_price
                          elsif entity.respond_to?(:share_price)
                            entity.share_price
                          end

            percent = (bundle.percent if bundle.respond_to?(:percent))

            owner_label = if bundle.respond_to?(:owner) && bundle.owner && bundle.owner != @game.share_pool
                            " (#{bundle.owner.name})"
                          else
                            ''
                          end
            price_str = "#{@game.format_currency(price)}#{owner_label}"
            can_afford = (entity.respond_to?(:cash) ? entity.cash : 0) >= price

            click_handler = lambda {
              acting_entity = entity.respond_to?(:corporation?) && entity.corporation? ? entity : (@game.current_entity || current_entity)
              all_actions = (actions_for(acting_entity) + actions_for(entity) + (step.respond_to?(:current_actions) ? (step.current_actions || []) : [])).uniq

              action_kwargs = {
                shares: bundle.shares,
                share_price: share_price,
                percent: percent,
              }.compact

              if all_actions.include?('redeem_shares') && defined?(Engine::Action::RedeemShares)
                process_action(Engine::Action::RedeemShares.new(acting_entity, **action_kwargs))
              elsif all_actions.include?('redeem') && defined?(Engine::Action::Redeem)
                process_action(Engine::Action::Redeem.new(acting_entity, **action_kwargs))
              elsif all_actions.include?('corporate_buy_shares') && defined?(Engine::Action::CorporateBuyShares)
                process_action(Engine::Action::CorporateBuyShares.new(acting_entity, **action_kwargs))
              else
                process_action(Engine::Action::BuyShares.new(acting_entity, **action_kwargs))
              end
            }

            card_classes = %w[game-card action-buy]
            card_classes << 'clickable' if can_afford
            card = render_railcard(pct_str, card_classes, (can_afford ? click_handler : nil))
            h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.3rem', margin: '0 0.2rem' } }, [
              card,
              h(:span, { style: { fontFamily: FONT_MONEY, color: can_afford ? COLOR_MONEY : '#9ca3af', fontWeight: 'bold', fontSize: '0.85rem', whiteSpace: 'nowrap' } }, price_str),
            ])
          end

          corp_tag = @game.round.stock? ? " (#{entity.name})" : ''
          rows << render_action_row("Redeem#{corp_tag}:", redeem_buttons)
        elsif (entity_actions & %w[redeem redeem_shares]).any?
          rows << render_action_row('Redeem:', [
            h(:span, { style: { color: '#888', fontStyle: 'italic', fontSize: '0.85rem' } }, 'No redeemable shares available'),
          ])
        end

        return nil if rows.empty?

        h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.25rem', width: '100%' } }, rows.compact)
      end

      def render_stock_bidding(step, entity, actions)
        return nil unless actions.include?('bid') && entity

        auction_corp = step.respond_to?(:auctioning) ? step.auctioning : nil
        selected_id = Lib::Storage['selected_bid_corp']
        selected_corp = @game.corporations.find { |c| c.id.to_s == selected_id.to_s } if selected_id
        corporation = auction_corp || selected_corp
        return nil unless corporation

        min_bid = if step.respond_to?(:min_bid)
                    begin
                      step.min_bid(corporation)
                    rescue ArgumentError
                      step.min_bid
                    rescue StandardError
                      100
                    end
                  else
                    100
                  end
        min_bid = min_bid.to_i
        min_bid = 100 if min_bid < 100 && !auction_corp
        min_bid = min_bid.to_i

        max_bid = if step.respond_to?(:max_bid)
                    begin
                      step.max_bid(entity)
                    rescue ArgumentError, StandardError
                      entity.respond_to?(:cash) ? entity.cash.to_i : 400
                    end
                  else
                    entity.respond_to?(:cash) ? entity.cash.to_i : 400
                  end
        max_bid = [max_bid.to_i, 400].min unless auction_corp
        max_bid = min_bid if max_bid < min_bid

        price_key = "bid_price_#{corporation.id}"
        stored_price = Lib::Storage[price_key]
        current_bid = stored_price.nil? ? min_bid : stored_price.to_i
        current_bid = [[current_bid, min_bid].max, max_bid].min
        current_bid = current_bid.to_i
        current_bid = max_bid if current_bid > max_bid

        set_price = lambda do |value|
          value = value.to_i
          value = min_bid if value < min_bid
          value = max_bid if value > max_bid
          # Preserve the exact engine value. The buttons alter it by exactly five.
          Lib::Storage[price_key] = value
          update
        end

        place_bid = lambda do
          price = current_bid.to_i
          next unless price >= min_bid && price <= max_bid && (price % 5).zero?

          action = Engine::Action::Bid.new(entity, corporation: corporation, price: price)
          Lib::Storage['selected_bid_corp'] = nil unless auction_corp
          Lib::Storage[price_key] = nil
          process_action(action)
        end

        cancel = lambda do
          Lib::Storage['selected_bid_corp'] = nil
          Lib::Storage[price_key] = nil
          update
        end

        button_style = {
          height: '1.65rem',
          padding: '0 9px',
          fontSize: '0.82rem',
          fontWeight: 'bold',
          border: '1px solid #cbd5e1',
          borderRadius: '4px',
          backgroundColor: '#ffffff',
          color: '#0f172a',
          cursor: 'pointer',
        }
        minus_disabled = current_bid <= min_bid
        plus_disabled = current_bid + 5 > max_bid
        minus = h(:button, {
                    attrs: { disabled: minus_disabled },
                    style: button_style.merge(cursor: minus_disabled ? 'not-allowed' : 'pointer', color: minus_disabled ? '#94a3b8' : '#0f172a'),
                    on: minus_disabled ? {} : { click: -> { set_price.call(current_bid - 5) } },
                  }, '-5')
        plus = h(:button, {
                   attrs: { disabled: plus_disabled },
                   style: button_style.merge(cursor: plus_disabled ? 'not-allowed' : 'pointer', color: plus_disabled ? '#94a3b8' : '#0f172a'),
                   on: plus_disabled ? {} : { click: -> { set_price.call(current_bid + 5) } },
                 }, '+5')
        price = h(:span, {
                    style: { minWidth: '4.4rem', textAlign: 'center', fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '1rem', fontWeight: 'bold' },
                  }, @game.format_currency(current_bid))
        submit = h(:button, {
                     style: button_style.merge(backgroundColor: '#16a34a', color: '#ffffff', border: 'none'),
                     on: { click: place_bid },
                   }, auction_corp ? 'Raise Bid' : 'Place Bid')

        card = render_major_railcard(
          corporation,
          nil,
          ['major-railcard'],
          "cmd_stock_bid_#{corporation.id}"
        )

        children = [card, minus, price, plus, submit]
        unless auction_corp
          children << h(:button, {
                          style: button_style.merge(backgroundColor: '#f1f5f9', color: '#64748b'),
                          on: { click: cancel },
                        }, 'Cancel')
        end
        render_action_row(auction_corp ? 'Auction:' : 'Opening Bid:', children)
      end

      def render_offer_for_sale_step(step, entity, actions)
        return nil unless step && entity && actions.include?('assign')

        offer = begin
          step.merger_auto_pass_entity if step.respond_to?(:merger_auto_pass_entity)
        rescue StandardError
          nil
        end
        return nil unless offer && offer.respond_to?(:corporation?) && offer.corporation?

        offer_card = render_major_railcard(
          offer,
          -> { process_action(Engine::Action::Assign.new(entity, target: offer)) },
          %w[major-railcard action-buy clickable],
          "cmd_offer_for_sale_#{offer.id}"
        )

        instruction = h(:span, {
                          style: {
                            color: '#334155',
                            fontSize: '0.86rem',
                            lineHeight: '1.25',
                            whiteSpace: 'normal',
                          },
                        }, "Choose whether to place #{offer.name} into the acquisition auction.")

        offer_button = h(:button, {
                           style: {
                             height: '1.65rem',
                             padding: '0 12px',
                             fontSize: '0.85rem',
                             fontWeight: 'bold',
                             backgroundColor: '#16a34a',
                             color: '#ffffff',
                             border: 'none',
                             borderRadius: '4px',
                             cursor: 'pointer',
                             boxShadow: '0 1px 2px rgba(0,0,0,0.12)',
                             whiteSpace: 'nowrap',
                           },
                           on: {
                             click: -> { process_action(Engine::Action::Assign.new(entity, target: offer)) },
                           },
                         }, 'Offer for Sale')

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'column',
              gap: '0.35rem',
              width: '100%',
              alignItems: 'flex-start',
            },
          }, [
            render_action_row('Corporation:', [offer_card, instruction]),
            render_action_row('Decision:', [offer_button]),
          ])
      end

      def remember_card_transfer(kind:, item_id:, source_type:, source_id: nil, variant: nil)
        transfer = {
          kind: kind.to_s,
          item_id: item_id.to_s,
          source_type: source_type.to_s,
          source_id: source_id&.to_s,
          variant: variant&.to_s,
        }

        %x{
    if (typeof window !== 'undefined') {
      window._railcard_pending_transfer = #{transfer};
    }
  }
      end

      def remaining_subsidiary_cost(step, entity)
        return nil unless step

        %i[remaining remaining_cash remaining_cost needed_cash cash_owed cash_needed cost amount].each do |m|
          next unless step.respond_to?(m)

          val = begin
            step.send(m)
          rescue ArgumentError
            begin; step.send(m, entity); rescue StandardError; nil; end
          rescue StandardError
            nil
          end
          return val.to_i if val&.is_a?(Numeric)
        end

        if step.respond_to?(:winning_bid) && step.winning_bid
          wb = step.winning_bid
          bid_val = wb.respond_to?(:price) ? wb.price : wb.to_i
          corp = step.respond_to?(:corporation) ? step.corporation : nil
          assigned_val = corp&.companies ? corp.companies.sum { |c| c.value || 0 } : 0
          return [bid_val - assigned_val, 0].max
        end

        nil
      end

      def render_assign_step(step, entity, actions)
        player = if entity.respond_to?(:player?) && entity.player?
                   entity
                 elsif entity.respond_to?(:owner) && entity.owner&.player?
                   entity.owner
                 else
                   active_player || entity
                 end
        return nil unless player

        assignable = if step.respond_to?(:companies)
                       begin; step.companies(player); rescue ArgumentError; step.companies; rescue StandardError; nil; end
                     elsif step.respond_to?(:assignable_companies)
                       begin; step.assignable_companies(player); rescue ArgumentError; step.assignable_companies; rescue StandardError; nil; end
                     elsif step.respond_to?(:available_companies)
                       begin; step.available_companies(player); rescue ArgumentError; step.available_companies; rescue StandardError; nil; end
                     end
        assignable ||= (player.respond_to?(:companies) ? player.companies : [])
        assignable = (assignable || []).reject { |c| c.respond_to?(:closed?) && c.closed? }

        remaining_cost = remaining_subsidiary_cost(step, player)

        items = []
        if remaining_cost
          items << h(:div, {
                       style: {
                         display: 'inline-flex',
                         alignItems: 'center',
                         gap: '0.3rem',
                         padding: '0 8px',
                         height: '1.65rem',
                         backgroundColor: '#f1f5f9',
                         border: '1px solid #cbd5e1',
                         borderRadius: '4px',
                         fontSize: '0.82rem',
                         fontWeight: 'bold',
                         color: '#334155',
                         whiteSpace: 'nowrap',
                       },
                     }, [
            h(:span, 'Cash Due:'),
            h(:span, { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '0.95rem' } }, @game.format_currency(remaining_cost)),
          ])
        end

        assignable.each do |c|
          c_val = c.respond_to?(:value) ? c.value : 0
          click_handler = -> { process_action(Engine::Action::Assign.new(player, target: c)) }
          card_text = (c.sym || c.name).to_s
          tooltip = build_company_tooltip(c)
          wrapper_classes = tooltip ? %w[cmd-company-wrapper status-company-wrapper] : nil

          card = render_railcard(
            card_text,
            %w[game-card action-buy clickable],
            click_handler,
            tooltip,
            nil,
            "cmd_assign_company_#{c.id}",
            wrapper_classes,
            entity: c
          )

          items << h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.3rem', margin: '0 0.2rem' } }, [
            card,
            h(:span, {
                style: {
                  fontFamily: FONT_MONEY,
                  color: COLOR_MONEY,
                  fontWeight: 'bold',
                  fontSize: '0.85rem',
                  whiteSpace: 'nowrap',
                },
              }, @game.format_currency(c_val)),
          ])
        end

        if assignable.empty?
          items << h(:span, { style: { fontStyle: 'italic', color: '#64748b', fontSize: '0.85rem' } }, 'No privates available to assign')
        end

        if actions.include?('pass')
          ok_text = remaining_cost && remaining_cost.positive? ? "OK (Pay #{@game.format_currency(remaining_cost)} Cash)" : 'OK (Done)'
          items << h(:button, {
                       style: {
                         padding: '0 12px',
                         height: '1.65rem',
                         fontSize: '0.82rem',
                         fontWeight: 'bold',
                         backgroundColor: '#16a34a',
                         color: '#ffffff',
                         border: 'none',
                         borderRadius: '4px',
                         cursor: 'pointer',
                         boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                         display: 'inline-flex',
                         alignItems: 'center',
                         justifyContent: 'center',
                         lineHeight: '1',
                         marginLeft: '0.4rem',
                         whiteSpace: 'nowrap',
                       },
                       on: { click: -> { process_action(Engine::Action::Pass.new(player)) } },
                     }, ok_text)
        end

        label = (step.respond_to?(:description) && step.description) || 'Assign Privates'
        label = "#{label}:" unless label.end_with?(':')

        render_action_row(label, items)
      end

      def render_acquisition_step(step, entity, actions)
        return nil unless step && entity && actions.include?('bid')

        target = nil
        %i[target auctioning corporation target_corporation acquired_corp offered_corporation].each do |m|
          next unless step.respond_to?(m)

          val = begin; step.send(m); rescue StandardError; nil; end
          if val && (val.is_a?(Engine::Corporation) || (val.respond_to?(:corporation?) && val.corporation?))
            target = val
            break
          end
        end

        if !target && step.respond_to?(:targets)
          t_list = begin; step.targets; rescue StandardError; []; end
          target = t_list&.first
        end

        if !target && step.respond_to?(:corporations)
          c_list = begin; step.corporations; rescue StandardError; []; end
          target = c_list.find { |c| (c.respond_to?(:receivership?) && c.receivership?) || (c.share_price && c.share_price.price.zero?) } || c_list.first
        end

        return nil unless target

        potential_buyers = []
        %i[potential_buyers eligible_buyers buyers purchasers bidders mergeable_candidates mergeable].each do |m|
          next unless step.respond_to?(m)

          val = begin
            step.send(m, target)
          rescue ArgumentError
            begin; step.send(m); rescue StandardError; nil; end
          rescue StandardError
            nil
          end
          if val.is_a?(Array) && val.any?
            potential_buyers = val.reject { |b| b == target }
            break if potential_buyers.any?
          end
        end

        if potential_buyers.empty? && step.respond_to?(:entities)
          ents = begin; step.entities; rescue StandardError; []; end
          potential_buyers = ents.select { |e| e.respond_to?(:corporation?) && e.corporation? && e != target }
        end

        if potential_buyers.empty? && step.respond_to?(:corporations)
          corps = begin; step.corporations; rescue StandardError; []; end
          potential_buyers = corps.select { |c| c != target }
        end

        if potential_buyers.empty?
          all_corps = @game.respond_to?(:corporations) ? @game.corporations : []
          potential_buyers = all_corps.select do |c|
            next false if c == target
            next false if c.respond_to?(:closed?) && c.closed?

            actions_for(c).include?('bid')
          end
        end

        potential_buyers = potential_buyers.uniq

        p = active_player || (entity.respond_to?(:player?) && entity.player? ? entity : entity&.owner)
        player_buyers = potential_buyers.select { |b| b.owner == p }

        selected_buyer_id = Lib::Storage["acq_buyer_#{target.id}"]
        selected_buyer = player_buyers.find { |b| b.id.to_s == selected_buyer_id.to_s } || player_buyers.first || potential_buyers.first

        is_corp_buyer = selected_buyer && selected_buyer.respond_to?(:corporation?) && selected_buyer.corporation? && selected_buyer != target

        min_bid = if step.respond_to?(:min_bid)
                    begin
                      step.min_bid(target)
                    rescue ArgumentError
                      step.min_bid
                    rescue StandardError
                      10
                    end
                  else
                    10
                  end
        min_bid = min_bid.to_i

        max_bid = if is_corp_buyer && step.respond_to?(:max_bid)
                    begin
                      step.max_bid(p, selected_buyer)
                    rescue ArgumentError
                      begin; step.max_bid(selected_buyer); rescue StandardError; nil; end
                    rescue StandardError
                      nil
                    end
                  elsif step.respond_to?(:max_bid)
                    begin
                      step.max_bid(p || entity, target)
                    rescue ArgumentError
                      begin; step.max_bid(p || entity); rescue StandardError; nil; end
                    rescue StandardError
                      nil
                    end
                  end

        max_bid ||= if is_corp_buyer
                      selected_buyer.cash
                    elsif p&.respond_to?(:cash)
                      p.cash
                    else
                      (entity.respond_to?(:cash) ? entity.cash : 1000)
                    end

        max_bid = [max_bid.to_i, min_bid].max

        inc = if step.respond_to?(:min_increment)
                begin; step.min_increment; rescue StandardError; 10; end
              elsif step.respond_to?(:increment)
                begin; step.increment; rescue StandardError; 10; end
              else
                10
              end
        inc = 10 if inc.nil? || inc.to_i <= 0
        inc = inc.to_i

        price_key = "acq_bid_price_#{target.id}"
        stored_price = Lib::Storage[price_key]
        current_bid = stored_price.nil? ? min_bid : stored_price.to_i
        current_bid = [[current_bid, min_bid].max, max_bid].min
        current_bid = current_bid.to_i

        set_price = lambda do |val|
          val = val.to_i
          val = min_bid if val < min_bid
          val = max_bid if val > max_bid
          Lib::Storage[price_key] = val
          update
        end

        place_bid = lambda do
          price = current_bid.to_i
          next unless price >= min_bid && price <= max_bid

          # In 1817 Acquire the Bid action is always made by the active player
          # against the corporation being auctioned. The potential buyer is selected
          # only after the auction is won (via the subsequent Merge/Acquire action).
          # Sending selected_buyer here makes the engine treat that buyer as the
          # auctioned corporation and validate the bid against the wrong object.
          action = Engine::Action::Bid.new(p || entity, corporation: target, price: price)
          Lib::Storage[price_key] = nil
          process_action(action)
        end

        button_style = {
          height: '1.65rem',
          padding: '0 9px',
          fontSize: '0.82rem',
          fontWeight: 'bold',
          border: '1px solid #cbd5e1',
          borderRadius: '4px',
          backgroundColor: '#ffffff',
          color: '#0f172a',
          cursor: 'pointer',
        }

        minus_disabled = current_bid <= min_bid
        plus_disabled = current_bid + inc > max_bid

        minus_btn = h(:button, {
                        attrs: { disabled: minus_disabled },
                        style: button_style.merge(cursor: minus_disabled ? 'not-allowed' : 'pointer', color: minus_disabled ? '#94a3b8' : '#0f172a'),
                        on: minus_disabled ? {} : { click: -> { set_price.call(current_bid - inc) } },
                      }, "-#{inc}")

        plus_btn = h(:button, {
                       attrs: { disabled: plus_disabled },
                       style: button_style.merge(cursor: plus_disabled ? 'not-allowed' : 'pointer', color: plus_disabled ? '#94a3b8' : '#0f172a'),
                       on: plus_disabled ? {} : { click: -> { set_price.call(current_bid + inc) } },
                     }, "+#{inc}")

        price_display = h(:span, {
                            style: { minWidth: '4.4rem', textAlign: 'center', fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '1rem', fontWeight: 'bold' },
                          }, @game.format_currency(current_bid))

        submit_btn = h(:button, {
                         style: button_style.merge(backgroundColor: '#16a34a', color: '#ffffff', border: 'none'),
                         on: { click: place_bid },
                       }, 'Place Bid')

        target_badge = render_major_railcard(
    target,
    nil,
    ['major-railcard'],
    "cmd_acquisition_target_#{target.id}"
  )

        row1 = render_action_row('Company for sale:', [
          target_badge,
          minus_btn,
          price_display,
          plus_btn,
          submit_btn,
        ])

        buyer_badges = if potential_buyers.any?
                         potential_buyers.map do |b|
                           is_selected = (b == selected_buyer)
                           card_classes = %w[game-card]

                           is_clickable = player_buyers.size > 1 && player_buyers.include?(b)

                           if is_clickable
                             card_classes << 'action-buy' if is_selected
                             card_classes << 'clickable'
                           end

                           click_cb = if is_clickable
                                        lambda {
                                          Lib::Storage["acq_buyer_#{target.id}"] = b.id
                                          update
                                        }
                                      end

                           badge_wrapper = render_major_railcard(
                           b,
                           click_cb,
                           card_classes.map { |cls| cls == 'game-card' ? 'major-railcard' : cls },
                           "cmd_acquisition_buyer_#{b.id}"
                         )

                           b_cash = b.respond_to?(:cash) ? @game.format_currency(b.cash) : ''
                           h(:div, { style: { display: 'inline-flex', alignItems: 'center', gap: '0.25rem', margin: '0 0.2rem' } }, [
                             badge_wrapper,
                             (h(:span, { style: { fontFamily: FONT_MONEY, color: COLOR_MONEY, fontSize: '0.82rem', fontWeight: 'bold' } }, b_cash) unless b_cash.empty?),
                           ].compact)
                         end
                       else
                         [h(:span, { style: { fontStyle: 'italic', color: '#64748b', fontSize: '0.85rem' } }, 'None')]
                       end

        row2 = render_action_row('Potential buyers:', buyer_badges)

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'column',
              gap: '0.35rem',
              width: '100%',
              alignItems: 'flex-start',
            },
          }, [row1, row2].compact)
      end

      def render_ground_truth_actions(actions, step)
        return h(:div) if @game.finished

        return h(UpgradeOrDiscardTrains) if actions.include?('discard_train') && actions.include?('swap_train')

        is_acquisition = actions.include?('bid') && (
          @game.round.class.name =~ /Acquisition|Merger/i ||
          step&.class&.name =~ /Acquire|Acquisition/i ||
          (step.respond_to?(:description) && step.description =~ /Acquire/i)
        )
        if actions.include?('assign') && step&.class&.name =~ /Acquire|Acquisition/i
          offer_node = render_offer_for_sale_step(step, step&.current_entity || current_entity, actions)
          return offer_node if offer_node
        end
        if is_acquisition
          acq_node = render_acquisition_step(step, step&.current_entity || current_entity, actions)
          return acq_node if acq_node
        end

        if actions.include?('par')
          pending_corp = if step&.respond_to?(:corporation_pending_par) && step&.corporation_pending_par
                           step.corporation_pending_par
                         elsif step&.respond_to?(:corporation) && step&.corporation
                           step.corporation
                         elsif step&.respond_to?(:par_corporation) && step&.par_corporation
                           step.par_corporation
                         elsif step&.respond_to?(:parring) && step&.parring
                           step.parring
                         elsif step&.respond_to?(:corporations) && step.corporations&.one?
                           step.corporations.first
                         elsif corporation_or_minor?(step&.current_entity || current_entity)
                           step&.current_entity || current_entity
                         end

          unless pending_corp
            transacted_company = nil
            %i[company last_company auctioning].each do |m|
              if step&.respond_to?(m) && (val = step.send(m))
                transacted_company = val if val.respond_to?(:abilities) || val.is_a?(Engine::Company)
                break if transacted_company
              end
            end

            if transacted_company
              shares_ability = begin
                transacted_company.abilities(:shares)
              rescue StandardError
                nil
              end
              if shares_ability&.respond_to?(:shares)
                share = begin
                  shares_ability.shares.first
                rescue StandardError
                  nil
                end
                pending_corp = share.corporation if share&.respond_to?(:corporation)
              end
            end

            unless pending_corp
              actor = step&.current_entity || current_entity
              player_actor = actor.respond_to?(:player?) && actor.player? ? actor : actor&.owner
              if player_actor&.respond_to?(:companies)
                player_actor.companies.each do |c|
                  shares_ability = begin
                    c.abilities(:shares)
                  rescue StandardError
                    nil
                  end
                  next unless shares_ability&.respond_to?(:shares)

                  share = begin
                    shares_ability.shares.first
                  rescue StandardError
                    nil
                  end
                  corp = share.corporation if share&.respond_to?(:corporation)
                  if corp && !corp.ipoed
                    pending_corp = corp
                    break
                  end
                end
              end
            end
          end

          return render_par_step(step, step&.current_entity || current_entity, pending_corp) if pending_corp
        end

        is_draft_or_auction = (step&.respond_to?(:auctioning) && step&.auctioning) ||
                              (!actions.include?('par') && (
                                (step&.class&.name =~ /Waterfall|Draft|Auction|Initial/i) ||
                                (step&.respond_to?(:description) && step.description =~ /Draft|Auction/i) ||
                                (@game.respond_to?(:round) && @game.round.class.name =~ /Draft|Auction/i)
                              ))

        case @game.round
        when Engine::Round::Stock
          if actions.include?('assign')
            render_assign_step(step, step&.current_entity || current_entity, actions)
          elsif is_draft_or_auction
            h(View::Game::Dashboard::DraftOverlay, game: @game)
          elsif actions.include?('choose')
            render_generic_choice(step, step&.current_entity || current_entity)
          else
            stock_components = []
            if actions.include?('bid')
              bidding_row = render_stock_bidding(step, step&.current_entity || current_entity, actions)
              stock_components << bidding_row if bidding_row
            end
            corporate_action_entities.each do |action_entity, _entity_actions|
              action_step = active_step_for(action_entity) || step
              stock_components << render_issue_shares(action_step, action_entity)
            end
            h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%' } }, stock_components.compact)
          end
        when Engine::Round::Operating
          is_pure_merger_step = step.class.name =~ /Merge/i ||
                                 (actions.include?('merge') && (actions & %w[lay_tile place_token run_routes dividend buy_train]).empty?)

          if is_pure_merger_step
            h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, [render_merger_step(step, step&.current_entity || current_entity, actions)].compact)
          elsif is_draft_or_auction
            h(View::Game::Dashboard::DraftOverlay, game: @game)
          else
            components = []
            convert_track = step&.respond_to?(:conversion?) && step&.conversion?
            loans_rendered = false

            if actions.include?('choose')
              choice_item = render_generic_choice(step, step&.current_entity || current_entity)
              components << choice_item if choice_item
            end

            if actions.include?('assign')
              assign_item = render_assign_step(step, step&.current_entity || current_entity, actions)
              components << assign_item if assign_item
            end

            components << h(SpecialBuy) if actions.include?('special_buy')
            components << h(TrackConversion) if actions.include?('run_routes') && convert_track
            components << h(Convert) if actions.include?('convert')
            components << h(SwitchTrains) if actions.include?('switch_trains')
            components << h(ReassignTrains) if actions.include?('reassign_trains')
            components << h(DoubleHeadTrains) if actions.include?('double_head_trains')
            components << h(CombinedTrains) if actions.include?('combined_trains')
            if actions.include?('lay_tile')
              components << render_action_row('Lay Tile:', h(:span, { style: { fontSize: '0.88rem', color: '#1e293b', fontWeight: '600' } }, ''))
            end
            if home_token_step?(step, actions)
              components << render_home_token_step(step, step&.current_entity || current_entity)
            elsif actions.include?('place_token')
              components << render_action_row('Place Token:', h(:span, { style: { fontSize: '0.85rem', color: '#475569', fontStyle: 'italic' } }, ''))

            end
            components << render_buy_tokens(step, step&.current_entity || current_entity) if actions.include?('buy_token')

            corporate_action_entities.each do |action_entity, _entity_actions|
              action_step = active_step_for(action_entity) || step
              components << render_issue_shares(action_step, action_entity)
            end

            if actions.include?('buy_train') || actions.include?('sell_train')
              components << render_issue_shares(step, step&.current_entity || current_entity) if actions.include?('sell_shares') || actions.include?('buy_shares')
            elsif actions.include?('buy_power')

              components << render_issue_shares(step, step&.current_entity || current_entity) if actions.include?('sell_shares')
              components << h(BuyPower)
            elsif actions.include?('borrow_train')
              components << h(BorrowTrain)

            elsif step&.respond_to?(:cash_crisis?) && step&.cash_crisis?
              components << h(CashCrisis)
              loans_rendered = true if (%w[take_loan payoff_loan] & actions).any?
            elsif (actions.include?('buy_shares') || actions.include?('sell_shares')) &&
              corporation_or_minor?(step&.current_entity || current_entity)

              price_protection = begin
                step.price_protection if step&.respond_to?(:price_protection)
              rescue StandardError
                nil
              end

              price_protection_corporation =
                if price_protection&.respond_to?(:corporation)
                  price_protection.corporation
                elsif corporation_or_minor?(price_protection)
                  price_protection
                end

              if price_protection_corporation
                components << h(
                  Corporation,
                  corporation: price_protection_corporation
                )

                components << h(
                  BuySellShares,
                  corporation: price_protection_corporation
                )

              elsif @game.corporations_can_ipo?
                components << h(CorporateBuySellShares)
              elsif (%w[issue_shares reissue_shares reissue redeem redeem_shares] & actions).none?
                components << render_issue_shares(step, step&.current_entity || current_entity)
              end
              acting_entity = step&.current_entity || current_entity

              if actions.include?('buy_shares') &&
              !actions.include?('run_routes') &&
              corporation_or_minor?(acting_entity)
                components << h(CorporateBuyShares)
              end
            elsif actions.include?('corporate_sell_shares')
              components << h(CorporateSellShares)
            elsif actions.include?('swap_train')
              components << h(SwapTrain)
            elsif actions.include?('buy_corporation')
              acting_entity = step&.current_entity || current_entity
              if corporation_or_minor?(acting_entity)
                components << h(BuyCorporation)
              else
                fallback_item = render_generic_fallback(step, acting_entity, actions)
                components << fallback_item if fallback_item
              end
            end

            if actions.include?('scrap_train') || actions.include?('surrender_train') || actions.include?('surrender')
              components << render_surrender_trains(actions, step, step&.current_entity)
            end
            components << render_loan_actions(step, step&.current_entity || current_entity, actions) if !loans_rendered && (%w[take_loan payoff_loan] & actions).any?
            components << h(ViewMergeOptions, corporation: step&.current_entity) if actions.include?('view_merge_options')

            if actions.include?('bankrupt')
              entity = step&.current_entity
              player = entity&.player? ? entity : entity&.owner

              show_bankrupt = false
              if step&.respond_to?(:must_buy_train?) && step&.must_buy_train?(entity)
                show_bankrupt = @game.respond_to?(:can_go_bankrupt?) ? @game.can_go_bankrupt?(player, entity) : true
              elsif @game.round.respond_to?(:stock?) && @game.round.stock? && step&.respond_to?(:must_sell?) && step&.must_sell?(player)
                show_bankrupt = true
              end

              if show_bankrupt
                b_options = @game.respond_to?(:bankruptcy_options) ? @game.bankruptcy_options(player) : []

                if b_options.empty?
                  components << h(:button, {
                                    style: { width: '100%', padding: '0.5rem', backgroundColor: '#dc3545', color: 'white', fontWeight: 'bold', border: 'none', borderRadius: '4px', cursor: 'pointer' },
                                    on: { click: -> { process_action(Engine::Action::Bankrupt.new(entity)) } },
                                  }, 'Declare Bankruptcy')
                else
                  b_options.each do |opt|
                    btn_text = @game.respond_to?(:bankruptcy_button_text) ? @game.bankruptcy_button_text(opt) : 'Declare Bankruptcy'
                    components << h(:button, {
                                      style: { width: '100%', padding: '0.5rem', backgroundColor: '#dc3545', color: 'white', fontWeight: 'bold', border: 'none', borderRadius: '4px', cursor: 'pointer', marginBottom: '0.2rem' },
                                      on: { click: -> { process_action(Engine::Action::Bankrupt.new(entity, option: opt)) } },
                                    }, btn_text)
                  end
                end
              end
            end

            can_buy_companies = actions.include?('buy_company') ||
                                (step.respond_to?(:buyable_companies) && step.buyable_companies(step&.current_entity)&.any?) ||
                                (step.respond_to?(:can_buy_company?) && @game.companies.any? { |c| step.can_buy_company?(step&.current_entity, c) })
            components << render_buyable_companies(step, step&.current_entity) if can_buy_companies

            components << render_buyable_trains(step, step&.current_entity) if actions.include?('buy_train')
            components << render_discard_trains(step, step&.current_entity) if actions.include?('discard_train')

            components << h(AcquireCompanies) if actions.include?('acquire_company')
            components << h(CorporateSellCompanies) if actions.include?('corporate_sell_company')
            components << h(CorporateBuyCompanies) if actions.include?('corporate_buy_company')

            if components.compact.empty?
              fallback_item = render_generic_fallback(step, step&.current_entity || current_entity, actions)
              components << fallback_item if fallback_item
            end

            h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, components.compact)
          end
        when Engine::Round::Choices
          if actions.include?('choose')
            choice_item = render_generic_choice(step, step&.current_entity || current_entity)
            choice_item ? h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, [choice_item]) : h(Round::Choices, game: @game)
          else
            h(Round::Choices, game: @game)
          end
        when Engine::Round::Auction, Engine::Round::Draft
          h(View::Game::Dashboard::DraftOverlay, game: @game)
        when Engine::Round::Merger
          if !(%w[buy_train scrap_train reassign_trains] & actions).empty? &&
             @game.train_actions_always_use_operating_round_view? &&
             !(step&.current_entity || current_entity).is_a?(Engine::Bank)

            h(Round::Operating, game: @game)

          elsif (%w[merge convert buy_shares corporate_buy_shares take_loan payoff_loan] & actions).any?
            h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, [render_merger_step(step, step&.current_entity || current_entity, actions)].compact)
          elsif actions.include?('choose')
            choice_item = render_generic_choice(step, step&.current_entity || current_entity)
            choice_item ? h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, [choice_item]) : h(Round::Merger, game: @game)
          else
            h(Round::Merger, game: @game)
          end
        else
          if is_draft_or_auction
            h(View::Game::Dashboard::DraftOverlay, game: @game)
          elsif actions.include?('assign')
            render_assign_step(step, step&.current_entity || current_entity, actions) || h(:div)
          elsif actions.include?('choose')
            choice_item = render_generic_choice(step, step&.current_entity || current_entity)
            h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', width: '100%', alignItems: 'flex-start' } }, [choice_item].compact)
          elsif @game.round.unordered?
            h(Round::Unordered, game: @game, user: nil)
          elsif @game.round.unordered?
            h(Round::Unordered, game: @game, user: nil)
          else
            render_generic_fallback(step, step&.current_entity || current_entity, actions) || h(:div)
          end
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
