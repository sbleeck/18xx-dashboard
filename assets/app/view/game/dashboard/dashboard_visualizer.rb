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
        return nil unless entity

        if entity.player?
          entity
        elsif entity.respond_to?(:player) && entity.player
          entity.player
        else
          entity.owner
        end
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
          source = "#bank_train_#{train_id}, [id^='bank_train_#{train_id}'], #extra_cards .card-train, [id^='cmd_train_'], [id^='cmd_other_train_'], #extra_cards"
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
                h(:p, 'The game has concluded. Active turn components and ledgers are disabled.'),
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

        h(:div, {
            hook: {
              insert: lambda {
                        Lib::Storage["viz_last_act_#{game_storage_id}"] = last_action_id.to_i
                        `document.body.style.overflow = 'hidden'`
                        `document.body.style.margin = '0'`
                        `document.body.style.padding = '0'`
                        `document.body.style.backgroundColor = '#ffffff'`
                        `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: 'hidden', padding: '0', margin: '0', maxWidth: '100vw', width: '100vw', height: '100vh', backgroundColor: '#ffffff' })`
                        `document.getElementById('game') && Object.assign(document.getElementById('game').style, { overflow: 'hidden', width: '100vw', height: 'calc(100vh - 50px)', maxWidth: '100vw', maxHeight: 'calc(100vh - 50px)' })`

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

                              var minNext = 0;
                              if (next) {
                                var computedMin = isVertical ? window.getComputedStyle(next).minHeight : window.getComputedStyle(next).minWidth;
                                minNext = parseFloat(computedMin) || 0;
                              }
                              var maxPrev = Math.max(0, totalFlex - minNext);
                              var newPrevFlex = Math.max(0, Math.min(maxPrev, prevFlex + delta));

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
                          styleTag.innerHTML = '.scaler-content text { font-size: 0.65em !important; letter-spacing: normal !important; } ' +
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

                          ['map-panel-bot', 'panel-ledger', 'panel-market'].forEach(function(id) {
                            var el = document.getElementById(id);
                            if (el) fitObserver.observe(el);
                          });
                        };
                        setTimeout(window.init18xxResizers, 200);)
                      },
              postpatch: lambda { |_old, _vnode|
                           prev_id = Lib::Storage["viz_last_act_#{game_storage_id}"]&.to_i || 0
                           curr_id = last_action_id.to_i

                           animate_last_action(last_action) if curr_id > prev_id && prev_id.positive?
                           Lib::Storage["viz_last_act_#{game_storage_id}"] = curr_id
                         },
              destroy: lambda {
                         `document.body.style.backgroundColor = ''`
                         `document.getElementById('app') && Object.assign(document.getElementById('app').style, { overflow: '', padding: '', margin: '', maxWidth: '', width: '', height: '', backgroundColor: '' })`
                         `document.getElementById('game') && Object.assign(document.getElementById('game').style, { overflow: '', width: '', height: '', maxWidth: '', maxHeight: '' })`
                       },
            },
            attrs: { id: 'viz-master-frame' },
            style: {
              display: 'flex',
              flexDirection: 'row',
              width: '100vw',
              height: 'calc(100vh - 50px)',
              maxHeight: 'calc(100vh - 50px)',
              boxSizing: 'border-box',
              position: 'relative',
              overflow: 'hidden',
              padding: '0.5rem',
              backgroundColor: '#ffffff',
            },
          }, [
          # COLUMN 1 (LEFT): COMMAND SPACE (TOP) + MAP CANVAS (BOTTOM)
          h(:div, { attrs: { id: 'col-left' }, style: { flex: '0 0 55%', height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' } }, [
            # Command Row (Flexible height controlled by resizer)
            h(:div, { attrs: { id: 'command-space-top' }, style: { flex: '0 0 7.5rem', minHeight: '4.5rem', border: '1px solid #ccc', borderRadius: '4px', backgroundColor: '#fff', display: 'flex', flexDirection: 'column', overflow: 'hidden', boxSizing: 'border-box' } }, [
              h(:div, { style: { padding: '0.2rem', height: '100%', boxSizing: 'border-box', overflowY: 'hidden' } }, [
                h(View::Game::DashboardCommandColumn, game: @game),
              ]),
            ]),

            # Horizontal Resizer between Command Space and Map
            h(:div, { attrs: { id: 'resizer-h-cmd-map' }, style: { flex: '0 0 0.5rem', cursor: 'row-resize', zIndex: 10 } }),

            # Map Panel Box
            h(:div, { attrs: { id: 'map-panel-bot' }, style: { flex: '1 1 auto', minHeight: '0', boxSizing: 'border-box', border: '1px solid #ccc', borderRadius: '4px', backgroundColor: '#fff', overflow: 'hidden', position: 'relative' } }, [
               render_zoom_controls('map-panel-bot', { top: '6px', left: '6px' }),
               h(:div, { attrs: { class: 'scaler-content' }, style: { position: 'absolute', top: '0', left: '0', width: 'max-content', height: 'max-content', transformOrigin: 'top left' } }, [
                 h(View::Game::DashboardMap, game: @game, user: @user),
               ]),
               h(:div, {
                   attrs: { class: 'panel-manifest-control' },
                   style: {
                     position: 'absolute',
                     top: '8px',
                     right: '8px',
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

          # VERTICAL RESIZER
          h(:div, { attrs: { id: 'resizer-v-main' }, style: { flex: '0 0 0.75rem', cursor: 'col-resize', zIndex: 10 } }),

          # COLUMN 2 (RIGHT): GLOBAL CONTROLS, TURN ORDER & DATA LEDGERS
          h(:div, { attrs: { id: 'col-right' }, style: { flex: '1 1 auto', display: 'flex', flexDirection: 'column', height: '100%', maxHeight: '100%', overflow: 'hidden', gap: '0.5rem' } }, [

            # Entity Turn Tracker Hub
            h(:div, { attrs: { id: 'temporal-hub' }, style: { flex: '0 0 auto', display: 'flex', flexDirection: 'column', border: '1px solid #ccc', borderRadius: '4px', backgroundColor: '#f8f9fa', padding: '0.25rem', minHeight: '2.8rem', overflowX: 'auto' } }, [
              if @game.respond_to?(:finished?) && @game.finished?
                h(View::Game::DashboardEntityOrder, round: nil)
              else
                h(View::Game::DashboardEntityOrder, round: @game.round)
              end,
            ]),

            # Status Table & Cash / Trains Ledger
            h(:div, { attrs: { id: 'panel-ledger' }, style: { flex: '1 1 auto', overflow: 'hidden', border: '1px solid #ccc', padding: '0.4rem', borderRadius: '4px', backgroundColor: '#fff', display: 'flex', flexDirection: 'column' } }, [
              h(:div, { attrs: { class: 'scaler-content' }, style: { display: 'flex', flexDirection: 'column', width: 'max-content', minWidth: '100%', transformOrigin: 'top left' } }, [
                h(View::Game::DashboardGameStatus, game: @game),
              ]),
            ]),

            # Horizontal Resizer
            h(:div, { attrs: { id: 'resizer-h-ledger-market' }, style: { flex: '0 0 0.5rem', cursor: 'row-resize', zIndex: 10 } }),

            # Stock Market Grid
h(:div, { attrs: { id: 'panel-market' }, style: { flex: '1 1 auto', minHeight: '12rem', overflow: 'hidden', border: '1px solid #ccc', padding: '0.5rem', borderRadius: '4px', backgroundColor: '#fff', boxSizing: 'border-box', position: 'relative' } }, [
                render_zoom_controls('panel-market', { top: '6px', right: '6px' }),
              h(:div, { attrs: { class: 'scaler-content' }, style: { position: 'absolute', top: '0', left: '0', display: 'flex', flexDirection: 'column', width: 'max-content', height: 'max-content', transformOrigin: 'top left', margin: '0', padding: '0' } }, [
                h(View::Game::DashboardStockMarket, game: @game),
              ]),
            ]),
          ]),
          render_par_overlay,
          render_tile_manifest_overlay,
        ].compact)
      end
    end
  end
end
# rubocop:enable Layout/LineLength
