# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'view/game/dashboard/dashboard_map'
require 'view/game/dashboard/dashboard_entity_order'
require 'lib/settings'
require 'view/game/dashboard/dashboard_game_status'
require 'view/game/dashboard/dashboard_stock_market'
require 'view/game/history_and_undo'
require 'view/game/dashboard/par_prompt_overlay'
require 'view/game/dashboard/draft_overlay'
require 'view/game/dashboard/bidding_overlay'
require 'view/game/dashboard/dashboard_tile_manifest'
require 'view/game/dashboard/other_games_overlay'
require 'view/game/dashboard/dashboard_action_window'
require 'view/game/dashboard/chat_overlay'
require 'view/game/dashboard/dashboard_ai_player'
require 'view/game/dashboard/dashboard_help_overlay'

# Monkey-patch Engine::Minor so 1846 / 1835 minors safely respond to .ipoed
module Engine
  class Minor
    def ipoed
      false
    end
  end

  # Dashboard compatibility: auction views may inspect the owner of an
  # auction item as though it were a corporation-bearing entity. In games
  # such as 1837 that owner can legitimately be the bank. The bank has no
  # corporation, so expose that fact as nil instead of raising NoMethodError.
  class Bank
    def corporation
      nil
    end

    def corporation?
      false
    end
  end
end

# Snabbdom Extensibility Shield:
# Prevents Opal.nil and NilClass singletons from being frozen so Snabbdom
# can assign `.elm` anchors safely if a component's render method returns nil.
%x{
  (function() {
    if (window.__snabbdom_extensibility_shield) return;
    window.__snabbdom_extensibility_shield = true;

    var origFreeze = Object.freeze;
    Object.freeze = function(obj) {
      if (obj && (
        (typeof Opal !== 'undefined' && obj === Opal.nil) ||
        (obj.$$class && (obj.$$class.$$name === 'NilClass' || obj.$$class.$$name === 'FalseClass')) ||
        (obj.constructor && obj.constructor.name === 'NilClass')
      )) {
        return obj;
      }
      return origFreeze.call(Object, obj);
    };

    var origPreventExtensions = Object.preventExtensions;
    Object.preventExtensions = function(obj) {
      if (obj && (
        (typeof Opal !== 'undefined' && obj === Opal.nil) ||
        (obj.$$class && (obj.$$class.$$name === 'NilClass' || obj.$$class.$$name === 'FalseClass')) ||
        (obj.constructor && obj.constructor.name === 'NilClass')
      )) {
        return obj;
      }
      return origPreventExtensions.call(Object, obj);
    };

    if (typeof Opal !== 'undefined' && Opal.nil) {
      try {
        Object.defineProperty(Opal.nil, 'elm', {
          writable: true,
          configurable: true,
          value: null
        });
      } catch (e) {}
    }
  })();
}

