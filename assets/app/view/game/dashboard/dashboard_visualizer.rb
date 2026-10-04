# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'view/game/dashboard/dashboard_command_column'
require 'view/game/dashboard/dashboard_map'
require 'view/game/dashboard/dashboard_entity_order'
require 'view/game/dashboard/dashboard_game_status'
require 'view/game/dashboard/dashboard_stock_market'
require 'view/game/history_and_undo'
require 'view/game/dashboard/par_prompt_overlay'
require 'view/game/dashboard/draft_overlay'
require 'view/game/dashboard/dashboard_tile_manifest'

# Monkey-patch Engine::Minor so 1846 / 1835 minors safely respond to .ipoed
module Engine
  class Minor
    def ipoed
      false
    end
  end
end

module View
  module Game
    class DashboardVisualizer < Snabberb::Component
      needs :game
      needs :game_data, store: true
      needs :tile_selector, default: nil
      needs :routes, store: true, default: []
      needs :user, default: nil
      include Actionable

      def active_entity
        @game.round.active_step&.current_entity
      rescue NotImplementedError, StandardError
        nil
      end

      def active_player
        entity = active_entity
        if entity
          return entity if entity.player?
          return entity.player if entity.respond_to?(:player) && entity.player
          return entity.owner if entity.respond_to?(:owner) && entity.owner
        end

        step = begin
          @game.round.active_step
        rescue StandardError
          nil
        end
        if step&.respond_to?(:active_entities)
          act_ent = step.active_entities&.first
          if act_ent
            return act_ent if act_ent.player?
            return act_ent.player if act_ent.respond_to?(:player) && act_ent.player
            return act_ent.owner if act_ent.respond_to?(:owner) && act_ent.owner
          end
        end

        if @game.respond_to?(:active_players_id) && @game.active_players_id&.any?
          active_id = @game.active_players_id.first
          return @game.players.find { |p| p.id.to_s == active_id.to_s }
        end

        nil
      end

      def render_par_overlay
        corp_id = Lib::Storage['par_menu_corp']
        return nil unless corp_id

        corporation = @game.corporation_by_id(corp_id) || (@game.corporations.find { |c| c.id.to_s == corp_id.to_s } if @game.respond_to?(:corporations))
        return nil unless corporation

        step = @game.round.active_step
        return nil unless step

        cancel_handler = lambda {
          Lib::Storage['par_menu_corp'] = nil
          update
        }

        h(::View::Game::Dashboard::ParPromptOverlay,
          game: @game,
          step: step,
          entity: active_player || active_entity,
          corporation: corporation,
          on_cancel: cancel_handler)
      end

      def render_tile_manifest_overlay
        return nil unless Lib::Storage['dashboard_tile_manifest']

        close_handler = lambda {
          Lib::Storage['dashboard_tile_manifest'] = false
          update
        }

        h(::View::Game::Dashboard::TileManifest,
          game: @game,
          tile_selector: @tile_selector,
          on_close: close_handler)
      end

      def render_global_auction_overlay
        step = @game.round&.active_step
        return nil unless step

        actions =
          begin
            @game.round.actions_for(
              step.current_entity || @game.current_entity
            )
          rescue StandardError
            []
          end

        show_overlay =
          (step.respond_to?(:auctioning) && step.auctioning) ||
          (
            !actions.include?('par') &&
            (
              step.class.name =~ /Waterfall|Draft|Auction|Initial/i ||
              (@game.round.class.name =~ /Draft|Auction/i)
            )
          )

        return nil unless show_overlay

        h(View::Game::Dashboard::DraftOverlay,
          game: @game)
      end

      def render_zoom_controls(panel_id, position_styles = {})
        pid = panel_id.to_s
        h(:div, {
            attrs: { class: 'panel-zoom-controls' },
            style: {
              position: 'absolute',
              zIndex: 20,
              display: 'flex',
              gap: '3px',
              backgroundColor: 'rgba(255,255,255,0.88)',
              padding: '2px 4px',
              borderRadius: '4px',
              border: '1px solid #ccc',
              boxShadow: '0 1px 3px rgba(0,0,0,0.15)',
            }.merge(position_styles),
          }, [
          h(:button, {
              style: { width: '20px', height: '20px', lineHeight: '16px', textAlign: 'center', fontSize: '13px', fontWeight: 'bold', cursor: 'pointer', backgroundColor: '#fff', border: '1px solid #999', borderRadius: '3px', padding: '0', color: '#333' },
              attrs: { title: 'Zoom In', type: 'button', onclick: "window.zoomPanel('#{pid}', 1.15); return false;" },
              on: { click: -> { `window.zoomPanel('#{pid}', 1.15)` } },
            }, '+'),
          h(:button, {
              style: { width: '20px', height: '20px', lineHeight: '16px', textAlign: 'center', fontSize: '13px', fontWeight: 'bold', cursor: 'pointer', backgroundColor: '#fff', border: '1px solid #999', borderRadius: '3px', padding: '0', color: '#333' },
              attrs: { title: 'Zoom Out', type: 'button', onclick: "window.zoomPanel('#{pid}', 0.85); return false;" },
              on: { click: -> { `window.zoomPanel('#{pid}', 0.85)` } },
            }, '−'),
          h(:button, {
              style: { width: '20px', height: '20px', lineHeight: '16px', textAlign: 'center', fontSize: '11px', fontWeight: 'bold', cursor: 'pointer', backgroundColor: '#fff', border: '1px solid #999', borderRadius: '3px', padding: '0', color: '#333' },
              attrs: { title: 'Reset to Fit', type: 'button', onclick: "window.resetPanelZoom('#{pid}'); return false;" },
              on: { click: -> { `window.resetPanelZoom('#{pid}')` } },
            }, '⟲'),
        ])
      end

      def render_history_overlay
        val = Lib::Storage['cmd_history_overlay']
        is_open = [true, 'true'].include?(val) || @show_history_overlay == true
        return nil unless is_open

        close_handler = lambda {
          Lib::Storage['cmd_history_overlay'] = nil
          store(:show_history_overlay, false)
          update
        }

        h(::View::Game::Dashboard::HistoryOverlay,
          game: @game,
          game_data: @game_data,
          on_close: close_handler)
      end

      def animate_last_action(action)
        return unless action && defined?(Lib::CardAnimation)

        type = if action.is_a?(Hash)
                 action['type'] || action[:type]
               elsif action.respond_to?(:type)
                 action.type
               end
        return unless type

        entity_id = if action.is_a?(Hash)
                      action['entity'] || action[:entity]
                    elsif action.respond_to?(:entity)
                      ent = action.entity
                      ent.respond_to?(:id) ? ent.id : ent
                    end

        corp_id = nil

        case type
        when 'buy_shares', 'par'
          if action.is_a?(Hash)
            shares = action['shares'] || action[:shares] || []
            corp_id = shares.first&.dig('corporation') || action['corporation'] || action[:corporation]
          elsif action.respond_to?(:bundle) && action.bundle
            corp_id = action.bundle.corporation&.id
          elsif action.respond_to?(:corporation) && action.corporation
            c = action.corporation
            corp_id = c.respond_to?(:id) ? c.id : c
          end

          return unless corp_id

          source = "#pool_shares_#{corp_id} .game-card, #ipo_shares_#{corp_id} .game-card, #treasury_shares_#{corp_id} .game-card, #market-cell-#{corp_id}, [data-corp='#{corp_id}']"
          dest = "#player_shares_#{entity_id}_#{corp_id}, #player-row-#{entity_id}, #temporal-hub"
          Lib::CardAnimation.fly(source, dest, hide_source: false)

        when 'sell_shares'
          if action.is_a?(Hash)
            shares = action['shares'] || action[:shares] || []
            corp_id = shares.first&.dig('corporation') || action['corporation'] || action[:corporation]
          elsif action.respond_to?(:bundle) && action.bundle
            corp_id = action.bundle.corporation&.id
          end

          return unless corp_id

          source = "#player_shares_#{entity_id}_#{corp_id} .game-card, #player-row-#{entity_id}, #temporal-hub"
          dest = "#pool_shares_#{corp_id}, #market-cell-#{corp_id}"
          Lib::CardAnimation.fly(source, dest, hide_source: false)

        when 'buy_train'
          train_id = if action.is_a?(Hash)
                       action['train'] || action[:train]
                     elsif action.respond_to?(:train)
                       t = action.train
                       t.respond_to?(:name) ? t.name : t
                     end

          escaped_train_id = `CSS.escape(#{train_id})`
          source = "#bank_train_#{escaped_train_id}, [id^='bank_train_#{escaped_train_id}'], #extra_cards .card-train, [id^='cmd_train_'], [id^='cmd_other_train_'], #extra_cards"
          dest = "#train_drop_#{entity_id}, #trains_#{entity_id}, #status_major_#{entity_id}, #panel-ledger"
          Lib::CardAnimation.fly(source, dest, hide_source: false)

        when 'buy_company'
          company_id = if action.is_a?(Hash)
                         action['company'] || action[:company]
                       elsif action.respond_to?(:company)
                         c = action.company
                         c.respond_to?(:id) ? c.id : c
                       end
          source = "[id^='company_wrapper_'][id$='_#{company_id}'] .game-card, #cmd_buy_company_#{company_id} .game-card, .status-company-wrapper .game-card"
          dest = "#companies_#{entity_id}, #status_major_#{entity_id}, #panel-ledger"
          Lib::CardAnimation.fly(source, dest, hide_source: false)

        end
      end

      def render_active_turn_card
        player = active_player
        player_label = if player&.respond_to?(:name) && player.name
                         player.name.to_s
                       elsif player&.respond_to?(:id) && player.id
                         player.id.to_s
                       else
                         ''
                       end

        if player_label.empty?
          entity = active_entity
          if entity&.respond_to?(:player) && entity.player&.name
            player_label = entity.player.name.to_s
          elsif entity&.respond_to?(:owner) && entity.owner&.name
            player_label = entity.owner.name.to_s
          elsif entity&.respond_to?(:name) && entity.name
            player_label = entity.name.to_s
          end
        end

        return nil if player_label.empty?

        is_hotseat = @game_data && @game_data[:mode] == :hotseat
        user_id = @user&.dig('id') || @user&.dig(:id)
        is_my_turn = is_hotseat || (user_id && @game.respond_to?(:active_players_id) && @game.active_players_id&.map(&:to_s)&.include?(user_id.to_s))

        round = @game.round
        is_stock = (round.respond_to?(:stock?) && round.stock?) || round.class.name.to_s.include?('Stock')

        acting_entity = active_entity
        acting_corp = if acting_entity && begin
          acting_entity.corporation? || acting_entity.minor?
        rescue StandardError
          false
        end
                        acting_entity
                      elsif round.respond_to?(:current_entity) && begin
                        round.current_entity&.corporation? || round.current_entity&.minor?
                      rescue StandardError
                        false
                      end
                        round.current_entity
                      end

        corp_marker = nil
        if !is_stock && acting_corp
          logo_src = begin
            (acting_corp.respond_to?(:simple_logo) && acting_corp.simple_logo) ||
              (acting_corp.respond_to?(:logo) && acting_corp.logo)
          rescue StandardError
            nil
          end

          corp_color = acting_corp.respond_to?(:color) && acting_corp.color ? acting_corp.color : '#2563eb'
          corp_text_color = acting_corp.respond_to?(:text_color) && acting_corp.text_color ? acting_corp.text_color : '#ffffff'
          corp_id = if acting_corp.respond_to?(:id)
                      acting_corp.id.to_s
                    else
                      (acting_corp.respond_to?(:name) ? acting_corp.name.to_s : '')
                    end

          marker_content = if logo_src
                             h(:img, {
                                 attrs: { src: logo_src, alt: corp_id },
                                 style: {
                                   width: '100%',
                                   height: '100%',
                                   display: 'block',
                                   borderRadius: '50%',
                                   objectFit: 'contain',
                                 },
                               })
                           else
                             h(:span, {
                                 style: {
                                   lineHeight: '26px',
                                   fontSize: '0.72rem',
                                   fontWeight: 'bold',
                                   color: corp_text_color,
                                 },
                               }, corp_id[0..3])
                           end

          corp_marker = h(:div, {
                            attrs: { class: 'active-turn-corp-marker', title: acting_corp.name.to_s },
                            style: {
                              width: '28px',
                              height: '28px',
                              minWidth: '28px',
                              borderRadius: '50%',
                              backgroundColor: corp_color,
                              border: '2px solid #ffffff',
                              boxShadow: '0 1px 4px rgba(0,0,0,0.35)',
                              display: 'flex',
                              alignItems: 'center',
                              justifyContent: 'center',
                              overflow: 'hidden',
                              flexShrink: '0',
                              marginRight: '0.55rem',
                            },
                          }, [marker_content])
        end

        card_bg = is_my_turn ? '#16a34a' : '#f1f5f9'
        card_text_color = is_my_turn ? '#ffffff' : '#0f172a'
        card_border = is_my_turn ? '2px solid #15803d' : '2px solid #94a3b8'
        card_shadow = is_my_turn ? '0 2px 8px rgba(22, 163, 74, 0.4)' : '0 1px 3px rgba(0, 0, 0, 0.08)'
        display_label = is_my_turn ? "★ YOUR TURN (#{player_label})" : player_label

        card_children = []
        card_children << corp_marker if corp_marker
        card_children << h(:span, {
                             style: {
                               whiteSpace: 'nowrap',
                               overflow: 'hidden',
                               textOverflow: 'ellipsis',
                             },
                           }, display_label)

        h(:div, {
            attrs: {
              class: 'active-turn-card',
              title: is_my_turn ? "Your turn (#{player_label})" : "Waiting on #{player_label}",
            },
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              flex: '0 0 auto',
              alignSelf: 'center',
              height: '2.85rem',
              minHeight: '2.85rem',
              maxHeight: '2.85rem',
              padding: '0 1rem',
              borderRadius: '6px',
              backgroundColor: card_bg,
              color: card_text_color,
              border: card_border,
              boxShadow: card_shadow,
              fontSize: '1.15rem',
              fontWeight: 'bold',
              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
              letterSpacing: '0.5px',
              lineHeight: '1',
              boxSizing: 'border-box',
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              transition: 'background-color 0.25s ease, color 0.25s ease, border-color 0.25s ease',
              flexShrink: '0',
            },
          }, card_children)
      end

      def render
        if @game.respond_to?(:finished?) && @game.finished?
          return h(:div, {
                     style: { display: 'flex', flexDirection: 'row', width: '100vw', height: '100vh', padding: '0.5rem', boxSizing: 'border-box', backgroundColor: '#ffffff', gap: '0.75rem' },
                   }, [
            h(:div, { style: { width: '55%', height: '100%', display: 'flex', flexDirection: 'column', gap: '0.5rem', overflow: 'hidden' } }, [
              h(:div, { style: { flex: '1 1 auto', border: '1px solid #ccc', borderRadius: '4px', display: 'flex', justifyContent: 'center', alignItems: 'center', overflow: 'hidden' } }, [
                h(:div, { attrs: { class: 'scaler-content' }, style: { display: 'flex', justifyContent: 'center', alignItems: 'center' } }, [
                  h(View::Game::DashboardMap, game: @game, user: @user, minimal: true),
                ]),
              ]),
            ]),
            h(:div, { style: { width: '45%', display: 'flex', flexDirection: 'column', height: '100%', gap: '0.5rem' } }, [
              h(:div, { style: { flex: '1 1 62%', border: '1px solid #ccc', padding: '2rem', borderRadius: '4px', textAlign: 'center', fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif' } }, [
                h(:h3, 'Final Match State'),
                h(:p, 'The 1846 game has concluded. Active turn components and ledgers are disabled.'),
              ]),
              h(:div, { style: { flex: '1 1 30%', minHeight: '12rem', border: '1px solid #ccc', padding: '0.5rem', borderRadius: '4px', display: 'flex', justifyContent: 'center', alignItems: 'flex-start', overflow: 'hidden' } }, [
                h(:div, { attrs: { class: 'scaler-content' }, style: { width: 'max-content', height: 'max-content', minWidth: '100%', display: 'flex', justifyContent: 'center', alignItems: 'flex-start', transformOrigin: 'center top' } }, [
                  h(View::Game::DashboardStockMarket, game: @game),
                ]),
              ]),
            ]),
          ])
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

        game_storage_id = @game.respond_to?(:id) ? @game.id : 'default'

        is_hotseat = @game_data && @game_data[:mode] == :hotseat
        user_id = @user&.dig('id') || @user&.dig(:id)
        is_my_turn = is_hotseat || (user_id && @game.respond_to?(:active_players_id) && @game.active_players_id&.map(&:to_s)&.include?(user_id.to_s))

        round = @game.round
        is_stock = (round.respond_to?(:stock?) && round.stock?) || round.class.name.to_s.include?('Stock')
        acting_ent = active_entity
        acting_corp = if acting_ent && begin
          acting_ent.corporation? || acting_ent.minor?
        rescue StandardError
          false
        end
                        acting_ent
                      elsif round.respond_to?(:current_entity) && begin
                        round.current_entity&.corporation? || round.current_entity&.minor?
                      rescue StandardError
                        false
                      end
                        round.current_entity
                      end

        corp_ribbon_text = (!is_stock && acting_corp&.respond_to?(:name) ? acting_corp.name.to_s : '')
        player_ribbon_text = begin
          p = active_player
          if p&.respond_to?(:name)
            p.name.to_s
          else
            (p&.respond_to?(:id) ? p.id.to_s : '')
          end
        rescue StandardError
          ''
        end

        frame_bg = '#ffffff'
        frame_border = 'none'
        frame_class = ''

        if @user && !is_hotseat
          if is_my_turn
            frame_bg = '#dcfce7'
            frame_border = '6px solid #16a34a'
            frame_class = 'frame-my-turn'
          else
            frame_bg = '#f1f5f9'
            frame_border = '4px solid #94a3b8'
            frame_class = 'frame-opponent-turn'
          end
        end

        h(:div, {
            hook: {
              insert: lambda {
                        Lib::Storage["viz_last_act_#{game_storage_id}"] = last_action_id.to_i
                        `window.scrollTo(0, 0)`
                        `document.body.style.overflow = 'hidden'`
                        `document.body.style.margin = '0'`
                        `document.body.style.padding = '0'`
                        `document.body.style.backgroundColor = '#{frame_bg}'`
                        `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: 'hidden', padding: '0', margin: '0', maxWidth: '100vw', width: '100vw', height: '100vh', backgroundColor: '#{frame_bg}', transition: 'background-color 0.3s ease' })`
                        `document.getElementById('game') && Object.assign(document.getElementById('game').style, { display: 'flex', flexDirection: 'column', overflow: 'hidden', width: '100vw', height: 'calc(100dvh - 36px)', maxWidth: '100vw', maxHeight: 'calc(100dvh - 36px)' })`

                        %x(
                          var menuStyleTag = document.getElementById('dashboard-menu-overrides');
                          if (!menuStyleTag) {
                            menuStyleTag = document.createElement('style');
                            menuStyleTag.id = 'dashboard-menu-overrides';
                            document.head.appendChild(menuStyleTag);
                          }
                          menuStyleTag.innerHTML = '' +
                            '#app > div:first-child, nav, #nav { margin-bottom: 0 !important; flex: 0 0 auto !important; } ' +
                            '#game > div:first-child { ' +
                            '  height: 26px !important; min-height: 26px !important; max-height: 26px !important; line-height: 26px !important; ' +
                            '  margin: 0 !important; padding: 0 0.5rem !important; display: flex !important; flex-direction: row !important; ' +
                            '  align-items: center !important; gap: 0.15rem !important; flex: 0 0 26px !important; box-sizing: border-box !important; ' +
                            '  overflow-x: auto !important; overflow-y: hidden !important; border: none !important; ' +
                            '} ' +
                            '#game > div:first-child a, #game > div:first-child span { ' +
                            '  font-size: 0.78rem !important; font-weight: 500 !important; line-height: 26px !important; padding: 0 0.45rem !important; ' +
                            '  color: #1a1a1a !important; text-decoration: none !important; display: inline-flex !important; align-items: center !important; ' +
                            '  border-radius: 3px !important; transition: background-color 0.15s ease !important; ' +
                            '} ' +
                            '#game > div:first-child a:hover { background-color: rgba(0, 0, 0, 0.12) !important; } ' +
                            '#game > div:first-child a.active, #game > div:first-child .active { ' +
                            '  font-weight: 700 !important; background-color: rgba(0, 0, 0, 0.18) !important; box-shadow: inset 0 -2px 0 0 #000000 !important; ' +
                            '} ' +
                            '#game > div:first-child a u, #game > div:first-child span u { text-decoration: underline !important; } ' +
                            '#viz-master-frame::after { ' +
                            '  content: ""; position: absolute; top: 0; left: 0; right: 0; bottom: 0; ' +
                            '  pointer-events: none; z-index: 9999; border-radius: 0; ' +
                            '  transition: box-shadow 0.3s ease; ' +
                            '} ' +
                            '@keyframes frame-ripple-anim { ' +
                            '  0% { box-shadow: inset 0 0 0 0 rgba(255, 255, 255, 0.95); } ' +
                            '  50% { box-shadow: inset 0 0 28px 10px rgba(255, 255, 255, 0.9); } ' +
                            '  100% { box-shadow: inset 0 0 0 0 rgba(255, 255, 255, 0); } ' +
                            '} ' +
                            '.frame-turn-ripple::after { animation: frame-ripple-anim 0.45s ease-out !important; } ' +
                            '@keyframes frame-ignition-anim { ' +
                            '  0% { box-shadow: inset 0 0 0 0 rgba(34, 197, 94, 0.9), 0 0 0 rgba(34, 197, 94, 0.9); } ' +
                            '  35% { box-shadow: inset 0 0 45px 14px rgba(34, 197, 94, 0.95), inset 0 0 15px 4px #ffffff; } ' +
                            '  100% { box-shadow: inset 0 0 18px 4px rgba(22, 163, 74, 0.5); } ' +
                            '} ' +
                            '.frame-ignition::after { animation: frame-ignition-anim 0.75s cubic-bezier(0.16, 1, 0.3, 1) !important; } ' +
                            '@keyframes frame-myturn-breath { ' +
                            '  0% { box-shadow: inset 0 0 10px 2px rgba(22, 163, 74, 0.45), inset 0 0 4px 1px rgba(34, 197, 94, 0.7); } ' +
                            '  50% { box-shadow: inset 0 0 26px 8px rgba(34, 197, 94, 0.85), inset 0 0 8px 2px rgba(255, 255, 255, 0.8); } ' +
                            '  100% { box-shadow: inset 0 0 10px 2px rgba(22, 163, 74, 0.45), inset 0 0 4px 1px rgba(34, 197, 94, 0.7); } ' +
                            '} ' +
                            '.frame-my-turn { border: 6px solid #16a34a !important; } ' +
                            '.frame-my-turn::after { animation: frame-myturn-breath 2.2s ease-in-out infinite !important; } ' +
                            '@keyframes frame-opponent-breath { ' +
                            '  0% { box-shadow: inset 0 0 4px rgba(100, 116, 139, 0.2); } ' +
                            '  50% { box-shadow: inset 0 0 12px rgba(100, 116, 139, 0.4); } ' +
                            '  100% { box-shadow: inset 0 0 4px rgba(100, 116, 139, 0.2); } ' +
                            '} ' +
                            '.frame-opponent-turn { border: 4px solid #94a3b8 !important; } ' +
                            '.frame-opponent-turn::after { animation: frame-opponent-breath 3.5s ease-in-out infinite !important; } ' +

                             '#turn-notification-ribbon { ' +
                            '  position: fixed; top: 12px; left: 50%; transform: translateX(-50%); z-index: 999999; ' +
                            '  padding: 8px 24px; border-radius: 20px; font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; ' +
                            '  font-size: 0.95rem; font-weight: 700; letter-spacing: 0.5px; pointer-events: none; ' +
                            '  box-shadow: 0 4px 18px rgba(0, 0, 0, 0.28); display: none; ' +
                            '} ' +
                            '@keyframes ribbon-slide-fade { ' +
                            '  0% { opacity: 0; transform: translate(-50%, -18px) scale(0.96); } ' +
                            '  15% { opacity: 0.95; transform: translate(-50%, 0) scale(1); } ' +
                            '  75% { opacity: 0.95; transform: translate(-50%, 0) scale(1); } ' +
                            '  100% { opacity: 0; transform: translate(-50%, -10px) scale(0.98); } ' +
                            '} ' +
                            '.ribbon-animate { animation: ribbon-slide-fade 1.8s cubic-bezier(0.16, 1, 0.3, 1) forwards !important; } ' +
                            '.ribbon-my-turn { background-color: rgba(22, 163, 74, 0.94) !important; color: #ffffff !important; border: 1px solid #15803d !important; } ' +
                            '.ribbon-opponent-turn { background-color: rgba(30, 41, 59, 0.92) !important; color: #f8fafc !important; border: 1px solid #475569 !important; }';

                          window.notifyTurnAlert = function(isMine, pName, cName, isInitial) {
                            var cleanTitle = document.title.replace(/^[🟢⏳]\s*\[.*?\]\s*/, '');
                            document.title = (isMine ? '🟢 [YOUR TURN] ' : ('⏳ [' + pName + '] ')) + cleanTitle;

                            var frame = document.getElementById('viz-master-frame');
                            if (frame) {
                              frame.classList.remove('frame-turn-ripple', 'frame-ignition', 'frame-my-turn', 'frame-opponent-turn');
                              void frame.offsetWidth;
                              if (!isInitial) frame.classList.add('frame-turn-ripple');
                              if (isMine) {
                                if (!isInitial) frame.classList.add('frame-ignition');
                                frame.classList.add('frame-my-turn');
                              } else {
                                frame.classList.add('frame-opponent-turn');
                              }
                            }

                            if (!isInitial && pName) {
                              var ribbon = document.getElementById('turn-notification-ribbon');
                              if (ribbon) {
                                var msg = isMine ? ('★ YOUR TURN — ' + (cName ? cName + ' (' + pName + ')' : pName)) : ('▶ ' + (cName ? cName + ': ' : '') + pName + ' is Operating');
                                ribbon.textContent = msg;
                                ribbon.className = (isMine ? 'ribbon-my-turn' : 'ribbon-opponent-turn') + ' ribbon-animate';
                                ribbon.style.display = 'block';
                                clearTimeout(window._turnRibbonTimer);
                                window._turnRibbonTimer = setTimeout(function() {
                                  if (ribbon) ribbon.style.display = 'none';
                                }, 1800);
                              }
                            }
                          };

                          window.notifyTurnAlert(#{is_my_turn ? true : false}, #{player_ribbon_text}, #{corp_ribbon_text}, true);
                        )

                        %x(window.init18xxResizers = function() {
                          var savedResizers = {};
                          try {
                            savedResizers = JSON.parse(sessionStorage.getItem('18xx_viz_resizers')) || {};
                            window.scalerUserZoom = JSON.parse(sessionStorage.getItem('18xx_viz_zoom')) || { 'map-panel-bot': 1.0, 'panel-market': 1.0 };
                            window.scalerPanOffset = JSON.parse(sessionStorage.getItem('18xx_viz_pan')) || {
                              'map-panel-bot': { x: 0, y: 0 },
                              'panel-market': { x: 0, y: 0 }
                            };
                          } catch(e) {
                            window.scalerUserZoom = { 'map-panel-bot': 1.0, 'panel-market': 1.0 };
                            window.scalerPanOffset = { 'map-panel-bot': { x: 0, y: 0 }, 'panel-market': { x: 0, y: 0 } };
                          }

                          var createResizer = function(resizerId, prevId, nextId, isVertical) {
                            var resizer = document.getElementById(resizerId);
                            var prev = document.getElementById(prevId);
                            var next = document.getElementById(nextId);
                            if(!resizer || !prev || !next) return;

                            if (savedResizers[prevId]) {
                              prev.style.flex = savedResizers[prevId];
                              next.style.flex = '1 1 auto';
                            }

                            var x = 0, y = 0, prevFlex = 0, nextFlex = 0;
                            var mouseDownHandler = function(e) {
                              x = e.clientX; y = e.clientY;
                              var prevRect = prev.getBoundingClientRect();
                              var nextRect = next.getBoundingClientRect();
                              prevFlex = isVertical ? prevRect.height : prevRect.width;
                              nextFlex = isVertical ? nextRect.height : nextRect.width;
                              document.addEventListener('mousemove', mouseMoveHandler);
                              document.addEventListener('mouseup', mouseUpHandler);
                              document.body.style.cursor = isVertical ? 'row-resize' : 'col-resize';
                            };
                            var mouseMoveHandler = function(e) {
                              var delta = isVertical ? (e.clientY - y) : (e.clientX - x);
                              var totalFlex = prevFlex + nextFlex;
                              var minPrev = 0;
                              var minNext = 0;
                              if (prev) {
                                var computedPrevMin = isVertical ? window.getComputedStyle(prev).minHeight : window.getComputedStyle(prev).minWidth;
                                minPrev = parseFloat(computedPrevMin) || 0;
                              }
                              if (next) {
                                var computedMin = isVertical ? window.getComputedStyle(next).minHeight : window.getComputedStyle(next).minWidth;
                                minNext = parseFloat(computedMin) || 0;
                              }
                              var maxPrev = Math.max(minPrev, totalFlex - minNext);
                              var newPrevFlex = Math.max(minPrev, Math.min(maxPrev, prevFlex + delta));
                              var newNextFlex = Math.max(0, totalFlex - newPrevFlex);

                              prev.style.flex = '0 0 ' + newPrevFlex + 'px';
                              next.style.flex = '1 1 auto';

                              if (!isVertical) {
                                prev.style.height = '100%';
                                next.style.height = '100%';
                              }
                            };
                            var mouseUpHandler = function() {
                              document.removeEventListener('mousemove', mouseMoveHandler);
                              document.removeEventListener('mouseup', mouseUpHandler);
                              document.body.style.cursor = '';
                              try {
                                var s = JSON.parse(sessionStorage.getItem('18xx_viz_resizers')) || {};
                                s[prevId] = prev.style.flex;
                                sessionStorage.setItem('18xx_viz_resizers', JSON.stringify(s));
                              } catch(e) {}
                            };
                            resizer.addEventListener('mousedown', mouseDownHandler);
                          };

                          createResizer('resizer-v-main', 'col-left', 'col-right', false);
                          createResizer('resizer-h-cmd-map', 'command-space-top', 'map-panel-bot', true);
                          createResizer('resizer-h-entity-ledger', 'temporal-hub', 'panel-ledger', true);
                          createResizer('resizer-h-ledger-market', 'panel-ledger', 'panel-market', true);

                          window.scalerScales = window.scalerScales || {};

                          window.applyPanelTransform = function(panelId) {
                            var panel = document.getElementById(panelId);
                            if (!panel) return;
                            var wrapper = panel.querySelector('.scaler-content');
                            if (!wrapper) return;

                            var offset = (window.scalerPanOffset && window.scalerPanOffset[panelId]) || { x: 0, y: 0 };
                            wrapper.style.left = offset.x + 'px';
                            wrapper.style.top = offset.y + 'px';

                            if (panelId === 'map-panel-bot') {
                              var sizer = panel.querySelector('.map-sizer');
                              var uZoom = (window.scalerUserZoom && window.scalerUserZoom[panelId]) || 1.0;
                              var baseScale = (window.scalerScales && window.scalerScales[panelId]) || 1.0;
                              var effScale = baseScale * uZoom;
                              if (sizer) {
                                var svgEl = wrapper.querySelector('svg');
                                var cw = parseFloat(wrapper.style.width) || (svgEl && (parseFloat(svgEl.getAttribute('width')) || (svgEl.viewBox && svgEl.viewBox.baseVal && svgEl.viewBox.baseVal.width))) || wrapper.scrollWidth || 0;
                                var ch = parseFloat(wrapper.style.height) || (svgEl && (parseFloat(svgEl.getAttribute('height')) || (svgEl.viewBox && svgEl.viewBox.baseVal && svgEl.viewBox.baseVal.height))) || wrapper.scrollHeight || 0;
                                if (cw > 0 && ch > 0) {
                                  var scrollCanvas = panel.querySelector('#map-scroll-canvas');
                                  var viewportW = scrollCanvas ? scrollCanvas.clientWidth : panel.clientWidth;
                                  var viewportH = scrollCanvas ? scrollCanvas.clientHeight : panel.clientHeight;
                                  var scaledW = cw * effScale;
                                  var scaledH = ch * effScale;
                                  var targetW = scaledW > viewportW + 1 ? Math.ceil(scaledW) : viewportW;
                                  var targetH = scaledH > viewportH + 1 ? Math.ceil(scaledH) : viewportH;
                                  sizer.style.width = targetW + 'px';
                                  sizer.style.height = targetH + 'px';
                                  sizer.style.minWidth = targetW + 'px';
                                  sizer.style.minHeight = targetH + 'px';
                                }
                              }
                            }

                            var dynStyle = document.getElementById('dynamic-scaler-styles');
                            if (!dynStyle) return;
                            var css = '';
                            for (var id in window.scalerScales) {
                              var uZoom = (window.scalerUserZoom && window.scalerUserZoom[id]) || 1.0;
                              var effScale = window.scalerScales[id] * uZoom;
                              css += '#' + id + ' .scaler-content { transform: scale(' + effScale + ') !important; transform-origin: top left !important; }\n';
                            }
                            dynStyle.innerHTML = css;
                          };

                          window.zoomPanel = function(panelId, factor) {
                            window.scalerUserZoom = window.scalerUserZoom || {};
                            var cur = (window.scalerUserZoom && window.scalerUserZoom[panelId]) || 1.0;
                            window.scalerUserZoom[panelId] = Math.max(0.15, Math.min(4.0, cur * factor));
                            try { sessionStorage.setItem('18xx_viz_zoom', JSON.stringify(window.scalerUserZoom)); } catch(e) {}
                            window.applyPanelTransform(panelId);
                          };

                          window.resetPanelZoom = function(panelId) {
                            window.scalerUserZoom = window.scalerUserZoom || {};
                            window.scalerPanOffset = window.scalerPanOffset || {};
                            window.scalerUserZoom[panelId] = 1.0;
                            window.scalerPanOffset[panelId] = { x: 0, y: 0 };
                            var panel = document.getElementById(panelId);
                            if (panel) {
                              var scrollCanvas = panel.querySelector('#map-scroll-canvas') || panel;
                              scrollCanvas.scrollLeft = 0;
                              scrollCanvas.scrollTop = 0;
                            }
                            try {
                              sessionStorage.setItem('18xx_viz_zoom', JSON.stringify(window.scalerUserZoom));
                              sessionStorage.setItem('18xx_viz_pan', JSON.stringify(window.scalerPanOffset));
                            } catch(e) {}
                            window.applyPanelTransform(panelId);
                          };

                          var createPanHandler = function(panelId) {
                            var panel = document.getElementById(panelId);
                            if (!panel) return;
                            var wrapper = panel.querySelector('.scaler-content');
                            if (!wrapper) return;

                            wrapper.style.position = 'absolute';
                            window.scalerPanOffset[panelId] = window.scalerPanOffset[panelId] || { x: 0, y: 0 };
                            window.scalerUserZoom[panelId] = window.scalerUserZoom[panelId] || 1.0;

                            var isPanning = false;
                            var startX = 0, startY = 0;

                            panel.addEventListener('mousedown', function(e) {
                              if (!e.altKey || e.button !== 0 || (e.target.closest && e.target.closest('.panel-zoom-controls'))) return;
                              isPanning = true;
                              var currentOffset = window.scalerPanOffset[panelId] || { x: 0, y: 0 };
                              startX = e.clientX - currentOffset.x;
                              startY = e.clientY - currentOffset.y;
                              panel.style.cursor = 'grabbing';
                            });

                            document.addEventListener('mousemove', function(e) {
                              if (!isPanning) return;
                              window.scalerPanOffset[panelId] = {
                                x: e.clientX - startX,
                                y: e.clientY - startY
                              };
                              wrapper.style.left = window.scalerPanOffset[panelId].x + 'px';
                              wrapper.style.top = window.scalerPanOffset[panelId].y + 'px';
                            });

                            document.addEventListener('mouseup', function() {
                              if (!isPanning) return;
                              isPanning = false;
                              panel.style.cursor = '';
                              try { sessionStorage.setItem('18xx_viz_pan', JSON.stringify(window.scalerPanOffset)); } catch(e) {}
                            });

                            panel.addEventListener('wheel', function(e) {
                              if (!e.altKey) return;
                              e.preventDefault();

                              var rect = panel.getBoundingClientRect();
                              var mouseX = e.clientX - rect.left;
                              var mouseY = e.clientY - rect.top;

                              var currentZ = (window.scalerUserZoom && window.scalerUserZoom[panelId]) || 1.0;
                              var baseScale = (window.scalerScales && window.scalerScales[panelId]) || 1.0;
                              var oldEffScale = baseScale * currentZ;

                              var zoomDelta = e.deltaY < 0 ? 1.06 : 0.94;
                              var newZ = Math.max(0.15, Math.min(4.0, currentZ * zoomDelta));
                              var newEffScale = baseScale * newZ;

                              var currentOffset = window.scalerPanOffset[panelId] || { x: 0, y: 0 };

                              var newOffsetX = mouseX - ((mouseX - currentOffset.x) / oldEffScale) * newEffScale;
                              var newOffsetY = mouseY - ((mouseY - currentOffset.y) / oldEffScale) * newEffScale;

                              window.scalerUserZoom[panelId] = newZ;
                              window.scalerPanOffset[panelId] = { x: newOffsetX, y: newOffsetY };

                              try {
                                sessionStorage.setItem('18xx_viz_zoom', JSON.stringify(window.scalerUserZoom));
                                sessionStorage.setItem('18xx_viz_pan', JSON.stringify(window.scalerPanOffset));
                              } catch(err) {}

                              window.applyPanelTransform(panelId);
                            }, { passive: false });
                          };

                          createPanHandler('map-panel-bot');
                          createPanHandler('panel-market');

                          var styleTag = document.getElementById('dashboard-map-svg-styles');
                          if (!styleTag) {
                            styleTag = document.createElement('style');
                            styleTag.id = 'dashboard-map-svg-styles';
                            document.head.appendChild(styleTag);
                          }
                          styleTag.innerHTML = '#map-scroll-canvas svg { max-width: none !important; } ' +
                                               '.scaler-content .tile__text { font-size: 0.75em !important; } ' +
                                               '.scaler-content text.number { font-size: 0.55em !important; } ' +
                                               '@keyframes map-hex-pulse { ' +
                                               '  0% { stroke: #ff0055; stroke-width: 8px; fill-opacity: 0.18; } ' +
                                               '  50% { stroke: #fbbf24; stroke-width: 10px; fill-opacity: 0.38; } ' +
                                               '  100% { stroke: #ff0055; stroke-width: 8px; fill-opacity: 0.18; } ' +
                                               '} ' +
                                               '.map-hex-highlight .hex-highlight-poly { ' +
                                               '  stroke: #ff0055 !important; ' +
                                               '  stroke-width: 8px !important; ' +
                                               '  fill: #ff0055 !important; ' +
                                               '  fill-opacity: 0.25 !important; ' +
                                               '  animation: map-hex-pulse 1.2s infinite ease-in-out !important; ' +
                                               '}';

                          window.highlightMapHexes = function(hexIds) {
                            if (!hexIds) return;
                            var ids = Array.isArray(hexIds) ? hexIds : [hexIds];
                            if (!ids.length) return;
                            var mapPanel = document.getElementById('map-panel-bot') || document;
                            for (var i = 0; i < ids.length; i++) {
                              var raw = String(ids[i]);
                              var variants = [raw, raw.toUpperCase(), raw.toLowerCase()];
                              for (var v = 0; v < variants.length; v++) {
                                var hid = variants[v];
                                var targets = mapPanel.querySelectorAll('#hex-' + hid + ', [data-hex="' + hid + '"], .hex-' + hid);
                                for (var j = 0; j < targets.length; j++) {
                                  targets[j].classList.add('map-hex-highlight');
                                  var poly = targets[j].querySelector('.hex-highlight-poly');
                                  if (poly) {
                                    poly.setAttribute('stroke', '#ff0055');
                                    poly.setAttribute('stroke-width', '8');
                                    poly.setAttribute('fill', '#ff0055');
                                    poly.setAttribute('fill-opacity', '0.25');
                                  }
                                }
                              }
                            }
                          };

                          window.clearMapHexHighlights = function() {
                            var mapPanel = document.getElementById('map-panel-bot') || document;
                            var highlighted = mapPanel.querySelectorAll('.map-hex-highlight');
                            for (var i = 0; i < highlighted.length; i++) {
                              highlighted[i].classList.remove('map-hex-highlight');
                              var poly = highlighted[i].querySelector('.hex-highlight-poly');
                              if (poly) {
                                var origStroke = poly.getAttribute('data-orig-stroke') || 'transparent';
                                var origWidth = poly.getAttribute('data-orig-width') || '0';
                                poly.setAttribute('stroke', origStroke);
                                poly.setAttribute('stroke-width', origWidth);
                                poly.setAttribute('fill-opacity', '0');
                              }
                            }
                          };

                          var fitObserver = new ResizeObserver(function(entries) {
                            var dynStyle = document.getElementById('dynamic-scaler-styles');
                            if (!dynStyle) {
                              dynStyle = document.createElement('style');
                              dynStyle.id = 'dynamic-scaler-styles';
                              document.head.appendChild(dynStyle);
                            }

                            for (var i = 0; i < entries.length; i++) {
                              var panel = entries[i].target;
                              if (!panel.id) continue;
                              var wrapper = panel.querySelector('.scaler-content');
                              if (!wrapper) continue;

                              var cw = wrapper.scrollWidth;
                              var ch = wrapper.scrollHeight;

                              if (panel.id === 'map-panel-bot') {
                                var svg = wrapper.querySelector('svg');
                                var topG = svg ? svg.querySelector('g') : null;
                                if (svg && topG) {
                                  var bbox = topG.getBBox();
                                  var requiredWidth = bbox.width + 50;
                                  var requiredHeight = bbox.height + 50;
                                  svg.setAttribute('viewBox', (bbox.x - 25) + ' ' + (bbox.y - 25) + ' ' + requiredWidth + ' ' + requiredHeight);
                                  svg.setAttribute('width', requiredWidth);
                                  svg.setAttribute('height', requiredHeight);
                                  svg.style.width = requiredWidth + 'px';
                                  svg.style.height = requiredHeight + 'px';
                                  wrapper.style.width = requiredWidth + 'px';
                                  wrapper.style.height = requiredHeight + 'px';
                                  cw = requiredWidth;
                                  ch = requiredHeight;
                                }
                              }

                              if (panel.id === 'panel-market') {
                                var innerChild = wrapper.firstElementChild;
                                if (innerChild) {
                                  var svg = innerChild.tagName && innerChild.tagName.toLowerCase() === 'svg' ? innerChild : innerChild.querySelector('svg');
                                  if (svg) {
                                    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
                                    var allG = svg.querySelectorAll('g');
                                    if (allG.length > 0) {
                                      for (var gi = 0; gi < allG.length; gi++) {
                                        try {
                                          var gb = allG[gi].getBBox();
                                          if (gb.width > 0 || gb.height > 0) {
                                            minX = Math.min(minX, gb.x);
                                            minY = Math.min(minY, gb.y);
                                            maxX = Math.max(maxX, gb.x + gb.width);
                                            maxY = Math.max(maxY, gb.y + gb.height);
                                          }
                                        } catch(err) {}
                                      }
                                    }
                                    if (svg.getBBox) {
                                      try {
                                        var sb = svg.getBBox();
                                        if (sb.width > 0 || sb.height > 0) {
                                          minX = Math.min(minX, sb.x);
                                          minY = Math.min(minY, sb.y);
                                          maxX = Math.max(maxX, sb.x + sb.width);
                                          maxY = Math.max(maxY, sb.y + sb.height);
                                        }
                                      } catch(err) {}
                                    }

                                    if (isFinite(maxX) && isFinite(maxY)) {
                                      var requiredWidth = (maxX - minX) + 24;
                                      var requiredHeight = (maxY - minY) + 40;
                                      svg.setAttribute('viewBox', (minX - 12) + ' ' + (minY - 10) + ' ' + requiredWidth + ' ' + requiredHeight);
                                      svg.style.overflow = 'visible';
                                      svg.setAttribute('width', requiredWidth);
                                      svg.setAttribute('height', requiredHeight);
                                      svg.style.width = requiredWidth + 'px';
                                      svg.style.height = requiredHeight + 'px';
                                      wrapper.style.width = requiredWidth + 'px';
                                      wrapper.style.height = requiredHeight + 'px';
                                      cw = requiredWidth;
                                      ch = requiredHeight;
                                    }
                                  } else {
                                    cw = innerChild.scrollWidth;
                                    ch = innerChild.scrollHeight;
                                    wrapper.style.width = cw + 'px';
                                    wrapper.style.height = ch + 'px';
                                  }
                                }
                              }

                              var pw = entries[i].contentRect.width - 16;
                              var ph = entries[i].contentRect.height - 16;

                              if (cw > 0 && ch > 0) {
                                window.scalerScales[panel.id] = Math.min(pw / cw, ph / ch);
                              }
                            }

                            for (var pId in window.scalerScales) {
                              window.applyPanelTransform(pId);
                            }
                          });

                          ['map-panel-bot', 'panel-market'].forEach(function(id) {
                            var el = document.getElementById(id);
                            if (el) fitObserver.observe(el);
                          });
                        };
                        setTimeout(window.init18xxResizers, 200);)
                      },
              postpatch: lambda { |_old, _vnode|
                           prev_id = Lib::Storage["viz_last_act_#{game_storage_id}"]&.to_i || 0
                           curr_id = last_action_id.to_i

                           if curr_id > prev_id && prev_id.positive?
                             animate_last_action(last_action)
                             %x(
                               if (window.notifyTurnAlert) {
                                 window.notifyTurnAlert(#{is_my_turn ? true : false}, #{player_ribbon_text}, #{corp_ribbon_text}, false);
                               }
                             )
                           end
                           Lib::Storage["viz_last_act_#{game_storage_id}"] = curr_id
                         },
              destroy: lambda {
                         %x(
                           var menuStyle = document.getElementById('dashboard-menu-overrides');
                           if (menuStyle) menuStyle.remove();
                           var ribbon = document.getElementById('turn-notification-ribbon');
                           if (ribbon) ribbon.remove();
                         )
                         `document.body.style.backgroundColor = ''`
                         `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: '', padding: '', margin: '', maxWidth: '', width: '', height: '', backgroundColor: '', transition: '' })`
                         `document.getElementById('game') && Object.assign(document.getElementById('game').style, { overflow: '', width: '', height: '', maxWidth: '', maxHeight: '' })`
                       },
            },
            attrs: {
              id: 'viz-master-frame',
              class: frame_class,
            },
            style: {
              display: 'flex',
              flexDirection: 'row',
              flex: '1 1 auto',
              width: '100vw',
              height: 'calc(100% - 26px)',
              minHeight: '0',
              boxSizing: 'border-box',
              position: 'relative',
              overflow: 'hidden',
              padding: '0.4rem 0.5rem 0.5rem 0.5rem',
              backgroundColor: frame_bg,
              border: frame_border,
              borderTop: 'none',
              transition: 'background-color 0.3s ease, border 0.3s ease',
            },
          }, [
h(:div, { attrs: { id: 'col-left' }, style: { flex: '0 0 55%', height: '100%', minHeight: '0', display: 'flex', flexDirection: 'column', overflow: 'hidden' } }, [
              h(:div, { attrs: { id: 'command-space-top' }, style: { flex: '0 0 9rem', minHeight: '6.5rem', border: '1px solid #ccc', borderRadius: '4px', backgroundColor: '#fff', display: 'flex', flexDirection: 'column', overflow: 'hidden', boxSizing: 'border-box' } }, [
                h(:div, { attrs: { id: 'command-scroll-viewport' }, style: { padding: '1.45rem 0.25rem 0.2rem', height: '100%', minHeight: '0', boxSizing: 'border-box', overflow: 'hidden' } }, [
                  h(View::Game::DashboardCommandColumn, game: @game, user: @user, game_data: @game_data),
                ]),
              ]),

              h(:div, { attrs: { id: 'resizer-h-cmd-map' }, style: { flex: '0 0 0.5rem', cursor: 'row-resize', zIndex: 10 } }),

              h(:div, { attrs: { id: 'map-panel-bot' }, style: { flex: '1 1 auto', minHeight: '0', boxSizing: 'border-box', border: '1px solid #ccc', borderRadius: '4px 4px 0 0', backgroundColor: '#fff', overflow: 'hidden', position: 'relative' } }, [
                render_zoom_controls('map-panel-bot', { top: '6px', left: '6px' }),
                h(:div, {
                    attrs: { id: 'map-scroll-canvas' },
                    style: {
                      width: '100%',
                      height: '100%',
                      maxHeight: '100%',
                      minHeight: '0',
                      overflow: 'auto',
                      overflowX: 'auto',
                      overflowY: 'auto',
                      position: 'relative',
                      boxSizing: 'border-box',
                    },
                  }, [
                  h(:div, {
                      attrs: { class: 'map-sizer' },
                      style: {
                        position: 'relative',
                        display: 'block',
                        width: '100%',
                        height: '100%',
                        minWidth: '100%',
                        minHeight: '100%',
                      },
                    }, [
                    h(:div, { attrs: { class: 'scaler-content' }, style: { position: 'absolute', top: '0', left: '0', width: 'max-content', height: 'max-content', transformOrigin: 'top left' } }, [
                      h(View::Game::DashboardMap, game: @game, user: @user),
                    ]),
                  ]),
                ]),
                h(:div, {
                    attrs: { class: 'panel-manifest-control' },
                    style: {
                      position: 'absolute',
                      top: '8px',
                      right: '18px',
                      zIndex: 30,
                      display: 'flex',
                    },
                  }, [
                  h(:button, {
                      attrs: { id: 'btn-show-tile-manifest', type: 'button', title: 'Toggle tile manifest overlay' },
                      style: {
                        backgroundColor: '#ffffff',
                        color: '#1e293b',
                        border: '1px solid #94a3b8',
                        borderRadius: '4px',
                        padding: '4px 9px',
                        fontSize: '0.78rem',
                        fontWeight: 'bold',
                        cursor: 'pointer',
                        boxShadow: '0 1px 3px rgba(0,0,0,0.2)',
                        display: 'inline-flex',
                        alignItems: 'center',
                        lineHeight: '1.2',
                      },
                      on: {
                        click: lambda {
                          Lib::Storage['dashboard_tile_manifest'] = !Lib::Storage['dashboard_tile_manifest']
                          update
                        },
                      },
                    }, 'Show Remaining Tiles'),
                ]),
              ]),
            ]),

h(:div, { attrs: { id: 'resizer-v-main' }, style: { flex: '0 0 0.75rem', cursor: 'col-resize', zIndex: 10 } }),

h(:div, { attrs: { id: 'col-right' }, style: { flex: '1 1 auto', display: 'flex', flexDirection: 'column', height: '100%', maxHeight: '100%', overflow: 'hidden', gap: '0.5rem' } }, [
  h(:div, {
      attrs: { id: 'temporal-hub' },
      style: {
        flex: '0 0 3.75rem',
        minHeight: '3.25rem',
        display: 'flex',
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-start',
        border: '1px solid #ccc',
        borderRadius: '4px',
        backgroundColor: '#f8f9fa',
        padding: '0 0.65rem',
        boxSizing: 'border-box',
        overflow: 'hidden',
        gap: '0.65rem',
      },
    }, [
    h(:style, {}, '
                  /* Target the div children directly to account for prepended style tags */
                  #command-space-top #dashboard-command-panel-bar > div:first-of-type {
                    display: none !important;
                  }
                  #command-space-top #dashboard-command-panel-bar > div:nth-of-type(2) {
                    flex: 1 1 auto !important;
                    min-width: 0 !important;
                    border-left: none !important;
                  }
                  #command-space-top #dashboard-command-panel-bar > div:nth-of-type(3) {
                    flex: 0 0 28% !important;
                    min-width: 15.5rem !important;
                    max-width: none !important;
                    box-sizing: border-box !important;
                    overflow: visible !important;
                  }
                '),
    render_active_turn_card,
    h(:div, {
        attrs: { class: 'entity-order-content' },
        style: {
          flex: '1 1 auto',
          minWidth: '0',
          height: '2.5rem',
          display: 'flex',
          alignItems: 'center',
          overflow: 'hidden',
        },
      }, [
      if @game.respond_to?(:finished?) && @game.finished?
        h(View::Game::DashboardEntityOrder, round: nil)
      else
        h(View::Game::DashboardEntityOrder, round: @game.round)
      end,
    ]),
  ].compact),

  h(:div, { attrs: { id: 'resizer-h-entity-ledger', title: 'Drag to resize Entity Order' }, style: { flex: '0 0 0.5rem', minHeight: '0.5rem', cursor: 'row-resize', zIndex: 10, backgroundColor: 'transparent', borderRadius: '0' } }),

  h(:div, { attrs: { id: 'panel-ledger' }, style: { flex: '1 1 auto', overflow: 'auto', border: '1px solid #ccc', padding: '0.4rem', borderRadius: '4px', backgroundColor: '#fff', boxSizing: 'border-box' } }, [
    h(:div, { style: { display: 'flex', flexDirection: 'column', width: 'max-content', minWidth: '100%' } }, [
      h(View::Game::DashboardGameStatus, game: @game),
    ]),
  ]),

  h(:div, { attrs: { id: 'resizer-h-ledger-market' }, style: { flex: '0 0 0.5rem', cursor: 'row-resize', zIndex: 10 } }),

  h(:div, { attrs: { id: 'panel-market' }, style: { flex: '1 1 auto', minHeight: '12rem', overflow: 'hidden', border: '1px solid #ccc', padding: '0.5rem', borderRadius: '4px', backgroundColor: '#fff', boxSizing: 'border-box', position: 'relative' } }, [
    render_zoom_controls('panel-market', { top: '6px', right: '6px' }),
    h(:div, { attrs: { class: 'scaler-content' }, style: { position: 'absolute', top: '0', left: '0', display: 'flex', flexDirection: 'column', width: 'max-content', height: 'max-content', transformOrigin: 'top left', margin: '0', padding: '0' } }, [
      h(View::Game::DashboardStockMarket, game: @game),
    ]),
  ]),
]),
render_global_auction_overlay,
render_par_overlay,
render_tile_manifest_overlay,

h(:div, { attrs: { id: 'turn-notification-ribbon' } }),
].compact)
      end
    end
  end
end
# rubocop:enable Layout/LineLength