module View
  module Game
    class DashboardVisualizer < Snabberb::Component
      needs :game
      needs :game_data, store: true
      include Lib::Settings
      needs :tile_selector, default: nil
      needs :routes, store: true, default: []
      needs :user, default: nil, store: true
      needs :show_history_overlay, store: true, default: false
      needs :show_move_history, store: true, default: false
      needs :par_menu_corp, store: true, default: nil
      needs :show_other_games_overlay, store: true, default: false
      needs :show_actions_window, store: true, default: false
      needs :show_chat_overlay, store: true, default: false
      needs :show_help_overlay, store: true, default: false
      needs :show_meme_revenue, store: true, default: nil
      needs :show_location_names, store: true, default: nil
      needs :simple_logos, store: true, default: nil
      include Actionable

      def meme_revenue_enabled?
        return @show_meme_revenue unless @show_meme_revenue.nil?

        [true, 'true'].include?(Lib::Storage['show_meme_revenue'])
      end

      def toggle_meme_revenue
        new_val = !meme_revenue_enabled?

        # The component state is the source of truth for this render.
        @show_meme_revenue = new_val
        Lib::Storage['show_meme_revenue'] = new_val
        store(:show_meme_revenue, new_val, skip: true)

        %x{
          try {
            localStorage.setItem('show_meme_revenue', #{new_val} ? 'true' : 'false');
          } catch(e) {}
        }

        update
      end

      def action_required_for_me?
        return false if @game.respond_to?(:finished?) && @game.finished?

        is_hotseat =
          @game_data &&
          (
            @game_data[:mode] == :hotseat ||
            @game_data['mode'] == 'hotseat'
          )

        step = begin
          @game.round&.active_step
        rescue StandardError
          nil
        end

        return false unless step

        # Use exactly ONE acting entity.
        #
        # Do not aggregate step.active_entities here. Some OR steps expose
        # multiple entities even though the dashboard AI must perform only
        # the action belonging to the entity whose turn is current.
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

        entity ||= active_entity

        return false unless entity

        # Check only the current entity for a real game action.
        actions = begin
          step.respond_to?(:actions) ? (step.actions(entity) || []) : []
        rescue NotImplementedError, StandardError
          []
        end

        if actions.empty?
          actions = begin
            @game.round.actions_for(entity) || []
          rescue NotImplementedError, StandardError
            []
          end
        end

        actionable =
          actions.any? do |action|
            action_name = action.to_s
            action_name != 'undo' && action_name != 'redo'
          end

        return false unless actionable

        # In hotseat mode the locally displayed current entity is actionable.
        return true if is_hotseat

        uid = current_user_id
        return false if uid.empty?

        # Player entity
        if entity.respond_to?(:player?) &&
           entity.player? &&
           entity.respond_to?(:id)

          return entity.id.to_s == uid.to_s
        end

        # Corporation/entity exposing its controlling player directly
        if entity.respond_to?(:player)
          player = entity.player
          return player.id.to_s == uid.to_s if player && player.respond_to?(:id)
        end

        # Corporation/entity owned by a player
        if entity.respond_to?(:owner)
          owner = entity.owner
          return owner.id.to_s == uid.to_s if owner && owner.respond_to?(:id)
        end

        # Final fallback for games which expose player activity separately.
        if @game.respond_to?(:active_players_id)
          active_ids = Array(@game.active_players_id).compact.map(&:to_s)
          return active_ids.include?(uid.to_s)
        end

        player = active_player
        player.respond_to?(:id) && player.id.to_s == uid.to_s
      rescue StandardError => e
        `console.warn("[Dashboard] action_required_for_me? failed:", #{e.message})`
        false
      end

      def actions_window_storage_key
        game_id = @game.respond_to?(:id) ? @game.id : 'default'
        "dashboard_actions_open_#{game_id}"
      end

      def render_help_button
        is_open = @show_help_overlay == true ||
                  [true, 'true'].include?(Lib::Storage['dashboard_show_help'])

        bg_color = is_open ? '#eff6ff' : '#ffffff'
        text_color = is_open ? '#1d4ed8' : '#334155'
        border_style = is_open ? '2px solid #2563eb' : '1px solid #cbd5e1'

        click_action = lambda do
          new_value = !is_open
          Lib::Storage['dashboard_show_help'] = new_value ? true : nil
          store(:show_help_overlay, new_value)
          update
        end

        h(:button, {
            attrs: {
              id: 'btn-dashboard-help',
              type: 'button',
              title: is_open ? 'Close Dashboard Help' : 'Open Dashboard Help & Guide',
              'aria-pressed': is_open ? 'true' : 'false',
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: bg_color,
              color: text_color,
              border: border_style,
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: {
              click: click_action,
            },
          }, [
            h(:span, {
                style: {
                  fontSize: '1.8rem',
                  lineHeight: '1',
                },
              }, '❓'),
          ])
      end

      def render_help_overlay
        is_open = @show_help_overlay == true ||
                  [true, 'true'].include?(Lib::Storage['dashboard_show_help'])
        return nil unless is_open

        close_handler = lambda do
          Lib::Storage['dashboard_show_help'] = nil
          %x{
      try {
        localStorage.removeItem('dashboard_show_help');
      } catch(e) {}
    }
          store(:show_help_overlay, false)
          update
        end

        h(::View::Game::Dashboard::DashboardHelpOverlay,
          game: @game,
          on_close: close_handler)
      end

      def actions_window_open?
        storage_key = actions_window_storage_key
        stored_open = [true, 'true'].include?(Lib::Storage[storage_key])

        if action_required_for_me?
          @show_actions_window = true
          Lib::Storage[storage_key] = true
          return true
        end

        @show_actions_window == true || stored_open
      end

      def render_action_hub_button
        is_open = actions_window_open?
        is_required = action_required_for_me?

        bg_color =
          if is_required
            '#dcfce7'
          elsif is_open
            '#eff6ff'
          else
            '#ffffff'
          end

        border_style =
          if is_required
            '2px solid #16a34a'
          elsif is_open
            '2px solid #2563eb'
          else
            '1px solid #cbd5e1'
          end

        text_color =
          if is_required
            '#15803d'
          elsif is_open
            '#1d4ed8'
          else
            '#334155'
          end

        click_action = lambda do
          storage_key = actions_window_storage_key
          currently_open = actions_window_open?
          new_value = !currently_open

          @show_actions_window = new_value
          Lib::Storage[storage_key] = new_value

          store(:show_actions_window, new_value)
          update
        end

        title =
          if is_required
            'Actions Hub: action required'
          elsif is_open
            'Close Actions Hub'
          else
            'Open Actions Hub'
          end

        h(:button, {
            attrs: {
              id: 'btn-action-hub',
              type: 'button',
              title: title,
              'aria-pressed': is_open ? 'true' : 'false',
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: bg_color,
              color: text_color,
              border: border_style,
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: is_required ? 'default' : 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: {
              click: click_action,
            },
          }, [
            h(:span, {
                style: {
                  fontSize: '1.8rem',
                  lineHeight: '1',
                },
              }, '⚡'),
          ])
      end

      def render_history_button
        is_open = @show_history_overlay == true

        h(:button, {
            attrs: {
              id: 'btn-history-overlay',
              type: 'button',
              title: is_open ? 'Close Game History' : 'Show Game History',
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: is_open ? '#eff6ff' : '#ffffff',
              color: is_open ? '#1d4ed8' : '#334155',
              border: is_open ? '2px solid #2563eb' : '1px solid #cbd5e1',
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: {
              click: lambda {
                new_val = @show_history_overlay != true
                Lib::Storage['cmd_history_overlay'] = nil
                store(:show_history_overlay, new_val)
                update
              },
            },
          }, [
            h(:span, { style: { fontSize: '1.8rem', lineHeight: '1' } }, '📜'),
          ])
      end

      def render_move_history_button
        is_open = @show_move_history == true

        h(:button, {
            attrs: {
              id: 'btn-move-history-overlay',
              type: 'button',
              title: is_open ? 'Close Last Moves' : 'Show Last Moves',
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: is_open ? '#eff6ff' : '#ffffff',
              color: is_open ? '#1d4ed8' : '#334155',
              border: is_open ? '2px solid #2563eb' : '1px solid #cbd5e1',
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: {
              click: lambda {
                new_val = @show_move_history != true
                Lib::Storage['cmd_dashboard_move_feed_overlay'] = nil
                store(:show_move_history, new_val)
                update
              },
            },
          }, [
            h(:span, { style: { fontSize: '1.8rem', lineHeight: '1' } }, '🕘'),
          ])
      end

      def render_action_window
        return nil unless actions_window_open?

        close_handler = lambda do
          storage_key = actions_window_storage_key

          @show_actions_window = false
          Lib::Storage[storage_key] = false

          store(:show_actions_window, false)
          update
        end

        h(
          ::View::Game::Dashboard::DashboardActionWindow,
          game: @game,
          game_data: @game_data,
          user: @user,
          on_close: close_handler
        )
      end

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

        if step.respond_to?(:active_entities)
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
        corp_id = @par_menu_corp || Lib::Storage['par_menu_corp']
        return nil unless corp_id

        corporation = @game.corporation_by_id(corp_id) || (@game.corporations.find { |c| c.id.to_s == corp_id.to_s } if @game.respond_to?(:corporations))
        return nil unless corporation

        step = @game.round.active_step
        return nil unless step

        cancel_handler = lambda {
          Lib::Storage['par_menu_corp'] = nil
          store(:par_menu_corp, nil)
          update
        }

        h(::View::Game::Dashboard::ParPromptOverlay,
          game: @game,
          step: step,
          entity: active_player || active_entity || @game.current_entity,
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

      def auction_actor(step)
        candidates = []

        candidates.concat(Array(step.active_entities)) if step.respond_to?(:active_entities)

        candidates << step.current_entity if step.respond_to?(:current_entity)
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
      end

      def render_global_auction_overlay
        step = @game.round&.active_step
        return nil unless step

        round_name = @game.round.class.name.to_s
        step_name = step.class.name.to_s

        auction_target = begin
          step.auctioning if step.respond_to?(:auctioning)
        rescue StandardError
          nil
        end

        has_winning_bid = begin
          step.respond_to?(:winning_bid) && !step.winning_bid.nil?
        rescue StandardError
          false
        end

        is_stock_round = (@game.round.respond_to?(:stock?) && @game.round.stock?) || round_name.include?('Stock')

        is_draft_or_auction =
          round_name.match?(/Draft|Auction/i) ||
          step_name.match?(/Draft|Auction|Waterfall|Initial/i) ||
          (step.respond_to?(:draft?) && step.draft?) ||
          (is_stock_round && auction_target && !has_winning_bid)

        return nil unless is_draft_or_auction

        actor = auction_actor(step)
        return nil unless actor

        actions = begin
          @game.round.actions_for(actor) || []
        rescue StandardError
          []
        end

        return nil if is_stock_round && (actions & %w[bid pass]).none?
        return nil unless (actions & %w[bid choose buy_company pass]).any? || auction_target

        available_items =
          begin
            step.respond_to?(:available) ? Array(step.available).compact : []
          rescue StandardError
            []
          end

        direct_purchase_available =
          step.respond_to?(:may_purchase?) &&
          available_items.any? do |item|
            step.may_purchase?(item)
          rescue StandardError
            false
          end

        free_choice_selection =
          !auction_target &&
          !direct_purchase_available &&
          available_items.any? &&
          step.respond_to?(:may_bid?) &&
          available_items.all? do |item|
            step.may_bid?(item)
          rescue StandardError
            false
          end

        use_bidding_overlay =
          (actions.include?('bid') || actions.include?('pass')) &&
          (
            auction_target ||
            (!is_stock_round && step.respond_to?(:visible_corporations)) ||
            free_choice_selection
          )

        if use_bidding_overlay
          h(::View::Game::Dashboard::BiddingOverlay,
            game: @game,
            game_data: @game_data,
            user: @user,
            bidder: actor)
        else
          h(::View::Game::Dashboard::DraftOverlay,
            game: @game,
            game_data: @game_data,
            user: @user,
            actor: actor)
        end
      end

      def render_zoom_controls(panel_id, position_styles = {})
        pid = panel_id.to_s
        button_style = {
          width: '20px',
          height: '20px',
          lineHeight: '16px',
          textAlign: 'center',
          fontSize: '13px',
          fontWeight: 'bold',
          cursor: 'pointer',
          backgroundColor: '#fff',
          border: '1px solid #999',
          borderRadius: '3px',
          padding: '0',
          color: '#333',
        }

        buttons = [
          h(:button, {
              style: button_style,
              attrs: { title: 'Zoom In', type: 'button', onclick: "window.zoomPanel('#{pid}', 1.15); return false;" },
              on: { click: -> { `window.zoomPanel('#{pid}', 1.15)` } },
            }, '+'),
          h(:button, {
              style: button_style,
              attrs: { title: 'Zoom Out', type: 'button', onclick: "window.zoomPanel('#{pid}', 0.85); return false;" },
              on: { click: -> { `window.zoomPanel('#{pid}', 0.85)` } },
            }, '−'),
          h(:button, {
              style: button_style.merge(fontSize: '11px'),
              attrs: { title: 'Reset to Fit', type: 'button', onclick: "window.resetPanelZoom('#{pid}'); return false;" },
              on: { click: -> { `window.resetPanelZoom('#{pid}')` } },
            }, '⟲'),
        ]

        if pid == 'map-panel-bot'
          is_meme_active = meme_revenue_enabled?
          meme_btn_style = button_style.merge(
            backgroundColor: is_meme_active ? '#10b981' : '#ffffff',
            color: is_meme_active ? '#ffffff' : '#333333',
            borderColor: is_meme_active ? '#059669' : '#999999'
          )
          buttons << h(:button, {
                         attrs: { id: 'meme-revenue-toggle-btn', title: 'Toggle large route revenue numbers', type: 'button' },
                         style: meme_btn_style,
                         on: { click: -> { toggle_meme_revenue } },
                       }, '$')
          is_loc_active = location_names_enabled?
          loc_btn_style = button_style.merge(
            backgroundColor: is_loc_active ? '#10b981' : '#ffffff',
            color: is_loc_active ? '#ffffff' : '#333333',
            borderColor: is_loc_active ? '#059669' : '#999999'
          )
          buttons << h(:button, {
                         attrs: {
                           id: 'btn-toggle-location-names',
                           title: is_loc_active ? 'Location names: ON (click to hide)' : 'Location names: OFF (click to show)',
                           type: 'button',
                         },
                         style: loc_btn_style,
                         on: { click: -> { toggle_location_names } },
                       }, 'T')

          is_simple_active = simple_logos_enabled?
          logo_btn_style = button_style.merge(
            backgroundColor: is_simple_active ? '#10b981' : '#ffffff',
            color: is_simple_active ? '#ffffff' : '#333333',
            borderColor: is_simple_active ? '#059669' : '#999999'
          )
          buttons << h(:button, {
                         attrs: {
                           id: 'btn-toggle-simple-logos',
                           title: is_simple_active ? 'Logos: Simple (click for Fancy)' : 'Logos: Fancy (click for Simple)',
                           type: 'button',
                         },
                         style: logo_btn_style,
                         on: { click: -> { toggle_simple_logos } },
                       }, 'L')
        end

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
          }, buttons)
      end

      def current_user_id
        uid = %x((function() {
          var u = #{begin
            @user.to_n
          rescue StandardError
            nil
          end};
          if (u && u.id) return String(u.id);
          try {
            var stored = JSON.parse(localStorage.getItem('user') || '{}');
            if (stored && stored.id) return String(stored.id);
          } catch(e) {}
          return '';
        })())
        (uid || '').to_s
      end

      def fetch_user_games(force = false)
        comp = self
        %x{
          if (window.fetch && (!window._user_games_cache || #{force})) {
            fetch('/api/game/user')
              .then(function(res) { return res.ok ? res.json() : null; })
              .then(function(data) {
                if (data && Array.isArray(data.games)) {
                  window._user_games_cache = data.games;
                  try {
                    localStorage.setItem('all_user_games', JSON.stringify(data.games));
                  } catch(e) {}
                  if (comp && comp.$update) comp.$update();
                }
              })
              .catch(function() {});
          }
        }
      end

      def trigger_random_ai_move
        return unless action_required_for_me?

        View::Game::Dashboard::DashboardAiPlayer.play(@game, @routes) do |act|
          process_action(act)
        end
      end

      def other_games_turn_count
        curr_id = (@game.respond_to?(:id) ? @game.id : @game_data&.dig('id'))&.to_s
        uid = current_user_id
        return 0 if uid.to_s.strip.empty?

        count = %x((function() {
          var games = window._user_games_cache;
          if (!games || !Array.isArray(games)) {
            try {
              games = JSON.parse(localStorage.getItem('all_user_games') || '[]');
            } catch(e) {
              games = [];
            }
          }
          if (!Array.isArray(games)) return 0;

          var total = 0;
          var myId = parseInt(#{uid}, 10);
          var curId = parseInt(#{curr_id}, 10);
          for (var i = 0; i < games.length; i++) {
            var g = games[i];
            if (!g) continue;
            if (parseInt(g.id, 10) === curId) continue;
            var status = String(g.status || '').toLowerCase();
            if (status && status !== 'active') continue;
            if (g.finished_at || g.finished) continue;

            if (g.acting && Array.isArray(g.acting) && g.acting.some(function(a) { return parseInt(a, 10) === myId; })) {
              total++;
            }
          }
          return total;
        })())

        count ? count.to_i : 0
      end

      def render_other_games_overlay
        return nil unless @show_other_games_overlay == true

        close_handler = lambda do
          Lib::Storage['show_other_games_overlay'] = nil

          %x{
      try {
        localStorage.removeItem('show_other_games_overlay');
      } catch(e) {}
    }

          store(:show_other_games_overlay, false)
          update
        end

        h(::View::Game::Dashboard::OtherGamesOverlay,
          game: @game,
          user_id: current_user_id,
          on_close: close_handler)
      end

      def ensure_overlay_safety!
        if defined?(::View::Game::Dashboard::MoveHistoryOverlay)
          klass = ::View::Game::Dashboard::MoveHistoryOverlay
          klass.define_method(:is_chat) { |*_args| false } unless klass.method_defined?(:is_chat)
          klass.define_method(:is_chat?) { |*_args| false } unless klass.method_defined?(:is_chat?)
        end
        if defined?(::View::Game::Dashboard::HistoryOverlay)
          klass = ::View::Game::Dashboard::HistoryOverlay
          klass.define_method(:is_chat) { |*_args| false } unless klass.method_defined?(:is_chat)
          klass.define_method(:is_chat?) { |*_args| false } unless klass.method_defined?(:is_chat?)
        end
      rescue StandardError
        nil
      end

      def render_history_overlay
        return nil unless @show_history_overlay == true

        ensure_overlay_safety!

        close_handler = lambda {
          Lib::Storage['cmd_history_overlay'] = nil
          store(:show_history_overlay, false)
          update
        }

        h(::View::Game::Dashboard::HistoryOverlay,
          game: @game,
          game_data: @game_data,
          on_close: close_handler)
      rescue StandardError => e
        `console.error("HistoryOverlay failed to render:", #{e.message})`
        Lib::Storage['cmd_history_overlay'] = nil
        store(:show_history_overlay, false, skip: true)
        nil
      end

      def render_dashboard_move_feed_overlay
        return nil unless @show_move_history == true

        ensure_overlay_safety!

        close_handler = lambda {
          Lib::Storage['cmd_dashboard_move_feed_overlay'] = nil
          store(:show_move_history, false)
          update
        }

        h(::View::Game::Dashboard::MoveHistoryOverlay,
          game: @game,
          game_data: @game_data,
          on_close: close_handler)
      rescue StandardError => e
        `console.error("MoveHistoryOverlay failed to render:", #{e.message})`
        Lib::Storage['cmd_dashboard_move_feed_overlay'] = nil
        store(:show_move_history, false, skip: true)
        nil
      end

      def sound_enabled?
        val = Lib::Storage['turn_sound_enabled']
        val.nil? || val == true || val == 'true'
      end

      def active_player_index
        p = active_player
        return 0 unless p && @game.respond_to?(:players)

        idx = @game.players.index(p)
        idx || 0
      rescue StandardError
        0
      end

      def game_chat_messages
        uid = current_user_id
        Array(@game&.log).filter_map do |entry|
          raw_msg = entry.respond_to?(:message) ? entry.message : entry
          next unless raw_msg.is_a?(Engine::Action::Message)

          txt = raw_msg.message.to_s.strip
          next if txt.empty?

          sender = raw_msg.entity
          sender_id = sender.respond_to?(:id) ? sender.id.to_s : ''
          sender_name = sender.respond_to?(:name) ? sender.name.to_s : 'Player'

          {
            sender_id: sender_id,
            sender_name: sender_name,
            text: txt,
            mine: !uid.empty? && sender_id == uid,
          }
        end
      rescue StandardError
        []
      end

      def mark_chat_messages_read!(total_count = nil)
        gid = (@game.respond_to?(:id) ? @game.id : 'default').to_s
        count = total_count || game_chat_messages.size
        read_key = "chat_read_count_#{gid}"
        pop_key = "chat_pop_count_#{gid}"

        Lib::Storage[read_key] = count
        Lib::Storage[pop_key] = count
        %x{
          try {
            localStorage.setItem(#{read_key}, String(#{count}));
            localStorage.setItem(#{pop_key}, String(#{count}));
          } catch (e) {}
        }
      end

      def unread_chat_count
        gid = (@game.respond_to?(:id) ? @game.id : 'default').to_s
        msgs = game_chat_messages
        total = msgs.size
        read_key = "chat_read_count_#{gid}"

        is_open = @show_chat_overlay == true ||
                  [true, 'true'].include?(Lib::Storage['dashboard_chat_overlay'])

        if is_open
          mark_chat_messages_read!(total)
          return 0
        end

        stored_lib = Lib::Storage[read_key]
        read_idx = %x{
          (function() {
            try {
              var v = #{stored_lib};
              if (v !== null && v !== undefined && v !== Opal.nil) {
                var n = parseInt(v, 10);
                if (!isNaN(n)) return n;
              }
              var raw = localStorage.getItem(#{read_key});
              if (raw !== null && raw !== undefined) {
                var n2 = parseInt(raw, 10);
                if (!isNaN(n2)) return n2;
              }
            } catch (e) {}
            return -1;
          })()
        }.to_i

        # First time opening this game on this browser: baseline existing history as read
        if read_idx.negative?
          mark_chat_messages_read!(total)
          return 0
        end

        return 0 if total <= read_idx

        unread_slice = msgs[read_idx...total] || []
        unread_from_others = unread_slice.count { |m| !m[:mine] }

        # If the only new messages were sent by me, advance the read pointer automatically
        mark_chat_messages_read!(total) if unread_from_others.zero?

        unread_from_others
      rescue StandardError
        0
      end

      def check_and_pop_new_chat!
        gid = (@game.respond_to?(:id) ? @game.id : 'default').to_s
        msgs = game_chat_messages
        total = msgs.size
        pop_key = "chat_pop_count_#{gid}"

        stored_lib = Lib::Storage[pop_key]
        last_pop = %x{
          (function() {
            try {
              var v = #{stored_lib};
              if (v !== null && v !== undefined && v !== Opal.nil) {
                var n = parseInt(v, 10);
                if (!isNaN(n)) return n;
              }
              var raw = localStorage.getItem(#{pop_key});
              if (raw !== null && raw !== undefined) {
                var n2 = parseInt(raw, 10);
                if (!isNaN(n2)) return n2;
              }
            } catch (e) {}
            return -1;
          })()
        }.to_i

        if last_pop.negative?
          Lib::Storage[pop_key] = total
          `try { localStorage.setItem(#{pop_key}, String(#{total})); } catch(e) {}`
          return
        end

        return if total <= last_pop

        new_msgs = msgs[last_pop...total] || []
        Lib::Storage[pop_key] = total
        `try { localStorage.setItem(#{pop_key}, String(#{total})); } catch(e) {}`

        latest_other = new_msgs.reverse.find { |m| !m[:mine] }
        return unless latest_other

        sender_name = latest_other[:sender_name]
        msg_text = latest_other[:text]
        %x{
          if (window.showChatPopupBubble) {
            window.showChatPopupBubble(#{sender_name}, #{msg_text});
          }
        }
      rescue StandardError
        nil
      end

      def map_wider_than_high?
        return false unless @game && @game.layout && @game.layout != :none

        hexes = @game.hexes || []
        axes_hexes = hexes.reject(&:ignore_for_axes)
        return false if axes_hexes.empty?

        xs = axes_hexes.map(&:x)
        ys = axes_hexes.map(&:y)
        return false if xs.empty? || ys.empty?

        min_x, max_x = xs.minmax
        min_y, max_y = ys.minmax

        cols_count = (max_x - min_x) + 1
        rows_count = (max_y - min_y) + 1

        edge_length = 50
        side_to_side = 87
        gap = 25

        w, h = if @game.layout == :flat
                 [(((cols_count * 1.5) + 0.5) * edge_length) + (2 * gap),
                  (((rows_count / 2.0) + 0.5) * side_to_side) + (2 * gap)]
               else
                 [((((cols_count / 2.0) + 0.5) * side_to_side) + (2 * gap)) + 1,
                  (((rows_count * 1.5) + 0.5) * edge_length) + (2 * gap)]
               end

        w > h
      rescue StandardError
        false
      end

      def render_temporal_hub
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
              padding: '0 0.5rem 0 0',
              boxSizing: 'border-box',
              overflow: 'hidden',
              gap: '0.5rem',
            },
          }, [
          render_active_turn_card,
          h(:div, {
              attrs: { class: 'entity-order-content' },
              style: {
                flex: '1 1 auto',
                minWidth: '0',
                height: '100%',
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
        ].compact)
      end

      def render_chat_button
        is_open = @show_chat_overlay == true ||
                  [true, 'true'].include?(Lib::Storage['dashboard_chat_overlay'])

        unread = unread_chat_count
        has_unread = unread.positive?

        bg_color =
          if has_unread
            '#1d4ed8' # Deep blue when unread messages are waiting
          elsif is_open
            '#eff6ff'
          else
            '#ffffff'
          end

        text_color =
          if has_unread
            '#ffffff'
          elsif is_open
            '#1d4ed8'
          else
            '#334155'
          end

        border_style =
          if has_unread
            '2px solid #1e3a8a'
          elsif is_open
            '2px solid #2563eb'
          else
            '1px solid #cbd5e1'
          end

        box_shadow =
          if has_unread
            '0 0 12px rgba(29, 78, 216, 0.75), 0 2px 5px rgba(0, 0, 0, 0.22)'
          else
            '0 2px 5px rgba(0, 0, 0, 0.18)'
          end

        click_action = lambda do
          new_value = !is_open

          Lib::Storage['dashboard_chat_overlay'] =
            new_value ? true : nil

          if new_value
            mark_chat_messages_read!
            %x{
              var existingBubble = document.getElementById('dashboard-chat-popup-bubble');
              if (existingBubble) existingBubble.remove();
            }
          end

          store(:show_chat_overlay, new_value)
          update
        end

        badge_el = if has_unread
                     h(:span, {
                         style: {
                           position: 'absolute',
                           top: '-6px',
                           right: '-6px',
                           backgroundColor: '#dc2626',
                           color: '#ffffff',
                           fontSize: '0.82rem',
                           fontWeight: 'bold',
                           borderRadius: '12px',
                           minWidth: '22px',
                           height: '22px',
                           lineHeight: '18px',
                           textAlign: 'center',
                           padding: '0 4px',
                           border: '2px solid #ffffff',
                           boxSizing: 'border-box',
                           boxShadow: '0 2px 4px rgba(0,0,0,0.25)',
                         },
                       }, unread.to_s)
                   end

        btn_title =
          if has_unread
            "#{unread} unread chat message(s) — click to open"
          elsif is_open
            'Close Player Chat'
          else
            'Open Player Chat'
          end

        h(:button, {
            attrs: {
              id: 'btn-dashboard-chat',
              type: 'button',
              title: btn_title,
              'aria-pressed': is_open ? 'true' : 'false',
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: bg_color,
              color: text_color,
              border: border_style,
              boxShadow: box_shadow,
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: {
              click: click_action,
            },
          }, [
            h(:span, {
                style: {
                  fontSize: '1.8rem',
                  lineHeight: '1',
                },
              }, '💬'),
            badge_el,
          ].compact)
      end

      def render_chat_overlay
        is_open = @show_chat_overlay == true ||
                  [true, 'true'].include?(Lib::Storage['dashboard_chat_overlay'])

        return nil unless is_open

        mark_chat_messages_read!

        close_handler = lambda do
          mark_chat_messages_read!
          Lib::Storage['dashboard_chat_overlay'] = nil
          store(:show_chat_overlay, false)
          update
        end

        h(::View::Game::Dashboard::ChatOverlay,
          game: @game,
          game_data: @game_data,
          user: @user,
          on_close: close_handler)
      end

      def render_top_nav_utility_cluster
        h(:div, {
            attrs: { id: 'top-nav-utility-cluster' },
            style: {
              position: 'fixed',
              right: '16px',
              height: '48px',
              display: 'flex',
              flexDirection: 'row',
              alignItems: 'center',
              gap: '8px',
              zIndex: 99_999,
            },
          }, [
            render_action_hub_button,
            render_history_button,
            render_move_history_button,
            render_other_games_button,
            render_sound_toggle_button,
            render_chat_button,
            render_help_button,
            ].compact)
      end

      def render_other_games_button
        turns_count = other_games_turn_count
        has_turns = turns_count.positive?

        bg_color = has_turns ? '#16a34a' : '#ffffff'
        text_color = has_turns ? '#ffffff' : '#334155'
        border_style = has_turns ? '2px solid #15803d' : '1px solid #cbd5e1'
        btn_title = has_turns ? "#{turns_count} other game(s) waiting on your turn" : 'View active games list'

        click_action = lambda do
          val = @show_other_games_overlay != true
          Lib::Storage['show_other_games_overlay'] = val ? true : nil
          %x{
            if (!#{val}) {
              try {
                localStorage.removeItem('show_other_games_overlay');
              } catch(e) {}
            }
          }
          store(:show_other_games_overlay, val)
          fetch_user_games(true)
          update
        end

        badge_el = if has_turns
                     h(:span, {
                         style: {
                           position: 'absolute',
                           top: '-6px',
                           right: '-6px',
                           backgroundColor: '#dc2626',
                           color: '#ffffff',
                           fontSize: '0.85rem',
                           fontWeight: 'bold',
                           borderRadius: '12px',
                           minWidth: '22px',
                           height: '22px',
                           lineHeight: '20px',
                           textAlign: 'center',
                           padding: '0 4px',
                           border: '2px solid #ffffff',
                           boxSizing: 'border-box',
                         },
                       }, turns_count.to_s)
                   end

        h(:button, {
            attrs: {
              id: 'btn-other-games',
              type: 'button',
              title: btn_title,
            },
            style: {
              position: 'relative',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: bg_color,
              color: text_color,
              border: border_style,
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'all 0.2s ease',
            },
            on: { click: click_action },
          }, [
h(:span, { style: { fontSize: '1.8rem', lineHeight: '1' } }, '🎮'),
badge_el,
          ].compact)
      end

      def render_sound_toggle_button
        enabled = sound_enabled?
        player_name = (active_player&.name || @user&.dig('name') || @user&.dig(:name) || 'directorofcompanies').to_s

        toggle_action = lambda do
          new_val = !sound_enabled?
          Lib::Storage['turn_sound_enabled'] = new_val
          %x{
            try {
              localStorage.setItem('turn_sound_enabled', #{new_val});
              if (#{new_val} && window.playTurnBeep) {
                window.playTurnBeep(#{player_name});
              }
            } catch(e) {}
          }
          update
        end

        h(:button, {
            attrs: {
              id: 'btn-sound-toggle',
              type: 'button',
              title: enabled ? 'Turn sound alert: ON (click to mute)' : 'Turn sound alert: OFF (click to unmute)',
            },
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: '48px',
              height: '48px',
              minWidth: '48px',
              padding: '0',
              flexShrink: '0',
              borderRadius: '8px',
              backgroundColor: enabled ? '#f0fdf4' : '#ffffff',
              border: enabled ? '2px solid #16a34a' : '1px solid #cbd5e1',
              boxShadow: '0 2px 5px rgba(0, 0, 0, 0.18)',
              cursor: 'pointer',
              lineHeight: '1',
              zIndex: 10,
              transition: 'background-color 0.2s ease, border-color 0.2s ease',
            },
            on: { click: toggle_action },
          }, [
            h(:span, {
                style: {
                  fontSize: '1.8rem',
                  lineHeight: '1',
                  filter: enabled ? 'none' : 'grayscale(100%) opacity(35%)',
                  transition: 'filter 0.2s ease',
                },
              }, '🎵'),
          ])
      end

      def dismiss_all_overlays
        any_closed = false

        # 1. Game History HUD & Live Action Reset
        history_active = @show_history_overlay == true ||
                         Lib::Storage['cmd_history_overlay'] ||
                         (defined?(Lib::Params) && Lib::Params['action']) ||
                         `window.location.search.indexOf('action=') !== -1`

        if history_active
          @show_history_overlay = false
          Lib::Storage['cmd_history_overlay'] = nil
          store(:show_history_overlay, false)

          Lib::Params['action'] = nil if defined?(Lib::Params)

          %x{
            try {
              var u = new URL(window.location.href);
              if (u.searchParams.has('action')) {
                u.searchParams.delete('action');
                var cleanPath = u.pathname + (u.searchParams.toString() ? '?' + u.searchParams.toString() : '') + u.hash;
                if (window.history && window.history.replaceState) {
                  window.history.replaceState(null, '', cleanPath);
                }
              }
            } catch(e) {}
          }

          begin
            curr_route = `window.location.pathname + window.location.search + window.location.hash`
            new_route = defined?(Lib::Params) ? Lib::Params.add(curr_route, 'action', nil) : curr_route
            store(:app_route, new_route)
          rescue StandardError
          end

          any_closed = true
        end

        # 2. Move Feed / Last Moves Overlay
        if @show_move_history == true || Lib::Storage['cmd_dashboard_move_feed_overlay']
          @show_move_history = false
          Lib::Storage['cmd_dashboard_move_feed_overlay'] = nil
          store(:show_move_history, false)
          any_closed = true
        end

        # 3. Dashboard Help Overlay
        if @show_help_overlay == true || [true, 'true'].include?(Lib::Storage['dashboard_show_help'])
          @show_help_overlay = false
          Lib::Storage['dashboard_show_help'] = nil
          %x{
            try {
              localStorage.removeItem('dashboard_show_help');
            } catch(e) {}
          }
          store(:show_help_overlay, false)
          any_closed = true
        end

        # 4. Other Active Games List
        if @show_other_games_overlay == true || Lib::Storage['show_other_games_overlay']
          @show_other_games_overlay = false
          Lib::Storage['show_other_games_overlay'] = nil
          %x{
            try {
              localStorage.removeItem('show_other_games_overlay');
            } catch(e) {}
          }
          store(:show_other_games_overlay, false)
          any_closed = true
        end

        # 5. Table Chat Overlay & Popup Bubbles
        if @show_chat_overlay == true || [true, 'true'].include?(Lib::Storage['dashboard_chat_overlay'])
          @show_chat_overlay = false
          mark_chat_messages_read!
          Lib::Storage['dashboard_chat_overlay'] = nil
          store(:show_chat_overlay, false)
          %x{
            var bubble = document.getElementById('dashboard-chat-popup-bubble');
            if (bubble) bubble.remove();
          }
          any_closed = true
        end

        # 6. Phases & Train Durability Table
        if [true, 'true'].include?(Lib::Storage['dashboard_show_phases'])
          Lib::Storage['dashboard_show_phases'] = 'false'
          %x{
            try {
              localStorage.setItem('dashboard_show_phases', 'false');
            } catch (e) {}
          }
          any_closed = true
        end

        # 7. Remaining Tiles Manifest
        if Lib::Storage['dashboard_tile_manifest']
          Lib::Storage['dashboard_tile_manifest'] = false
          any_closed = true
        end

        # 8. Par Selection Matrix
        if @par_menu_corp || Lib::Storage['par_menu_corp']
          @par_menu_corp = nil
          Lib::Storage['par_menu_corp'] = nil
          store(:par_menu_corp, nil)
          any_closed = true
        end

        # 9. Manual Route Selection HUD
        if Lib::Storage['cmd_manual_routes'] || [true, 'true'].include?(Lib::Storage['show_manual_routes'])
          Lib::Storage['cmd_manual_routes'] = false
          store(:show_manual_routes, false)
          store(:selected_route, nil)
          any_closed = true
        end

        # 10. Voluntary Action Hub Drawer
        storage_key = actions_window_storage_key
        if (@show_actions_window == true || [true, 'true'].include?(Lib::Storage[storage_key])) && !action_required_for_me?
          @show_actions_window = false
          Lib::Storage[storage_key] = false
          store(:show_actions_window, false)
          any_closed = true
        end

        update if any_closed
        any_closed
      end

      def render_phases_overlay
        val = Lib::Storage['dashboard_show_phases']
        is_open = [true, 'true'].include?(val)
        return nil unless is_open

        close_handler = lambda {
          Lib::Storage['dashboard_show_phases'] = 'false'
          %x{
            try {
              localStorage.setItem('dashboard_show_phases', 'false');
            } catch (e) {}
          }
          update
        }

        h(::View::Game::Dashboard::PhasesOverlay,
          game: @game,
          on_close: close_handler)
      end

      def animate_last_action(action)
        return unless action

        type = if action.is_a?(Hash)
                 action['type'] || action[:type]
               elsif action.respond_to?(:type)
                 action.type
               end
        return unless type.to_s == 'pass'

        entity_id = if action.is_a?(Hash)
                      action['entity'] || action[:entity]
                    elsif action.respond_to?(:entity)
                      ent = action.entity
                      ent.respond_to?(:id) ? ent.id : ent
                    end

        round = @game.round
        is_stock = (round.respond_to?(:stock?) && round.stock?) ||
                   round.class.name.to_s.include?('Stock')
        return unless is_stock

        player = if action.respond_to?(:entity) && action.entity.respond_to?(:player?) && action.entity.player?
                   action.entity
                 else
                   @game.players.find { |p| p.id.to_s == entity_id.to_s || p.name.to_s == entity_id.to_s }
                 end

        return unless player

        p_id = player.id.to_s
        p_name = player.name.to_s
        %x(
          if (window.showPassBubble) {
            window.showPassBubble(#{p_id}, #{p_name});
          }
        )
      end

      def render_active_turn_card
        player = active_player
        player_label = if player.respond_to?(:name) && player&.name
                         player.name.to_s
                       elsif player.respond_to?(:id) && player&.id
                         player.id.to_s
                       else
                         ''
                       end

        if player_label.empty?
          entity = active_entity
          if entity.respond_to?(:player) && entity.player&.name
            player_label = entity.player.name.to_s
          elsif entity.respond_to?(:owner) && entity.owner&.name
            player_label = entity.owner.name.to_s
          elsif entity.respond_to?(:name) && entity&.name
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
            if simple_logos_enabled?
              (acting_corp.respond_to?(:simple_logo) && acting_corp.simple_logo) ||
                (acting_corp.respond_to?(:logo) && acting_corp.logo)
            else
              (acting_corp.respond_to?(:logo) && acting_corp.logo) ||
                (acting_corp.respond_to?(:simple_logo) && acting_corp.simple_logo)
            end
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
                              width: '26px',
                              height: '26px',
                              minWidth: '26px',
                              borderRadius: '50%',
                              backgroundColor: corp_color,
                              border: '1.5px solid #ffffff',
                              boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
                              display: 'flex',
                              alignItems: 'center',
                              justifyContent: 'center',
                              overflow: 'hidden',
                              flexShrink: '0',
                              marginRight: '0.45rem',
                            },
                          }, [marker_content])
        end

        # Player identity is information. Turn ownership is shown by a small
        # green status mark rather than recolouring the whole information block.
        card_bg = '#ffffff'
        card_text_color = is_my_turn ? '#0f172a' : '#64748b'
        border_right = '1px solid #cbd5e1'

        card_children = []
        if is_my_turn
          card_children << h(:span, {
                               attrs: { title: 'Your turn' },
                               style: {
                                 width: '6px',
                                 height: '1.55rem',
                                 borderRadius: '3px',
                                 backgroundColor: '#16a34a',
                                 flexShrink: '0',
                                 marginRight: '0.5rem',
                               },
                             })
        end
        card_children << corp_marker if corp_marker
        card_children << h(:span, {
                             style: {
                               whiteSpace: 'nowrap',
                               overflow: 'hidden',
                               textOverflow: 'ellipsis',
                               fontWeight: '700',
                             },
                           }, player_label)

        h(:div, {
            attrs: {
              class: 'active-turn-card',
              title: is_my_turn ? "Active: #{player_label} (Your turn)" : "Active: #{player_label}",
            },
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'flex-start',
              flex: '0 0 auto',
              alignSelf: 'stretch',
              height: '100%',
              minWidth: '9.5rem',
              maxWidth: '13.5rem',
              padding: '0 0.85rem',
              borderTopLeftRadius: '0',
              borderBottomLeftRadius: '0',
              borderTopRightRadius: '0',
              borderBottomRightRadius: '0',
              backgroundColor: card_bg,
              color: card_text_color,
              border: 'none',
              borderRight: border_right,
              boxShadow: 'none',
              fontSize: '1rem',
              fontWeight: 'bold',
              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
              letterSpacing: '0.3px',
              lineHeight: '1',
              boxSizing: 'border-box',
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              cursor: 'default',
              userSelect: 'none',
              transition: 'background-color 0.25s ease, color 0.25s ease',
              flexShrink: '0',
            },
          }, card_children)
      end

      def game_title
        title = nil
        title ||= @game_data['title'] || @game_data[:title] if defined?(@game_data) && @game_data
        if (!title || title.to_s.strip.empty?) && @game
          if @game.class.const_defined?(:GAME_TITLE)
            title = @game.class::GAME_TITLE
          elsif @game.class.const_defined?(:TITLE)
            title = @game.class::TITLE
          elsif @game.respond_to?(:title) && @game.title && @game.title.to_s.strip.downcase != 'game'
            title = @game.title
          end

          if !title || title.to_s.strip.empty? || title.to_s.strip.downcase == 'game'
            parts = @game.class.name.to_s.split('::')
            mod = parts.reverse.find { |p| p =~ /^G\d+/i } || (parts[-2] if parts.size > 1)
            title = mod ? mod.sub(/^G/i, '') : parts.last
          end
        end
        title.to_s
      end

      # Tile colours belong with the map: physical-looking hexes show the
      # colours currently available in the phase without colouring the round label.
      def render_map_phase_indicator
        phase = @game.respond_to?(:phase) ? @game.phase : nil
        return nil unless phase

        raw_tiles = if phase.respond_to?(:tiles) && phase.tiles
                      Array(phase.tiles)
                    elsif phase.respond_to?(:color) && phase.color
                      [phase.color]
                    else
                      []
                    end
        tile_colors = raw_tiles.map { |c| c.to_s.downcase }.uniq
        tile_colors.select! { |c| %w[yellow green brown gray grey].include?(c) }
        return nil if tile_colors.empty?

        fills = { 'yellow' => '#f6e652', 'green' => '#7fbf55', 'brown' => '#a66a3f', 'gray' => '#9ca3af', 'grey' => '#9ca3af' }
        hexes = tile_colors.map do |name|
          h(:span, {
              attrs: { title: "#{name.capitalize} tiles available", 'aria-label': "#{name.capitalize} tiles available" },
              style: {
                width: '25px',
                height: '28px',
                display: 'inline-flex',
                flexShrink: '0',
                backgroundColor: fills[name],
                clipPath: 'polygon(25% 6%, 75% 6%, 100% 50%, 75% 94%, 25% 94%, 0 50%)',
                boxShadow: 'inset 0 0 0 1px rgba(15,23,42,0.45)',
              },
            })
        end
        h(:div, {
            attrs: { id: 'map-phase-indicator', title: 'Tile colours currently available' },
            style: {
              position: 'absolute',
              top: '6px',
              # // --- START FIX ---
              left: '6px',
              # // --- END FIX ---
              zIndex: 30,
              display: 'inline-flex',
              alignItems: 'center',
              gap: '6px',
              padding: '2px 6px',
              backgroundColor: 'rgba(255,255,255,0.90)',
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
            },
          }, hexes)
      end

      def location_names_enabled?
        setting_for(:show_location_names, @game)
      end

      def toggle_location_names
        toggle_setting(:show_location_names, @game)
        update
      end

      def simple_logos_enabled?
        setting_for(:simple_logos, @game)
      end

      def toggle_simple_logos
        toggle_setting(:simple_logos, @game)
        update
      end

      def render
        # Allow finished games to mount the complete dashboard, attach window._dashboardVisualizer,
        # and render the navigation cluster for history scrubbing and post-game review.
        #

        last_action = @game.respond_to?(:raw_actions) && @game.raw_actions ? @game.raw_actions.last : nil
        last_action ||= @game_data['actions']&.last if @game_data && @game_data['actions']
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

        corp_ribbon_text = (!is_stock && acting_corp.respond_to?(:name) ? acting_corp.name.to_s : '')
        player_ribbon_text = begin
          p = active_player
          if p.respond_to?(:name)
            p.name.to_s
          else
            (p.respond_to?(:id) ? p.id.to_s : '')
          end
        rescue StandardError
          ''
        end

        active_gid = (@game.respond_to?(:id) ? @game.id : 'default').to_s
        if Lib::Storage['last_active_dashboard_gid'] != active_gid
          Lib::Storage['last_active_dashboard_gid'] = active_gid
          Lib::Storage['show_other_games_overlay'] = nil
          Lib::Storage['cmd_dashboard_move_feed_overlay'] = nil
          Lib::Storage['cmd_history_overlay'] = nil
          store(:show_move_history, false, skip: true)
          store(:show_history_overlay, false, skip: true)
          `try { localStorage.removeItem('show_other_games_overlay'); } catch(e) {}`
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
                        # `window.scrollTo(0, 0)`
                        `document.body.style.overflow = ''`
                        `document.body.style.overflowX = 'hidden'`
                        `document.body.style.overflowY = 'auto'`
                        fetch_user_games(false)

                        comp = self
                        %x(
                    if (window._other_games_timer) {
                      clearInterval(window._other_games_timer);
                    }
                    window._other_games_timer = setInterval(function() {
                      if (window.fetch) {
                        fetch('/api/game/user')
                          .then(function(res) { return res.ok ? res.json() : null; })
                          .then(function(data) {
                            if (data && Array.isArray(data.games)) {
                              window._user_games_cache = data.games;
                              try {
                                localStorage.setItem('all_user_games', JSON.stringify(data.games));
                              } catch(e) {}
                              if (comp && comp.$update) comp.$update();
                            }
                          }).catch(function() {});
                      }
                    }, 60000);
                  )

                        `document.body.style.margin = '0'`
                        `document.body.style.padding = '0'`
                        `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: 'visible', padding: '0', margin: '0', maxWidth: '100vw', width: '100vw', minHeight: '100vh', height: 'auto'})`
                        `document.getElementById('game') && Object.assign(document.getElementById('game').style, { display: 'flex', flexDirection: 'column', overflow: 'visible', width: '100vw', height: 'calc(100dvh - 36px)', maxWidth: '100vw', maxHeight: 'calc(100dvh - 36px)' })`

                        %x(
                    window._dashboardVisualizer = comp;
                    window.positionDashboardButtons = function() {
  var menu = document.getElementById('game_menu');
  var cluster = document.getElementById('top-nav-utility-cluster');

  if (!menu || !cluster) return;

  var r = menu.getBoundingClientRect();

  cluster.style.top =
    Math.round(
      r.top + ((r.height - cluster.offsetHeight) / 2)
    ) + 'px';

  cluster.style.right = '16px';
};


setTimeout(window.positionDashboardButtons, 300);

window.addEventListener('resize', window.positionDashboardButtons);
window.addEventListener('scroll', window.positionDashboardButtons, { passive: true });


if (window._dashboardAiKeyHandler) {
                      window.removeEventListener('keydown', window._dashboardAiKeyHandler, true);
                      window.removeEventListener('keydown', window._dashboardAiKeyHandler, false);
                    }
                    window._dashboardAiKeyHandler = function(e) {
                      if (e.key === 'Escape' || e.key === 'Esc' || e.keyCode === 27) {
                        if (e.target && e.target.blur) {
                          e.target.blur();
                        }
                        if (comp && comp.$dismiss_all_overlays) {
                          var dismissed = comp.$dismiss_all_overlays();
                          if (dismissed) {
                            if (e.preventDefault) e.preventDefault();
                            if (e.stopPropagation) e.stopPropagation();
                          }
                        }
                        return;
                      }


if (e.key !== 'r' && e.key !== 'R') return;
if (e.ctrlKey || e.metaKey || e.altKey) return;

/*
 * One physical R press must execute exactly one AI action.
 *
 * e.repeat catches the browser's normal key-repeat behaviour.
 * _dashboardAiRDown provides a second short guard against the
 * same physical key press being dispatched twice.
 */
if (e.repeat) return;
if (window._dashboardAiRDown) return;

var tag = (e.target && e.target.tagName ? e.target.tagName : '').toUpperCase();
if (
  tag === 'INPUT' ||
  tag === 'TEXTAREA' ||
  tag === 'SELECT' ||
  (e.target && e.target.isContentEditable)
) {
  return;
}

window._dashboardAiRDown = true;

setTimeout(function() {
  window._dashboardAiRDown = false;
}, 150);

if (comp && comp.$trigger_random_ai_move) {
  if (e.preventDefault) e.preventDefault();
  if (e.stopPropagation) e.stopPropagation();
  if (e.stopImmediatePropagation) e.stopImmediatePropagation();

  comp.$trigger_random_ai_move();
}



                    };
                    window.addEventListener('keydown', window._dashboardAiKeyHandler, true);

                    window.toggleDashboardPhases = function() {
                      var cur = localStorage.getItem('dashboard_show_phases') === 'true';
                      var next = !cur;
                      localStorage.setItem('dashboard_show_phases', next ? 'true' : 'false');
                      if (comp && comp.$update) {
                        comp.$update();
                      }
                    };
                  )

                        %x(
                    window.playTurnBeep = function(playerName) {
                      try {
                        var enabled = localStorage.getItem('turn_sound_enabled');
                        if (enabled === 'false' || enabled === false) return;

                        var AudioCtx = window.AudioContext || window.webkitAudioContext;
                        if (!AudioCtx) return;
                        if (!window._turnAudioCtx) {
                          window._turnAudioCtx = new AudioCtx();
                        }
                        var ctx = window._turnAudioCtx;
                        if (ctx.state === 'suspended') {
                          ctx.resume();
                        }

                        var str = String(playerName || 'player').trim().toLowerCase();
                        var hash = 2166136261;
                        for (var i = 0; i < str.length; i++) {
                          hash ^= str.charCodeAt(i);
                          hash = Math.imul(hash, 16777619);
                        }
                        hash = hash >>> 0;

                        var pentatonic = [
                          329.63, 392.00, 440.00, 493.88, 523.25,
                          587.33, 659.25, 783.99, 880.00, 987.77, 1046.50
                        ];

                        var rootIdx = hash % 6;
                        var hRem = Math.floor(hash / 6);
                        var step = (hRem % 4) + 2;
                        var secondIdx = rootIdx + step;
                        hRem = Math.floor(hRem / 4);

                        var f1 = pentatonic[rootIdx];
                        var f2 = pentatonic[secondIdx];

                        var rhythms = [
                          { d1: 0.09, gap: 0.02, d2: 0.13 },
                          { d1: 0.05, gap: 0.015, d2: 0.16 },
                          { d1: 0.04, gap: 0.01, d2: 0.18 },
                          { d1: 0.11, gap: 0.025, d2: 0.10 }
                        ];
                        var rhythm = rhythms[hRem % 4];
                        hRem = Math.floor(hRem / 4);

                        var overtoneGain = 0.10 + ((hRem % 4) * 0.05);

                        var now = ctx.currentTime;
                        var playTone = function(freq, start, duration) {
                          var osc1 = ctx.createOscillator();
                          var osc2 = ctx.createOscillator();
                          var mainGain = ctx.createGain();
                          var overtoneGainNode = ctx.createGain();

                          osc1.type = 'sine';
                          osc1.frequency.setValueAtTime(freq, start);

                          osc2.type = 'sine';
                          osc2.frequency.setValueAtTime(freq * 2, start);

                          overtoneGainNode.gain.setValueAtTime(overtoneGain, start);

                          osc1.connect(mainGain);
                          osc2.connect(overtoneGainNode);
                          overtoneGainNode.connect(mainGain);

                          mainGain.gain.setValueAtTime(0.0001, start);
                          mainGain.gain.exponentialRampToValueAtTime(0.18, start + 0.012);
                          mainGain.gain.exponentialRampToValueAtTime(0.0001, start + duration);

                          mainGain.connect(ctx.destination);

                          osc1.start(start);
                          osc2.start(start);
                          osc1.stop(start + duration);
                          osc2.stop(start + duration);
                        };

                        playTone(f1, now, rhythm.d1);
                        playTone(f2, now + rhythm.d1 + rhythm.gap, rhythm.d2);
                      } catch (e) {}
                    };

                    var unlockAudio = function() {
                      try {
                        if (!window._turnAudioCtx) {
                          var AudioCtx = window.AudioContext || window.webkitAudioContext;
                          if (AudioCtx) window._turnAudioCtx = new AudioCtx();
                        }
                        if (window._turnAudioCtx && window._turnAudioCtx.state === 'suspended') {
                          window._turnAudioCtx.resume();
                        }
                      } catch(e) {}
                      window.removeEventListener('pointerdown', unlockAudio);
                      window.removeEventListener('keydown', unlockAudio);
                    };
                    window.addEventListener('pointerdown', unlockAudio, { once: true });
                    window.addEventListener('keydown', unlockAudio, { once: true });

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
                      '  text-decoration: none !important; display: inline-flex !important; align-items: center !important; ' +
                      '  border-radius: 3px !important; transition: background-color 0.15s ease !important; ' +
                      '} ' +
                      '#game > div:first-child a.active, #game > div:first-child .active { ' +
                      '  font-weight: 700 !important; ' +
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
                      '.ribbon-opponent-turn { background-color: rgba(30, 41, 59, 0.92) !important; color: #f8fafc !important; border: 1px solid #475569 !important; } ' +
                      '.pass-bubble-popup { ' +
                      '  position: fixed !important; z-index: 999999 !important; pointer-events: none !important; ' +
                      '  display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; ' +
                      '  transform: translate(-50%, -100%) !important; ' +
                      '} ' +
                      '.pass-bubble-body { ' +
                      '  position: relative !important; background-color: #ffffff !important; color: #334155 !important; ' +
                      '  border: 1.5px solid #64748b !important; border-radius: 12px !important; padding: 2px 9px !important; ' +
                      '  font-family: "Helvetica Neue", Helvetica, Arial, sans-serif !important; font-size: 0.75rem !important; ' +
                      '  font-weight: 700 !important; letter-spacing: 0.3px !important; line-height: 1.2 !important; white-space: nowrap !important; ' +
                      '  box-shadow: 0 3px 10px rgba(0, 0, 0, 0.16) !important; ' +
                      '  animation: pass-bubble-anim 1.8s cubic-bezier(0.16, 1, 0.3, 1) forwards !important; ' +
                      '} ' +
                      '.pass-bubble-body::after { ' +
                      '  content: "" !important; position: absolute !important; bottom: -5px !important; left: 50% !important; ' +
                      '  transform: translateX(-50%) !important; width: 0 !important; height: 0 !important; ' +
                      '  border-left: 5px solid transparent !important; border-right: 5px solid transparent !important; ' +
                      '  border-top: 5px solid #64748b !important; animation: pass-tail-fade 1.8s forwards !important; ' +
                      '} ' +
                      '.pass-bubble-body::before { ' +
                      '  content: "" !important; position: absolute !important; bottom: -3px !important; left: 50% !important; ' +
                      '  transform: translateX(-50%) !important; width: 0 !important; height: 0 !important; ' +
                      '  border-left: 4px solid transparent !important; border-right: 4px solid transparent !important; ' +
                      '  border-top: 4px solid #ffffff !important; z-index: 1 !important; animation: pass-tail-fade 1.8s forwards !important; ' +
                      '} ' +
                      '@keyframes pass-bubble-anim { ' +
                      '  0% { opacity: 0; transform: translateY(6px) scale(0.5); } ' +
                      '  18% { opacity: 1; transform: translateY(-2px) scale(1.06); } ' +
                      '  28% { opacity: 1; transform: translateY(0) scale(1); } ' +
                      '  68% { opacity: 1; transform: translateY(0) scale(1); filter: blur(0px); } ' +
                      '  85% { opacity: 0.7; transform: translateY(-8px) scale(1.18); filter: blur(2px); border-radius: 18px; } ' +
                      '  100% { opacity: 0; transform: translateY(-16px) scale(1.4); filter: blur(6px); border-radius: 24px; } ' +
                      '} ' +
                      '@keyframes pass-tail-fade { ' +
                      '  0%, 65% { opacity: 1; } ' +
                      '  80%, 100% { opacity: 0; } ' +
                      '} ' +
                      '.pass-cloud-puff { ' +
                      '  position: absolute !important; border-radius: 50% !important; ' +
                      '  background: radial-gradient(circle, rgba(255, 255, 255, 0.95) 0%, rgba(226, 232, 240, 0.8) 60%, rgba(203, 213, 225, 0) 100%) !important; ' +
                      '  opacity: 0 !important; pointer-events: none !important; ' +
                      '} ' +
                      '.puff-1 { width: 16px !important; height: 16px !important; top: 2px !important; left: -4px !important; animation: puff-anim-1 1.8s ease-out forwards !important; } ' +
                      '.puff-2 { width: 22px !important; height: 22px !important; top: -8px !important; left: 50% !important; transform: translateX(-50%) !important; animation: puff-anim-2 1.8s ease-out forwards !important; } ' +
                      '.puff-3 { width: 17px !important; height: 17px !important; top: 1px !important; right: -5px !important; animation: puff-anim-3 1.8s ease-out forwards !important; } ' +
                      '.puff-4 { width: 12px !important; height: 12px !important; top: -12px !important; left: 30% !important; animation: puff-anim-4 1.8s ease-out forwards !important; } ' +
                      '@keyframes puff-anim-1 { ' +
                      '  0%, 65% { opacity: 0; transform: translate(0, 0) scale(0.3); } ' +
                      '  78% { opacity: 0.85; transform: translate(-8px, -6px) scale(1.1); filter: blur(1px); } ' +
                      '  100% { opacity: 0; transform: translate(-14px, -12px) scale(1.5); filter: blur(4px); } ' +
                      '} ' +
                      '@keyframes puff-anim-2 { ' +
                      '  0%, 65% { opacity: 0; transform: translate(-50%, 0) scale(0.3); } ' +
                      '  78% { opacity: 0.9; transform: translate(-50%, -10px) scale(1.2); filter: blur(1px); } ' +
                      '  100% { opacity: 0; transform: translate(-50%, -20px) scale(1.6); filter: blur(5px); } ' +
                      '} ' +
                      '@keyframes puff-anim-3 { ' +
                      '  0%, 65% { opacity: 0; transform: translate(0, 0) scale(0.3); } ' +
                      '  78% { opacity: 0.85; transform: translate(8px, -6px) scale(1.1); filter: blur(1px); } ' +
                      '  100% { opacity: 0; transform: translate(14px, -12px) scale(1.5); filter: blur(4px); } ' +
                      '} ' +
                      '@keyframes puff-anim-4 { ' +
                      '  0%, 68% { opacity: 0; transform: translate(0, 0) scale(0.2); } ' +
                      '  82% { opacity: 0.8; transform: translate(-4px, -12px) scale(1); filter: blur(1px); } ' +
                      '  100% { opacity: 0; transform: translate(-8px, -22px) scale(1.4); filter: blur(4px); } ' +
                      '} ' +
                      '#panel-market { isolation: isolate; } ' +
                      '.hover-overlay, #market-hover-overlay, .market-hover-overlay, ' +
                      '.stock-market-tooltip, .market-tooltip, [class*="hover-overlay"], [id*="hover-overlay"] { ' +
                      '  z-index: 999999 !important; pointer-events: none !important; ' +
                      '} ' +
                      '#panel-market svg g.marker, #panel-market svg g.token, ' +
                      '#panel-market .market-marker, #panel-market .token, ' +
                      '#panel-market [class*="marker"], #panel-market [class*="token"], ' +
                      '#panel-market .stock-market-token, #panel-market [id^="stock-token-"] { ' +
                      '  pointer-events: auto !important; ' +
                      '  cursor: pointer !important; ' +
                      '}';

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
                          if (!isInitial && window.playTurnBeep) {
                            window.playTurnBeep(pName);
                          }
                        } else {
                          frame.classList.add('frame-opponent-turn');
                        }
                      }

                      var isPlayerTransition = !isInitial && pName && (window._lastTurnPlayer !== pName);
                      window._lastTurnPlayer = pName;

                      if (isPlayerTransition) {
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

                    window.showPassBubble = function(playerId, playerName) {
                      var selector = '#status-player-' + CSS.escape(String(playerId)) +
                                     ', [data-player-id="' + CSS.escape(String(playerId)) + '"]';
                      var target = null;
                      try {
                        target = document.querySelector(selector);
                      } catch(e) {
                        target = document.getElementById('status-player-' + playerId);
                      }
                      if (!target && playerName) {
                        var headers = document.querySelectorAll('#spreadsheet th.header-player, th.header-player');
                        for (var i = 0; i < headers.length; i++) {
                          if (headers[i].textContent.trim().indexOf(playerName) !== -1) {
                            target = headers[i];
                            break;
                          }
                        }
                      }
                      if (!target) return;

                      var rect = target.getBoundingClientRect();
                      if (rect.width === 0 && rect.height === 0) return;

                      var allBubbles = document.querySelectorAll('.pass-bubble-popup');
                      for (var k = 0; k < allBubbles.length; k++) {
                        if (allBubbles[k].getAttribute('data-player-id') === String(playerId)) {
                          allBubbles[k].remove();
                        }
                      }

                      var container = document.createElement('div');
                      container.className = 'pass-bubble-popup';
                      container.setAttribute('data-player-id', String(playerId));
                      container.style.left = Math.round(rect.left + rect.width / 2) + 'px';
                      container.style.top = Math.round(rect.top - 4) + 'px';

                      var body = document.createElement('div');
                      body.className = 'pass-bubble-body';
                      body.textContent = 'Passed';
                      container.appendChild(body);

                      for (var p = 1; p <= 4; p++) {
                        var puff = document.createElement('div');
                        puff.className = 'pass-cloud-puff puff-' + p;
                        container.appendChild(puff);
                      }

                      document.body.appendChild(container);

                      setTimeout(function() {
                        if (container && container.parentNode) {
                          container.parentNode.removeChild(container);
                        }
                      }, 1850);
                    };

                    window.showChatPopupBubble = function(senderName, messageText) {
                      var btn = document.getElementById('btn-dashboard-chat');
                      if (!btn) return;

                      var rect = btn.getBoundingClientRect();
                      if (rect.width === 0 && rect.height === 0) return;

                      var oldBubble = document.getElementById('dashboard-chat-popup-bubble');
                      if (oldBubble) oldBubble.remove();

                      var bubble = document.createElement('div');
                      bubble.id = 'dashboard-chat-popup-bubble';
                      var rightOffset = Math.max(12, Math.round(window.innerWidth - rect.right));
                      var topOffset = Math.round(rect.bottom + 12);

                      Object.assign(bubble.style, {
                        position: 'fixed',
                        top: topOffset + 'px',
                        right: rightOffset + 'px',
                        maxWidth: '320px',
                        minWidth: '180px',
                        backgroundColor: '#1e3a8a',
                        color: '#ffffff',
                        border: '2px solid #60a5fa',
                        borderRadius: '14px 4px 14px 14px',
                        padding: '10px 14px',
                        boxShadow: '0 10px 25px rgba(15, 23, 42, 0.45)',
                        zIndex: '10000020',
                        fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
                        cursor: 'pointer',
                        pointerEvents: 'auto',
                        transformOrigin: 'top right',
                        transition: 'opacity 0.28s ease, transform 0.28s cubic-bezier(0.16, 1, 0.3, 1)',
                        opacity: '0',
                        transform: 'translateY(-8px) scale(0.92)'
                      });

                      var tail = document.createElement('div');
                      Object.assign(tail.style, {
                        position: 'absolute',
                        top: '-9px',
                        right: '14px',
                        width: '0',
                        height: '0',
                        borderLeft: '8px solid transparent',
                        borderRight: '8px solid transparent',
                        borderBottom: '9px solid #60a5fa'
                      });
                      bubble.appendChild(tail);

                      var header = document.createElement('div');
                      Object.assign(header.style, {
                        fontSize: '0.74rem',
                        fontWeight: '800',
                        color: '#93c5fd',
                        marginBottom: '4px',
                        letterSpacing: '0.3px',
                        textTransform: 'uppercase'
                      });
                      header.textContent = '💬 ' + String(senderName || 'Player');
                      bubble.appendChild(header);

                      var body = document.createElement('div');
                      Object.assign(body.style, {
                        fontSize: '0.9rem',
                        fontWeight: '600',
                        lineHeight: '1.35',
                        color: '#ffffff',
                        wordBreak: 'break-word',
                        display: '-webkit-box',
                        webkitLineClamp: '4',
                        webkitBoxOrient: 'vertical',
                        overflow: 'hidden'
                      });
                      body.textContent = String(messageText || '');
                      bubble.appendChild(body);

                      bubble.addEventListener('click', function() {
                        bubble.remove();
                        var chatBtn = document.getElementById('btn-dashboard-chat');
                        if (chatBtn) chatBtn.click();
                      });

                      document.body.appendChild(bubble);

                      requestAnimationFrame(function() {
                        bubble.style.opacity = '1';
                        bubble.style.transform = 'translateY(0) scale(1)';
                      });

                      clearTimeout(window._chatPopupBubbleTimer);
                      window._chatPopupBubbleTimer = setTimeout(function() {
                        if (bubble && bubble.parentNode) {
                          bubble.style.opacity = '0';
                          bubble.style.transform = 'translateY(-6px) scale(0.95)';
                          setTimeout(function() {
                            if (bubble && bubble.parentNode) bubble.remove();
                          }, 300);
                        }
                      }, 4500);
                    };

                    window.notifyTurnAlert(#{is_my_turn ? true : false}, #{player_ribbon_text}, #{corp_ribbon_text}, true);
                  )

                        %x(window.init18xxResizers = function() {
                    var savedResizers = {};

                    try {
  savedResizers = JSON.parse(sessionStorage.getItem('18xx_viz_resizers')) || {};

  window.scalerUserZoom =
    JSON.parse(sessionStorage.getItem('18xx_viz_zoom')) || {
      'map-panel-bot': 1.0,
      'panel-market': 1.0,
      'panel-ledger': 1.0,
    };

  window.scalerPanOffset =
    JSON.parse(sessionStorage.getItem('18xx_viz_pan')) || {
      'map-panel-bot': { x: 0, y: 0 },
      'panel-market': { x: 0, y: 0 },
      'panel-ledger': { x: 0, y: 0 },
    };
} catch(e) {
  window.scalerUserZoom = {
    'map-panel-bot': 1.0,
    'panel-market': 1.0,
    'panel-ledger': 1.0,
  };

  window.scalerPanOffset = {
    'map-panel-bot': { x: 0, y: 0 },
    'panel-market': { x: 0, y: 0 },
    'panel-ledger': { x: 0, y: 0 },
  };
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
                  createResizer('resizer-h-entity-map', 'temporal-hub', 'map-panel-bot', true);
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

                      var uZoom = (window.scalerUserZoom && window.scalerUserZoom[panelId]) || 1.0;
                      var baseScale = (window.scalerScales && window.scalerScales[panelId]) || 1.0;
                      var effScale = baseScale * uZoom;

                      if (panelId === 'map-panel-bot') {
                        var sizer = panel.querySelector('.map-sizer');
                        if (sizer) {
                          var svgEl = wrapper.querySelector('svg');
                          var cw = parseFloat(wrapper.style.width) || (svgEl && (parseFloat(svgEl.getAttribute('width')) || (svgEl.viewBox && svgEl.viewBox.baseVal && svgEl.viewBox.baseVal.width))) || wrapper.scrollWidth || 0;
                          var ch = parseFloat(wrapper.style.height) || (svgEl && (parseFloat(svgEl.getAttribute('height')) || (svgEl.viewBox && svgEl.viewBox.baseVal && svgEl.viewBox.baseVal.height))) || wrapper.scrollHeight || 0;
                          if (cw > 0 && ch > 0) {
                            var scrollCanvas = panel.querySelector('#map-scroll-canvas');
                            var viewportW = scrollCanvas ? scrollCanvas.clientWidth : panel.clientWidth;
                            var viewportH = scrollCanvas ? scrollCanvas.clientHeight : panel.clientHeight;
                            var scaledW = Math.ceil(cw * effScale + Math.max(0, offset.x));
                            var scaledH = Math.ceil(ch * effScale + Math.max(0, offset.y));
                            var targetW = scaledW > viewportW + 1 ? scaledW : viewportW;
                            var targetH = scaledH > viewportH + 1 ? scaledH : viewportH;
                            sizer.style.width = targetW + 'px';
                            sizer.style.height = targetH + 'px';
                            sizer.style.minWidth = targetW + 'px';
                            sizer.style.minHeight = targetH + 'px';
                          }
                        }
                      }

                      if (panelId === 'panel-ledger') {
                        var sizer = panel.querySelector('.ledger-sizer');
                        var inner = wrapper.firstElementChild || wrapper;
                        var cw = Math.max(wrapper.scrollWidth || 0, inner.scrollWidth || 0, inner.offsetWidth || 0);
                        var ch = Math.max(wrapper.scrollHeight || 0, inner.scrollHeight || 0, inner.offsetHeight || 0);

                        if (sizer && cw > 0 && ch > 0) {
                          var scrollCanvas = panel.querySelector('#panel-ledger-scroll') || panel;
                          var viewportW = scrollCanvas.clientWidth || panel.clientWidth;
                          var viewportH = scrollCanvas.clientHeight || panel.clientHeight;

                          var scaledW = Math.ceil(cw * effScale + Math.max(0, offset.x) + 12);
                          var scaledH = Math.ceil(ch * effScale + Math.max(0, offset.y) + 16);

                          var targetW = scaledW > viewportW + 1 ? scaledW : viewportW;
                          var targetH = scaledH > viewportH + 1 ? scaledH : viewportH;

                          sizer.style.width = targetW + 'px';
                          sizer.style.height = targetH + 'px';
                          sizer.style.minWidth = targetW + 'px';
                          sizer.style.minHeight = targetH + 'px';
                        }
                      }

                      if (panelId === 'panel-market') {
                        var sizer = panel.querySelector('.market-sizer');
                        var cw = parseFloat(wrapper.style.width) || wrapper.scrollWidth || 0;
                        var ch = parseFloat(wrapper.style.height) || wrapper.scrollHeight || 0;

                        if (sizer && cw > 0 && ch > 0) {
                          var scrollCanvas = panel.querySelector('#panel-market-scroll') || panel;
                          var viewportW = scrollCanvas.clientWidth || panel.clientWidth;
                          var viewportH = scrollCanvas.clientHeight || panel.clientHeight;

                          var scaledW = Math.ceil(cw * effScale + Math.max(0, offset.x) + 12);
                          var scaledH = Math.ceil(ch * effScale + Math.max(0, offset.y) + 12);

                          var targetW = scaledW > viewportW + 1 ? scaledW : viewportW;
                          var targetH = scaledH > viewportH + 1 ? scaledH : viewportH;

                          sizer.style.width = targetW + 'px';
                          sizer.style.height = targetH + 'px';
                          sizer.style.minWidth = targetW + 'px';
                          sizer.style.minHeight = targetH + 'px';
                        }
                      }

                      var dynStyle = document.getElementById('dynamic-scaler-styles');
                      if (!dynStyle) return;
                      var css = '';
                      for (var id in window.scalerScales) {
                        var uz = (window.scalerUserZoom && window.scalerUserZoom[id]) || 1.0;
                        var es = window.scalerScales[id] * uz;
                        css += '#' + id + ' .scaler-content { transform: scale(' + es + ') !important; transform-origin: top left !important; }\n';
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
                        var scrollCanvas =
                          panel.querySelector('#map-scroll-canvas') ||
                          panel.querySelector('#panel-ledger-scroll') ||
                          panel.querySelector('#panel-market-scroll') ||
                          panel;
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
createPanHandler('panel-ledger');

                    var styleTag = document.getElementById('dashboard-map-svg-styles');
                    if (!styleTag) {
                      styleTag = document.createElement('style');
                      styleTag.id = 'dashboard-map-svg-styles';
                      document.head.appendChild(styleTag);
                    }

                    styleTag.innerHTML = '#map-scroll-canvas svg { max-width: none !important; } ' +
                     '.scaler-content .tile__text { font-size: 0.75em !important; } ' +
                     '.scaler-content text.number { font-size: 0.55em !important; } ' +
                     '#panel-market { isolation: isolate; } ' +
                     '#panel-market .scaler-content { z-index: 1; } ' +
                     '#market-hover-overlay, .market-hover-overlay, .stock-market-tooltip, [class*="hover-overlay"] { ' +
                     '  z-index: 9999 !important; pointer-events: none; ' +
                     '} ' +
                     '#panel-market svg g.marker, #panel-market .market-marker, #panel-market svg g[id*="marker"], ' +
                     '#panel-market .stock-market-token, #panel-market [id^="stock-token-"] { ' +
                     '  pointer-events: auto !important; z-index: 2; ' +
                     '} ' +
                     '@keyframes map-hex-pulse { ' +
                     '  0% { ' +
                     '    stroke: #00ffff; ' +
                     '    stroke-width: 6px; ' +
                     '    fill-opacity: 0.08; ' +
                     '    filter: drop-shadow(0 0 4px #00ffff); ' +
                     '  } ' +
                     '  50% { ' +
                     '    stroke: #00ffff; ' +
                     '    stroke-width: 12px; ' +
                     '    fill-opacity: 0.35; ' +
                     '    filter: drop-shadow(0 0 14px #00ffff); ' +
                     '  } ' +
                     '  100% { ' +
                     '    stroke: #00ffff; ' +
                     '    stroke-width: 6px; ' +
                     '    fill-opacity: 0.08; ' +
                     '    filter: drop-shadow(0 0 4px #00ffff); ' +
                     '  } ' +
                     '} ' +
                     '.map-hex-highlight .hex-highlight-poly { ' +
                     '  stroke: #00ffff !important; ' +
                     '  stroke-width: 8px !important; ' +
                     '  fill: #00ffff !important; ' +
                     '  fill-opacity: 0.20 !important; ' +
                     '  animation: map-hex-pulse 1.3s infinite ease-in-out !important; ' +
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
                          if (svg) {
                            var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
                            var allG = svg.querySelectorAll('g');
                            if (allG.length > 0) {
                              for (var gi = 0; gi < allG.length; gi++) {
                                try {
                                  var gb = allG[gi].getBBox();
                                  if (gb && (gb.width > 0 || gb.height > 0)) {
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
                                if (sb && (sb.width > 0 || sb.height > 0)) {
                                  minX = Math.min(minX, sb.x);
                                  minY = Math.min(minY, sb.y);
                                  maxX = Math.max(maxX, sb.x + sb.width);
                                  maxY = Math.max(maxY, sb.y + sb.height);
                                }
                              } catch(err) {}
                            }

                            if (isFinite(maxX) && isFinite(maxY) && (maxX - minX) > 50 && (maxY - minY) > 50) {
                              var requiredWidth = (maxX - minX) + 50;
                              var requiredHeight = (maxY - minY) + 50;
                              svg.setAttribute('viewBox', (minX - 25) + ' ' + (minY - 25) + ' ' + requiredWidth + ' ' + requiredHeight);
                              svg.setAttribute('width', requiredWidth);
                              svg.setAttribute('height', requiredHeight);
                              svg.style.width = requiredWidth + 'px';
                              svg.style.height = requiredHeight + 'px';
                              wrapper.style.width = requiredWidth + 'px';
                              wrapper.style.height = requiredHeight + 'px';
                              cw = requiredWidth;
                              ch = requiredHeight;
                            } else {
                              var attrW = parseFloat(svg.getAttribute('width')) || (svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.width) || 0;
                              var attrH = parseFloat(svg.getAttribute('height')) || (svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.height) || 0;
                              if (attrW > 50 && attrH > 50) {
                                cw = attrW;
                                ch = attrH;
                              }
                            }
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
if (cw > 50 && ch > 50 && pw > 50 && ph > 50) {
                            if (panel.id === 'panel-ledger') {
                            // Fit width (up to 1.0x) so tall status tables remain readable and scroll vertically
                            window.scalerScales[panel.id] = Math.min(1.0, pw / cw);
                          } else {
                            window.scalerScales[panel.id] = Math.min(pw / cw, ph / ch);
                          }
                        }
                      }

                      for (var pId in window.scalerScales) {
                        window.applyPanelTransform(pId);
                      }
                    });
window.recalcAllPanels = function() {
                      ['map-panel-bot', 'panel-market', 'panel-ledger'].forEach(function(id) {
                        var panel = document.getElementById(id);
                        if (!panel) return;
                        var wrapper = panel.querySelector('.scaler-content');
                        if (!wrapper) return;
                        var cw = wrapper.scrollWidth;
                        var ch = wrapper.scrollHeight;
                        if (id === 'map-panel-bot') {
                          var svg = wrapper.querySelector('svg');
                          if (svg) {
                            var sw = parseFloat(wrapper.style.width) || parseFloat(svg.getAttribute('width')) || (svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.width) || 0;
                            var sh = parseFloat(wrapper.style.height) || parseFloat(svg.getAttribute('height')) || (svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.height) || 0;
                            if (sw > 50 && sh > 50) {
                              cw = sw;
                              ch = sh;
                            }
                          }
                        }
                        var pw = panel.clientWidth - 16;
                        var ph = panel.clientHeight - 16;
                        if (cw > 50 && ch > 50 && pw > 50 && ph > 50) {
                          if (id === 'panel-ledger') {
                            window.scalerScales[id] = Math.min(1.0, pw / cw);
                          } else {
                            window.scalerScales[id] = Math.min(pw / cw, ph / ch);
                          }
                        }
                        window.applyPanelTransform(id);
                      });
                    };

                    ['map-panel-bot', 'panel-market', 'panel-ledger'].forEach(function(id) {
                      var el = document.getElementById(id);
                      if (el) {
                        fitObserver.observe(el);
                        var innerWrapper = el.querySelector('.scaler-content');
                        if (innerWrapper) fitObserver.observe(innerWrapper);
                      }
                    });


                    setTimeout(window.recalcAllPanels, 100);
                    setTimeout(window.recalcAllPanels, 400);
                  };
                  setTimeout(window.init18xxResizers, 200);)
                      },
              postpatch: lambda { |_old, _vnode|
                           %x{
  if (window.positionDashboardButtons) {
    window.positionDashboardButtons();
  }
    if (window.recalcAllPanels) {
    requestAnimationFrame(window.recalcAllPanels);
  }
}
                           check_and_pop_new_chat!
                           prev_id = Lib::Storage["viz_last_act_#{game_storage_id}"]&.to_i || 0
                           curr_id = last_action_id.to_i

                           if curr_id > prev_id && prev_id.positive?
                             animate_last_action(last_action)
                             prev_player = Lib::Storage["viz_last_player_#{game_storage_id}"]
                             curr_player = player_ribbon_text.to_s
                             is_player_transition = !curr_player.empty? && (prev_player != curr_player)
                             Lib::Storage["viz_last_player_#{game_storage_id}"] = curr_player

                             if is_player_transition
                               %x(
                           if (window.notifyTurnAlert) {
                             window.notifyTurnAlert(#{is_my_turn ? true : false}, #{player_ribbon_text}, #{corp_ribbon_text}, false);
                           }
                         )
                             end
                           end
                           Lib::Storage["viz_last_act_#{game_storage_id}"] = curr_id
                         },
              destroy: lambda {
                         %x(
                     if (window._other_games_timer) {
                       clearInterval(window._other_games_timer);
                       window._other_games_timer = null;
                     }
                   )
                         %x(
                     window._dashboardVisualizer = null;
                     window.toggleDashboardPhases = null;
                     if (window.positionDashboardButtons) {
                       window.removeEventListener('resize', window.positionDashboardButtons);
 window.removeEventListener('scroll', window.positionDashboardButtons);
                     }
                     window.positionDashboardButtons = null;
                    if (window._dashboardAiKeyHandler) {
                       window.removeEventListener('keydown', window._dashboardAiKeyHandler, true);
                       window.removeEventListener('keydown', window._dashboardAiKeyHandler, false);
                       window._dashboardAiKeyHandler = null;
                     }
                   )

                         %x(
                     var menuStyle = document.getElementById('dashboard-menu-overrides');
                     if (menuStyle) menuStyle.remove();
                     var ribbon = document.getElementById('turn-notification-ribbon');
                     if (ribbon) ribbon.remove();
                     var passBubbles = document.querySelectorAll('.pass-bubble-popup');
                     for (var bi = 0; bi < passBubbles.length; bi++) {
                       passBubbles[bi].remove();
                     }
                       var chatBubble = document.getElementById('dashboard-chat-popup-bubble');
                     if (chatBubble) chatBubble.remove();
                   )
                         `document.body.style.overflow = ''`
                         `document.body.style.overflowX = ''`
                         `document.body.style.overflowY = ''`
                         `document.body.style.margin = ''`
                         `document.body.style.padding = ''`

                         `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: '', padding: '', margin: '', maxWidth: '', width: '', height: '' })`

                         `document.getElementById('game') && Object.assign(document.getElementById('game').style, { display: '', flexDirection: '', overflow: '', width: '', height: '', maxWidth: '', maxHeight: '' })`
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
              height: 'calc(100% - 56px)',
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
            h(:div, { attrs: { id: 'col-left' }, style: { flex: '0 0 55%', height: '100%', minHeight: '0', display: 'flex', flexDirection: 'column', overflow: 'hidden', gap: '0.5rem' } }, [
              (render_temporal_hub if map_wider_than_high?),
              (h(:div, { attrs: { id: 'resizer-h-entity-map', title: 'Drag to resize Entity Order' }, style: { flex: '0 0 0.5rem', minHeight: '0.5rem', cursor: 'row-resize', zIndex: 10, backgroundColor: 'transparent', borderRadius: '0' } }) if map_wider_than_high?),
              h(:div, { attrs: { id: 'map-panel-bot' }, style: { flex: '1 1 auto', width: '100%', height: '100%', minHeight: '0', boxSizing: 'border-box', border: '1px solid #ccc', borderRadius: '4px', backgroundColor: '#fff', overflow: 'hidden', position: 'relative' } }, [

render_zoom_controls('map-panel-bot', { top: '6px', right: '12px' }),
render_map_phase_indicator,
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
h(View::Game::DashboardMap,
  game: @game,
  user: @user,
  show_meme_revenue: meme_revenue_enabled?,
  show_location_names: location_names_enabled?,
  simple_logos: simple_logos_enabled?),
      ]),
  ]),
]),
h(:div, {
    attrs: { id: 'canvas-game-watermark' },
    style: {
      position: 'absolute',
      bottom: '8px',
      right: '16px',
      zIndex: 15,
      pointerEvents: 'none',
      userSelect: 'none',
      fontFamily: 'Impact, "Arial Black", sans-serif',
      fontSize: '5.5rem',
      fontWeight: '900',
      lineHeight: '1',
      letterSpacing: '2px',
      color: 'rgba(15, 23, 42, 0.18)',
      textShadow: '0 0 2px #ffffff, 0 0 6px rgba(255, 255, 255, 0.7)',
    },
  }, game_title),
h(:div, {
    attrs: { class: 'panel-manifest-control' },
    style: {
      position: 'absolute',
      top: '36px',
      left: '6px',
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
].compact),
              ].compact),

            h(:div, { attrs: { id: 'resizer-v-main' }, style: { flex: '0 0 0.75rem', cursor: 'col-resize', zIndex: 10 } }),

            h(:div, { attrs: { id: 'col-right' }, style: { flex: '1 1 auto', display: 'flex', flexDirection: 'column', height: '100%', maxHeight: '100%', overflow: 'hidden', gap: '0.5rem' } }, [
              (render_temporal_hub unless map_wider_than_high?),
              (h(:div, { attrs: { id: 'resizer-h-entity-ledger', title: 'Drag to resize Entity Order' }, style: { flex: '0 0 0.5rem', minHeight: '0.5rem', cursor: 'row-resize', zIndex: 10, backgroundColor: 'transparent', borderRadius: '0' } }) unless map_wider_than_high?),

              h(:div, {
                  attrs: { id: 'panel-ledger' },
                  style: {
                    flex: '1 1 auto',
                    width: '100%',
                    height: '100%',
                    minHeight: '0',
                    overflow: 'hidden',
                    border: '1px solid #ccc',
                    borderRadius: '4px',
                    backgroundColor: '#fff',
                    boxSizing: 'border-box',
                    position: 'relative',
                  },
                }, [
  render_zoom_controls('panel-ledger', { top: '6px', right: '18px' }),
  h(:div, {
      attrs: { id: 'panel-ledger-scroll' },
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
          attrs: { class: 'ledger-sizer' },
          style: {
            position: 'relative',
            display: 'block',
            width: '100%',
            height: '100%',
            minWidth: '100%',
            minHeight: '100%',
          },
        }, [
          h(:div, {
              attrs: { class: 'scaler-content' },
              style: {
                position: 'absolute',
                top: '0',
                left: '0',
                width: 'max-content',
                height: 'max-content',
                transformOrigin: 'top left',
                padding: '0.35rem',
                boxSizing: 'border-box',
              },
            }, [
              h(:div, {
                  style: {
                    display: 'flex',
                    flexDirection: 'column',
                    width: 'max-content',
                    minWidth: '100%',
                  },
                }, [
                  h(View::Game::DashboardGameStatus,
                    game: @game,
                    user: @user),
                ]),
            ]),
        ]),
    ]),
                                ]),

              h(:div, { attrs: { id: 'resizer-h-ledger-market' }, style: { flex: '0 0 0.5rem', cursor: 'row-resize', zIndex: 10 } }),

              h(:div, {
                  attrs: { id: 'panel-market' },
                  style: {
                    flex: '1 1 auto',
                    width: '100%',
                    minHeight: '12rem',
                    overflow: 'hidden',
                    border: '1px solid #ccc',
                    borderRadius: '4px',
                    backgroundColor: '#fff',
                    boxSizing: 'border-box',
                    position: 'relative',
                  },
                }, [
                  render_zoom_controls('panel-market', { top: '6px', left: '6px' }),
                  h(:div, {
                      attrs: { id: 'panel-market-scroll' },
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
                          attrs: { class: 'market-sizer' },
                          style: {
                            position: 'relative',
                            display: 'block',
                            width: '100%',
                            height: '100%',
                            minWidth: '100%',
                            minHeight: '100%',
                          },
                        }, [
                          h(:div, {
                              attrs: { class: 'scaler-content' },
                              style: {
                                position: 'absolute',
                                top: '0',
                                left: '0',
                                display: 'flex',
                                flexDirection: 'column',
                                width: 'max-content',
                                height: 'max-content',
                                transformOrigin: 'top left',
                                margin: '0',
                                padding: '0.35rem',
                              },
                            }, [
                              h(View::Game::DashboardStockMarket, game: @game),
                            ]),
                        ]),
                    ]),
                ]),
].compact),
            render_global_auction_overlay,
            render_par_overlay,
            render_tile_manifest_overlay,
            render_history_overlay,
            render_dashboard_move_feed_overlay,
            render_other_games_overlay,
            render_top_nav_utility_cluster,
            render_chat_overlay,
            render_help_overlay,
            render_phases_overlay,
            render_action_window,

            h(:div, { attrs: { id: 'turn-notification-ribbon' } }),
          ].compact)
      end
    end
  end
end

# rubocop:enable Layout/LineLength
