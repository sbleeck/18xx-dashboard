# frozen_string_literal: true

require '../lib/storage'
require '../lib/settings'
require 'view/game/axis'
require 'view/game/hex'
require 'view/game/tile_confirmation'
require 'view/game/tile_selector'
require 'view/game/token_selector'
require 'view/game/part/track'
require 'view/game/part/revenue'
require 'view/game/part/city_slot'
require 'view/game/token'

begin
  require 'view/game/part/location_name'
  require 'view/game/part/future_revenue'
rescue LoadError
end

module Lib
  module TileLayAnimation
    def self.hook
      {
        update: lambda do |old_vnode, vnode|
          %x{
            var oldV = #{old_vnode};
            var newV = #{vnode};
            if (!oldV || !newV || !oldV.elm || !newV.elm) return;

            var oldAttrs = (oldV.data && oldV.data.attrs) ? oldV.data.attrs : null;
            var newAttrs = (newV.data && newV.data.attrs) ? newV.data.attrs : null;
            if (!oldAttrs || !newAttrs) return;

            var oldState = oldAttrs['data-tile-state'];
            var newState = newAttrs['data-tile-state'];

            // Only trigger when a tile change or rotation is confirmed
            if (!oldState || !newState || oldState === newState) return;

            var hexContainer = newV.elm;
            var baseHex = hexContainer.firstElementChild;
            var transformStr = hexContainer.getAttribute('data-transform') || '';

            var origTransform = baseHex ? (baseHex.getAttribute('data-orig-transform') || baseHex.getAttribute('transform') || transformStr) : transformStr;
            if (baseHex && !baseHex.getAttribute('data-orig-transform')) {
              baseHex.setAttribute('data-orig-transform', origTransform);
            }

            // Bring hex container forward in SVG stacking context during animation
            if (hexContainer.parentNode) {
              hexContainer.parentNode.appendChild(hexContainer);
            }

            var poly = hexContainer.querySelector('.hex-highlight-poly');
            var pointsStr = poly ? poly.getAttribute('points') : '';
            if (!pointsStr) pointsStr = '-50,0 -25,-43.3 25,-43.3 50,0 25,43.3 -25,43.3';

            // Create shockwave container inside hex local coordinates
            var shockwaveGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
            shockwaveGroup.setAttribute('transform', transformStr);
            shockwaveGroup.setAttribute('pointer-events', 'none');

            // Shockwave 1: High-energy cyan expansion
            var poly1 = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
            poly1.setAttribute('points', pointsStr);
            poly1.setAttribute('fill', '#00ffff');
            poly1.setAttribute('fill-opacity', '0');
            poly1.setAttribute('stroke', '#00ffff');
            poly1.setAttribute('stroke-width', '0');
            poly1.setAttribute('stroke-opacity', '0');

            // Shockwave 2: Outer luminous echo wave
            var poly2 = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
            poly2.setAttribute('points', pointsStr);
            poly2.setAttribute('fill', 'none');
            poly2.setAttribute('stroke', '#ffffff');
            poly2.setAttribute('stroke-width', '0');
            poly2.setAttribute('stroke-opacity', '0');
            poly2.style.filter = 'drop-shadow(0 0 8px #00ffff)';

            shockwaveGroup.appendChild(poly1);
            shockwaveGroup.appendChild(poly2);
            hexContainer.appendChild(shockwaveGroup);

            var startTime = performance.now();
            var slamDuration = 420;
            var totalDuration = 1600;

            function frame(now) {
              var elapsed = now - startTime;

              // 1. Tile Fly-In & Drop-Slam
              if (baseHex && elapsed <= slamDuration) {
                var s = 1.0;
                if (elapsed < 240) {
                  var p = elapsed / 240;
                  s = 2.2 - (1.28 * p * p);
                  baseHex.style.filter = 'drop-shadow(0px 22px 16px rgba(0,0,0,0.75)) brightness(' + (1.2 + 0.3 * p) + ')';
                } else if (elapsed < 330) {
                  var p2 = (elapsed - 240) / 90;
                  s = 0.92 + 0.16 * Math.sin(p2 * Math.PI / 2);
                  baseHex.style.filter = 'drop-shadow(0px 0px 14px #00ffff) brightness(' + (1.6 - 0.4 * p2) + ')';
                } else {
                  var p3 = (elapsed - 330) / 90;
                  s = 1.08 - 0.08 * p3;
                  baseHex.style.filter = 'drop-shadow(0px 0px ' + (14 * (1 - p3)) + 'px #00ffff) brightness(' + (1.2 - 0.2 * p3) + ')';
                }
                baseHex.setAttribute('transform', origTransform + ' scale(' + s.toFixed(3) + ')');
              } else if (baseHex && baseHex.getAttribute('data-orig-transform') && elapsed > slamDuration) {
                baseHex.setAttribute('transform', origTransform);
                baseHex.style.filter = '';
              }

              // 2. Radiating Shockwave Ring 1 (Cyan Energy Burst)
              var w1Start = 240;
              var w1Dur = 740;
              if (elapsed >= w1Start && elapsed <= (w1Start + w1Dur)) {
                var pw1 = (elapsed - w1Start) / w1Dur;
                var sw1 = 1.0 + 1.8 * (1 - Math.pow(1 - pw1, 3));
                var op1 = Math.max(0, 1.0 - pw1);
                poly1.setAttribute('transform', 'scale(' + sw1.toFixed(3) + ')');
                poly1.setAttribute('stroke-width', (10 * (1 - pw1 * 0.7)).toFixed(1));
                poly1.setAttribute('stroke-opacity', op1.toFixed(3));
                poly1.setAttribute('fill-opacity', (0.35 * op1).toFixed(3));
              } else {
                poly1.setAttribute('stroke-opacity', '0');
                poly1.setAttribute('fill-opacity', '0');
              }

              // 3. Radiating Shockwave Ring 2 (White/Cyan Echo Wave)
              var w2Start = 360;
              var w2Dur = 900;
              if (elapsed >= w2Start && elapsed <= (w2Start + w2Dur)) {
                var pw2 = (elapsed - w2Start) / w2Dur;
                var sw2 = 1.0 + 2.4 * (1 - Math.pow(1 - pw2, 3));
                var op2 = Math.max(0, 0.9 - pw2 * 0.9);
                poly2.setAttribute('transform', 'scale(' + sw2.toFixed(3) + ')');
                poly2.setAttribute('stroke-width', (8 * (1 - pw2 * 0.8)).toFixed(1));
                poly2.setAttribute('stroke-opacity', op2.toFixed(3));
              } else {
                poly2.setAttribute('stroke-opacity', '0');
              }

              // 4. Hex Border Beacon Pulse
              if (poly) {
                if (elapsed >= 420 && elapsed < 1500) {
                  var pulse = (Math.sin((elapsed - 420) / 1080 * Math.PI * 4) + 1) / 2;
                  poly.setAttribute('stroke', '#00ffff');
                  poly.setAttribute('stroke-width', '8');
                  poly.setAttribute('fill', '#00ffff');
                  poly.setAttribute('fill-opacity', (0.15 + 0.3 * pulse).toFixed(3));
                } else if (elapsed >= 1500) {
                  var origStroke = poly.getAttribute('data-orig-stroke') || 'transparent';
                  var origWidth = poly.getAttribute('data-orig-width') || '0';
                  var origFill = poly.getAttribute('data-orig-fill') || 'transparent';
                  var origFillOpacity = poly.getAttribute('data-orig-fill-opacity') || '0';
                  poly.setAttribute('stroke', origStroke);
                  poly.setAttribute('stroke-width', origWidth);
                  poly.setAttribute('fill', origFill);
                  poly.setAttribute('fill-opacity', origFillOpacity);
                }
              }

              if (elapsed < totalDuration) {
                window.requestAnimationFrame(frame);
              } else {
                if (shockwaveGroup.parentNode) {
                  shockwaveGroup.parentNode.removeChild(shockwaveGroup);
                }
                if (baseHex) {
                  baseHex.setAttribute('transform', origTransform);
                  baseHex.style.filter = '';
                  baseHex.removeAttribute('data-orig-transform');
                }
              }
            }

            window.requestAnimationFrame(frame);
          }
        end,
      }
    end
  end
end

module View
  module Game
    class Hex < Snabberb::Component
      unless method_defined?(:orig_dashboard_render)
        alias orig_dashboard_render render

        def render
          rendered = orig_dashboard_render
          %x{
            function removeLegacyFills(vnode) {
              if (!vnode) return;
              if (Array.isArray(vnode)) {
                for (var i = vnode.length - 1; i >= 0; i--) {
                  var child = vnode[i];
                  if (child && child.data && child.data.attrs) {
                    var f = (child.data.attrs['fill'] || '').toLowerCase();
                    var s = (child.data.attrs['stroke'] || '').toLowerCase();
                    if (f === 'red' || f === '#ff0000' || f === '#f00' || f === 'rgba(255, 0, 0, 0.5)' || f === 'rgba(255,0,0,0.5)' ||
                        f === 'green' || f === '#00ff00' || f === '#0f0' ||
                        s === 'red' || s === '#ff0000' || s === '#f00' ||
                        s === 'green' || s === '#00ff00' || s === '#0f0') {
                      vnode.splice(i, 1);
                      continue;
                    }
                  }
                  removeLegacyFills(child);
                }
                return;
              }
              if (vnode.children && Array.isArray(vnode.children)) {
                removeLegacyFills(vnode.children);
              }
            }
            removeLegacyFills(#{rendered});
          }
          rendered
        end
      end
    end
  end
end

module View
  module Game
    class Token < Snabberb::Component
      unless method_defined?(:orig_map_pulse_render)
        alias orig_map_pulse_render render

        def render
          rendered = orig_map_pulse_render
          corp = @corporation
          corp ||= @token.corporation if @token.respond_to?(:corporation)
          return rendered unless corp

          corp_id = corp.id.to_s
          %x{
            var v = #{rendered};
            if (v) {
              var list = Array.isArray(v) ? v : [v];
              for (var i = 0; i < list.length; i++) {
                var item = list[i];
                if (item) {
                  if (!item.data) item.data = {};
                  if (!item.data.attrs) item.data.attrs = {};
                  item.data.attrs['data-corp'] = #{corp_id};
                  var c = item.data.attrs['class'] || '';
                  if (c.indexOf('map-token') === -1) {
                    item.data.attrs['class'] = (c + ' map-token map-token-' + #{corp_id}).trim();
                  }
                }
              }
            }
          }
          rendered
        end
      end
    end
  end
end

module View
  module Game
    module Part
      class CitySlot < Base
        needs :game, default: nil, store: true
        needs :selected_company, default: nil, store: true
        unless method_defined?(:orig_render)
          alias orig_render render

          def render
            rendered = orig_render
            return rendered unless flash_token_slot?

            highlight = h(:circle, {
                            attrs: {
                              cx: 0,
                              cy: 0,
                              r: @radius,
                              fill: '#00ffff',
                              stroke: '#00ffff',
                              'stroke-width': 3,
                              'pointer-events': 'none',
                            },
                          }, [
              h(:animate,
                attrs: { attributeName: 'fill-opacity', values: '0.15;0.70;0.15', dur: '1.4s', repeatCount: 'indefinite' }),
              h(:animate,
                attrs: { attributeName: 'stroke-opacity', values: '0.35;1.0;0.35', dur: '1.4s', repeatCount: 'indefinite' }),
            ])

            rendered_children = `Array.isArray(#{rendered})` ? rendered : [rendered]
            h(:g, {}, [*rendered_children, highlight].compact)
          end

          def flash_token_slot?
            return false if @token || !@game || !@tile&.hex

            step = @game.round.active_step(@selected_company)
            current_entity = @selected_company || step&.current_entity
            return false unless step && current_entity

            actions = step.actions(current_entity) || []
            return false unless actions.include?('place_token') || actions.include?('hex_token')
            return false unless step.available_hex(current_entity, @tile.hex)

            return false if step.respond_to?(:available_tokens) && step.available_tokens(current_entity).empty?

            already_tokened = (@city.respond_to?(:tokened_by?) && @city.tokened_by?(current_entity)) ||
                              (@city.respond_to?(:tokens) && @city.tokens.compact.any? { |t| t.corporation == current_entity })
            return false if already_tokened

            open_slot = @city.respond_to?(:open_slot?) ? @city.open_slot?(current_entity) : @city.tokens.any?(&:nil?)
            return false unless open_slot

            if @reservation
              res_corp = @reservation.respond_to?(:corporation) ? @reservation.corporation : @reservation
              if res_corp && res_corp != current_entity && (res_corp.respond_to?(:id) ? res_corp.id != current_entity.id : true)
                return false
              end
            end

            true
          end
        end
      end
    end
  end
end

module View
  module Game
    module Part
      class Track < Snabberb::Component
        unless method_defined?(:orig_width_for_index)
          alias orig_width_for_index width_for_index
          alias orig_value_for_index value_for_index

          def width_for_index(path, index, path_indexes)
            base_width = orig_width_for_index(path, index, path_indexes)
            index ? (base_width * 2.5) : base_width
          end

          def value_for_index(index, prop, track)
            if index && prop == :color
              screaming_palette = ['#ff1493', '#00ffff', '#7fff00', '#ff00ff']
              screaming_palette[index.to_i] || '#ff1493'
            else
              orig_value_for_index(index, prop, track)
            end
          end
        end
      end

      class FutureRevenue < Base
        def render
          h(:g)
        end
      end

      class Revenue < Base
        unless method_defined?(:orig_render)
          alias orig_render render

          def render
            rendered = orig_render
            %x{
              function enlargeRevenue(vnode) {
                if (!vnode) return;
                if (Array.isArray(vnode)) {
                  for (var i = 0; i < vnode.length; i++) enlargeRevenue(vnode[i]);
                  return;
                }
                var sel = vnode.sel || '';
                if (typeof sel === 'string' && (sel === 'text' || sel.indexOf('text.') === 0 || sel.indexOf('text#') === 0)) {
                  if (!vnode.data) vnode.data = {};
                  if (!vnode.data.attrs) vnode.data.attrs = {};
                  if (!vnode.data.style) vnode.data.style = {};

                  var cur = parseFloat(vnode.data.style['font-size'] || vnode.data.attrs['font-size']) || 11;
                  var newSize = (cur * 1.35).toFixed(1) + 'px';

                  vnode.data.attrs['font-size'] = newSize;
                  vnode.data.style['font-size'] = newSize;
                  vnode.data.style['font-weight'] = 'bold';
                }
                if (vnode.children && Array.isArray(vnode.children)) {
                  for (var j = 0; j < vnode.children.length; j++) {
                    enlargeRevenue(vnode.children[j]);
                  }
                }
              }
              enlargeRevenue(#{rendered});
            }
            rendered
          end
        end
      end

      class LocationName < Base
        unless method_defined?(:orig_render)
          alias orig_render render

          def render
            rendered = orig_render
            %x{
              function enlargeLocation(vnode) {
                if (!vnode) return;
                if (Array.isArray(vnode)) {
                  for (var i = 0; i < vnode.length; i++) enlargeLocation(vnode[i]);
                  return;
                }
                var sel = vnode.sel || '';
                if (typeof sel === 'string' && (sel === 'text' || sel.indexOf('text.') === 0 || sel.indexOf('text#') === 0)) {
                  if (!vnode.data) vnode.data = {};
                  if (!vnode.data.attrs) vnode.data.attrs = {};
                  if (!vnode.data.style) vnode.data.style = {};

                  var cur = parseFloat(vnode.data.style['font-size'] || vnode.data.attrs['font-size']) || 11;
                  var newSize = (cur * 1.35).toFixed(1) + 'px';

                  vnode.data.attrs['font-size'] = newSize;
                  vnode.data.style['font-size'] = newSize;
                  vnode.data.style['font-weight'] = 'bold';
                }
                if (vnode.children && Array.isArray(vnode.children)) {
                  for (var j = 0; j < vnode.children.length; j++) {
                    enlargeLocation(vnode.children[j]);
                  }
                }
              }
              enlargeLocation(#{rendered});
            }
            rendered
          end
        end
      end
    end
  end
end

module View
  module Game
    class DashboardMap < Snabberb::Component
      include Lib::Settings

      needs :game, store: true
      needs :tile_selector, default: nil, store: true
      needs :selected_route, default: nil, store: true
      needs :selected_company, default: nil, store: true
      needs :selected_combos, default: nil, store: true
      needs :opacity, default: nil
      needs :show_starting_map, default: false, store: true
      needs :routes, default: [], store: true
      needs :historical_laid_hexes, default: nil, store: true
      needs :historical_routes, default: [], store: true
      needs :show_meme_revenue, default: false, store: true

      EDGE_LENGTH = 50
      SIDE_TO_SIDE = 87
      FONT_SIZE = 25
      GAP = 25

      def compute_axes(hexes)
        min, max = hexes.minmax
        (min..max).to_a
      end

      # Register highlighter immediately on load so cyan is active before any layout guards
      %x{
        if (typeof window !== 'undefined') {
          if (!window.__circle_attr_guard_installed) {
            window.__circle_attr_guard_installed = true;
            var origSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
              if (this.tagName && this.tagName.toLowerCase() === 'circle') {
                if ((name === 'cy' || name === 'cx' || name === 'r') &&
                    (value === '' || value == null || value === 'NaN' || value === 'undefined')) {
                  value = '0';
                }
              }
              return origSetAttribute.call(this, name, value);
            };
          }
          window.highlightMapHexes = function(hexIds, _color) {
            if (!hexIds) return;
            window.clearMapHexHighlights();
            var list = Array.isArray(hexIds) ? hexIds : (hexIds.to_a ? hexIds.to_a() : [hexIds]);
            var len = list.length || 0;
            for (var i = 0; i < len; i++) {
              var rawId = String(list[i]);
              var targets = [
                document.getElementById('hex-' + rawId),
                document.querySelector('.hex-' + rawId),
                document.getElementById('hex-' + rawId.toUpperCase()),
                document.querySelector('.hex-' + rawId.toUpperCase()),
                document.getElementById('hex-' + rawId.toLowerCase()),
                document.querySelector('.hex-' + rawId.toLowerCase())
              ];
              for (var t = 0; t < targets.length; t++) {
                var hexEl = targets[t];
                if (hexEl) {
                  var poly = hexEl.querySelector('.hex-highlight-poly');
                  if (poly) {
                    poly.setAttribute('stroke', '#00ffff');
                    poly.setAttribute('stroke-width', '8');
                    poly.setAttribute('fill', '#00ffff');
                    poly.setAttribute('fill-opacity', '0.35');
                  }
                }
              }
            }
          };

          window.clearMapHexHighlights = function() {
            var polys = document.querySelectorAll('.hex-highlight-poly');
            for (var i = 0; i < polys.length; i++) {
              var p = polys[i];
              var origStroke = p.getAttribute('data-orig-stroke') || 'transparent';
              var origWidth = p.getAttribute('data-orig-width') || '0';
              var origFill = p.getAttribute('data-orig-fill') || 'transparent';
              var origFillOpacity = p.getAttribute('data-orig-fill-opacity') || '0';
              p.setAttribute('stroke', origStroke);
              p.setAttribute('stroke-width', origWidth);
              p.setAttribute('fill', origFill);
              p.setAttribute('fill-opacity', origFillOpacity);
            }
          };
        }
      }

      def hex_cost_display(step, entity_or_entities, hex, tile: nil)
        current_entity = Array(entity_or_entities).compact.first
        return nil unless step && current_entity

        base_cost = 0

        target_tile = tile || hex.tile
        if @game.respond_to?(:upgrade_cost)
          begin
            base_cost += @game.upgrade_cost(target_tile, hex, current_entity, current_entity) || 0
          rescue ArgumentError
            begin
              base_cost += @game.upgrade_cost(target_tile, hex, current_entity) || 0
            rescue StandardError
            end
          rescue StandardError
          end
        end

        if step.respond_to?(:get_tile_lay)
          begin
            tile_lay = step.get_tile_lay(current_entity)
            if tile_lay
              extra = hex.tile.color == :white ? (tile_lay[:cost] || 0) : (tile_lay[:upgrade_cost] || 0)
              base_cost += extra || 0
            end
          rescue Exception
          end
        end

        border_objs = (hex.tile&.borders || []).select { |b| b.cost && b.cost.positive? }

        format_val = ->(val) { @game.respond_to?(:format_currency) ? @game.format_currency(val) : "$#{val}" }

        if tile
          tile_exits = []
          if tile.respond_to?(:exits) && tile.exits
            tile_exits = tile.exits
          elsif tile.respond_to?(:paths) && tile.paths
            tile_exits = tile.paths.flat_map do |p|
              if p.respond_to?(:exits) && p.exits
                p.exits
              elsif p.respond_to?(:edges) && p.edges
                p.edges.map(&:num)
              elsif p.respond_to?(:a) && p.respond_to?(:b)
                [p.a, p.b].select { |n| n.respond_to?(:edge?) && n.edge? }.map(&:num)
              end
            end.compact.uniq
          end

          border_cost = nil
          if @game.respond_to?(:border_cost)
            begin
              border_cost = @game.border_cost(tile, hex, current_entity)
            rescue ArgumentError
              begin
                border_cost = @game.border_cost(tile, hex)
              rescue StandardError
              end
            rescue StandardError
            end
          end

          border_cost ||= border_objs.select { |b| tile_exits.include?(b.edge) }.sum(&:cost)
          actual_cost = base_cost + border_cost

          return nil if border_objs.empty? && actual_cost.zero?

          return format_val.call(actual_cost)
        end

        if border_objs.empty?
          return nil if base_cost.zero?

          return @game.respond_to?(:format_currency) ? @game.format_currency(base_cost) : "$#{base_cost}"
        end

        connected_edges = step.respond_to?(:hex_neighbors) ? (step.hex_neighbors(current_entity, hex) || []) : []
        cost_edges = border_objs.map(&:edge)
        border_total = border_objs.sum(&:cost)

        if connected_edges.any? && connected_edges.all? { |e| cost_edges.include?(e) }
          total = base_cost + border_total
          return nil if total.zero?

          return @game.respond_to?(:format_currency) ? @game.format_currency(total) : "$#{total}"
        end

        min_cost = base_cost
        max_cost = base_cost + border_total

        if min_cost.zero?
          "#{format_val.call(max_cost)}?"
        else
          "#{format_val.call(min_cost)}-#{format_val.call(max_cost)}"
        end
      end

      def dashboard_current_entity(step)
        entity = @selected_company
        entity ||= step.current_entity if step&.respond_to?(:current_entity)
        entity ||= @game.round.current_entity if @game.round.respond_to?(:current_entity)
        entity ||= @game.current_entity if @game.respond_to?(:current_entity)
        entity ||= step.active_entities.first if step&.respond_to?(:active_entities)
        entity ||= @game.round.entities.first if @game.round.respond_to?(:entities) && @game.round.operating?
        entity
      rescue NotImplementedError, StandardError
        nil
      end

      def show_meme_revenue?
        return @show_meme_revenue unless @show_meme_revenue.nil?

        Lib::Storage['show_meme_revenue'] || false
      end

      def toggle_meme_revenue
        new_val = !show_meme_revenue?
        Lib::Storage['show_meme_revenue'] = new_val
        store(:show_meme_revenue, new_val)
      end

      def install_revenue_button_bridge
        active = show_meme_revenue?
        %x{
          var selfRef = #{self};

          window.__toggleMemeRevenue = function() {
            if (selfRef && selfRef.$toggle_meme_revenue) {
              selfRef.$toggle_meme_revenue();
            }
          };

          window.__updateMemeBtnState = function(btn) {
            if (!btn) btn = document.getElementById('meme-revenue-toggle-btn');
            if (!btn) return;
            var isActive = #{active};
            btn.style.fontWeight = 'bold';
            btn.style.fontSize = '14px';
            btn.style.cursor = 'pointer';
            btn.style.boxSizing = 'border-box';
            btn.style.visibility = 'visible';
            btn.style.opacity = '1';
            btn.style.lineHeight = '1';
            btn.setAttribute('role', 'checkbox');
            btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
            if (isActive) {
              btn.style.backgroundColor = '#10b981';
              btn.style.color = '#ffffff';
              btn.style.borderColor = '#059669';
            } else {
              btn.style.backgroundColor = '#ffffff';
              btn.style.color = '#363636';
              btn.style.borderColor = '#dbdbdb';
            }
          };

          window.__positionMemeRevenueBtn = function(btn) {
            if (!btn) return;

            // Locate any of the zoom panel buttons (+, -, o / ↺)
            var allButtons = Array.from(document.querySelectorAll('button'));
            var zoomBtn = allButtons.find(function(b) {
              if (b.id === 'meme-revenue-toggle-btn') return false;
              var t = (b.textContent || '').trim();
              return t === '+' || t === '-' || t === '−' || t === 'o' || t === '↺' || t === '⟲' || t === '↻';
            });

            if (zoomBtn && zoomBtn.parentElement) {
              var parent = zoomBtn.parentElement;

              // Ensure the $ button is appended directly inside the same button box
              if (btn.parentElement !== parent) {
                parent.appendChild(btn);
              }

              // Match dimensions and margins from the sibling buttons
              btn.style.position = 'static';
              btn.style.display = 'inline-flex';
              btn.style.alignItems = 'center';
              btn.style.justifyContent = 'center';
              btn.style.width = zoomBtn.offsetWidth ? (zoomBtn.offsetWidth + 'px') : '28px';
              btn.style.height = zoomBtn.offsetHeight ? (zoomBtn.offsetHeight + 'px') : '28px';
              btn.style.marginLeft = '4px';
              btn.style.border = '1px solid #dbdbdb';
              btn.style.borderRadius = '4px';
              btn.style.padding = '0';
              btn.style.zIndex = 'auto';
              return;
            }

            // Fallback if the panel hasn't rendered yet
            if (btn.parentElement !== document.body) {
              document.body.appendChild(btn);
            }
            btn.style.position = 'fixed';
            btn.style.zIndex = '999999';
            btn.style.top = '10px';
            btn.style.left = '10px';
          };

          window.__ensureMemeRevenueBtn = function() {
            var btn = document.getElementById('meme-revenue-toggle-btn');

            if (!btn) {
              btn = document.createElement('button');
              btn.id = 'meme-revenue-toggle-btn';
              btn.className = 'button';
              btn.textContent = '$';
              btn.setAttribute('title', 'Toggle Route Revenue Overlays');
              btn.addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation();
                if (window.__toggleMemeRevenue) {
                  window.__toggleMemeRevenue();
                }
              });
            }

            window.__positionMemeRevenueBtn(btn);
            window.__updateMemeBtnState(btn);
          };

          window.__ensureMemeRevenueBtn();

          if (!window.__meme_btn_observer_installed) {
            window.__meme_btn_observer_installed = true;
            var obs = new MutationObserver(function() {
              if (window.__ensureMemeRevenueBtn) {
                window.__ensureMemeRevenueBtn();
              }
            });
            obs.observe(document.body, { childList: true, subtree: true });

            window.addEventListener('resize', function() {
              var b = document.getElementById('meme-revenue-toggle-btn');
              if (b && window.__positionMemeRevenueBtn) {
                window.__positionMemeRevenueBtn(b);
              }
            });
          }
        }
      end

      def stop_revenue_value(stop, route = nil)
        val = nil

        if route && stop
          if route.respond_to?(:revenue_for)
            begin
              r = route.revenue_for(stop)
              val = r if r.is_a?(Numeric) && r.positive?
            rescue StandardError, ArgumentError
            end
          end
          if val.nil? && stop.respond_to?(:route_revenue)
            begin
              train = route.respond_to?(:train) ? route.train : nil
              r = stop.route_revenue(route, train)
              val = r if r.is_a?(Numeric) && r.positive?
            rescue StandardError, ArgumentError
            end
          end
        end

        if val.nil? && stop.respond_to?(:revenue)
          begin
            r = stop.revenue
            if r.is_a?(Numeric)
              val = r
            elsif r.is_a?(Hash)
              phase_name = @game.phase&.name if @game.respond_to?(:phase)
              val = r[phase_name] || r.values.last
            end
          rescue ArgumentError
            begin
              r = stop.revenue([])
              val = r if r.is_a?(Numeric)
            rescue StandardError
            end
          rescue StandardError
          end
        end

        if val.nil? && stop.respond_to?(:base_revenue)
          begin
            r = stop.base_revenue
            val = r if r.is_a?(Numeric)
          rescue StandardError
          end
        end

        val.to_i
      end

      def hex_meme_revenue_overlay(hex, x, y, routes)
        return nil unless show_meme_revenue?
        return nil unless routes&.any? && hex&.tile

        tile = hex.tile
        tile_stops = if tile.respond_to?(:stops) && tile.stops&.any?
                       tile.stops
                     elsif tile.respond_to?(:cities) && tile.cities&.any?
                       tile.cities
                     else
                       []
                     end
        return nil if tile_stops.empty?

        screaming_palette = ['#ff1493', '#00ffff', '#7fff00', '#ff00ff', '#ffea00', '#ff4500']
        visited_stops_with_route = []

        routes.each_with_index do |route, r_idx|
          r_stops = if route.respond_to?(:visited_stops) && route.visited_stops&.any?
                      route.visited_stops
                    elsif route.respond_to?(:stops) && route.stops
                      route.stops
                    else
                      []
                    end

          tile_stops.each do |ts|
            matches = r_stops.include?(ts) ||
                      r_stops.any? do |rs|
                        rs == ts ||
                          (rs.respond_to?(:hex) && rs.hex == hex) ||
                          (rs.respond_to?(:tile) && rs.tile&.hex == hex)
                      end
            if matches && visited_stops_with_route.none? { |v_ts, _, _| v_ts == ts }
              visited_stops_with_route << [ts, route, r_idx]
            end
          end
        end

        is_visited = visited_stops_with_route.any?

        total_rev = if is_visited
                      visited_stops_with_route.sum { |ts, r, _| stop_revenue_value(ts, r) }
                    else
                      tile_stops.sum { |ts| stop_revenue_value(ts, nil) }
                    end

        return nil if total_rev <= 0

        fill_color = if is_visited
                       first_route = visited_stops_with_route.first[1]
                       first_idx = visited_stops_with_route.first[2]
                       (first_route.respond_to?(:color) && first_route.color) || screaming_palette[first_idx % screaming_palette.size]
                     else
                       '#cbd5e1'
                     end

        text_str = total_rev.to_s
        font_size = 72
        pill_w = [(text_str.length * 48) + 32, 84].max
        pill_h = 76

        h(:g, {
            attrs: {
              transform: "translate(#{x}, #{y})",
              class: 'hex-revenue-meme',
            },
            style: { pointerEvents: 'none' },
          }, [
          h(:rect, {
              attrs: {
                x: (-pill_w / 2.0).round(1).to_s,
                y: (-pill_h / 2.0).round(1).to_s,
                width: pill_w.to_s,
                height: pill_h.to_s,
                rx: '14',
                ry: '14',
                fill: '#0f172a',
                'fill-opacity': is_visited ? '0.85' : '0.65',
                stroke: is_visited ? fill_color : '#475569',
                'stroke-width': is_visited ? '3.5' : '2',
              },
            }),
          h(:text, {
              attrs: {
                x: '0',
                y: '1',
                'text-anchor': 'middle',
                'dominant-baseline': 'central',
                fill: fill_color,
                stroke: '#000000',
                'stroke-width': '8',
                'stroke-linejoin': 'round',
                'paint-order': 'stroke fill',
                'font-family': 'Impact, "Arial Black", sans-serif',
                'font-size': "#{font_size}px",
                'font-weight': '900',
                'pointer-events': 'none',
              },
              style: {
                paintOrder: 'stroke fill',
              },
            }, text_str),
        ])
      end

      def render
        return h(:div, []) if (@layout = @game.layout) == :none

        install_revenue_button_bridge

        @hexes = @show_starting_map ? @game.clone([]).hexes : @game.hexes.dup

        axes_hexes = @hexes.reject(&:ignore_for_axes)
        @cols = compute_axes(axes_hexes.map(&:x))
        @rows = compute_axes(axes_hexes.map(&:y))

        @start_pos = [@cols.first, @rows.first]
        @scale = 1.0

        %x{
          if (typeof window !== 'undefined') {
            window.highlightMapHexes = function(hexIds, _color) {
              if (!hexIds) return;
              window.clearMapHexHighlights();
              var list = Array.isArray(hexIds) ? hexIds : (hexIds.to_a ? hexIds.to_a() : [hexIds]);
              for (var i = 0; i < list.length; i++) {
                var rawId = String(list[i]);
                var targets = [
                  document.getElementById('hex-' + rawId),
                  document.querySelector('.hex-' + rawId),
                  document.getElementById('hex-' + rawId.toUpperCase()),
                  document.querySelector('.hex-' + rawId.toUpperCase())
                ];
                for (var t = 0; t < targets.length; t++) {
                  var hexEl = targets[t];
                  if (hexEl) {
                    var poly = hexEl.querySelector('.hex-highlight-poly');
                    if (poly) {
                      poly.setAttribute('stroke', '#00ffff');
                      poly.setAttribute('stroke-width', '8');
                      poly.setAttribute('fill', '#00ffff');
                      poly.setAttribute('fill-opacity', '0.35');
                    }
                  }
                }
              }
            };

            window.clearMapHexHighlights = function() {
              var polys = document.querySelectorAll('.hex-highlight-poly');
              for (var i = 0; i < polys.length; i++) {
                var p = polys[i];
                p.setAttribute('stroke', p.getAttribute('data-orig-stroke') || 'transparent');
                p.setAttribute('stroke-width', p.getAttribute('data-orig-width') || '0');
                p.setAttribute('fill', p.getAttribute('data-orig-fill') || 'transparent');
                p.setAttribute('fill-opacity', p.getAttribute('data-orig-fill-opacity') || '0');
              }
            };
          }
        }

        step = @game.round.active_step(@selected_company)

        current_entity = dashboard_current_entity(step)
        combo_entities = (@selected_combos || []).map { |id| @game.company_by_id(id) }.compact
        entity_or_entities = combo_entities.empty? ? current_entity : [current_entity, *combo_entities].compact
        actions = step && current_entity ? (step.actions(current_entity) || []) : []

        selected_hex = @tile_selector&.hex
        @hexes << @hexes.delete(selected_hex) if @hexes.include?(selected_hex)

        routes = @routes
        routes = @historical_routes if routes.none?

        track_action_active = actions.include?('lay_tile')
        token_action_active = actions.include?('place_token') || actions.include?('hex_token')

        hovered_c_id = Lib::Storage['hovered_company_id']
        hovered_target_hexes = extract_hovered_hexes(hovered_c_id)

        hex_selected = @tile_selector && !@tile_selector.is_a?(Lib::TokenSelector) &&
                         @tile_selector.respond_to?(:hex) && @tile_selector.hex
        selected_hex = hex_selected ? @tile_selector.hex : nil
        tile_chosen = hex_selected && @tile_selector.tile &&
                      @tile_selector.hex.tile != @tile_selector.tile
        active_tile = tile_chosen ? @tile_selector.tile : nil

        @hexes.map! do |hex|
          clickable = if @show_starting_map || !step || !current_entity
                        false
                      else
                        begin
                          step.available_hex(entity_or_entities, hex)
                        rescue StandardError
                          false
                        end
                      end
          is_hovered = hovered_target_hexes.map(&:to_s).map(&:upcase).include?(hex.id.to_s.upcase)

          base_hex = h(
              Hex,
              hex: hex,
              opacity: @show_starting_map ? 1.0 : (@opacity || 1.0),
              entity: current_entity,
              clickable: hex_selected ? (hex == selected_hex && clickable) : clickable,
              actions: current_entity ? actions : [],
              routes: routes,
              start_pos: @start_pos,
              highlight: false # Disallow legacy red/green home hex fills; rely on breathing tokens and cyan bounds
            )

          # Highlighting Design System: Strict cyan highlight for untokened privates & targeted locations
          border_color = is_hovered ? '#00ffff' : nil
          initial_stroke = border_color || 'transparent'
          initial_width = border_color ? (Hex::HIGHLIGHT_STROKE_WIDTH + 4) : 0
          initial_fill = is_hovered ? '#00ffff' : 'transparent'
          initial_fill_opacity = is_hovered ? '0.35' : '0'

          x, y = Hex.coordinates(hex, @start_pos)
          transform_str = "translate(#{x}, #{y})#{' rotate(30)' if hex.layout == :pointy}"

          overlays = []

          show_building_highlight = if hex_selected
                                      hex == selected_hex
                                    else
                                      clickable && track_action_active && step.respond_to?(:potential_tiles) &&
                                        step.potential_tiles(entity_or_entities, hex).any?
                                    end

          if show_building_highlight
            overlays << h(:polygon, {
                            attrs: {
                              points: Hex::HIGHLIGHT_POINTS,
                              fill: 'url(#cyan-hatch)',
                              'pointer-events': 'none',
                            },
                          })

            overlays << h(:polygon, {
                            attrs: {
                              points: Hex::HIGHLIGHT_POINTS,
                              fill: 'none',
                              stroke: '#00ffff',
                              'stroke-width': '12',
                              'stroke-linejoin': 'round',
                              'stroke-linecap': 'square',
                              pathLength: '576',
                              'stroke-dasharray': '40 56',
                              'stroke-dashoffset': '20',
                              'pointer-events': 'none',
                            },
                          })

            cost_str = if current_entity
                         hex_cost_display(step, entity_or_entities, hex, tile: (hex == selected_hex ? active_tile : nil))
                       end
            if cost_str
              scale_factor = case cost_str.length
                             when 1..3 then 2.2
                             when 4    then 1.7
                             when 5    then 1.3
                             else 1.0
                             end

              rot_angle = hex.layout == :pointy ? 60 : 90

              overlays << h(:g, { attrs: { 'pointer-events': 'none' } }, [
                h(:polygon, {
                    attrs: {
                      points: '8.5,-80 48.5,-80 76.5,-32 36.5,-32',
                      fill: '#0f172a',
                      stroke: '#00ffff',
                      'stroke-width': '2.5',
                      'stroke-linejoin': 'round',
                    },
                  }),
                h(:g, {
                    attrs: {
                      transform: "translate(42.5, -56) rotate(#{rot_angle}) scale(#{scale_factor})",
                    },
                  }, [
                  h(:text, {
                      attrs: {
                        x: '0',
                        y: '0',
                        'text-anchor': 'middle',
                        'dominant-baseline': 'central',
                        fill: '#00ffff',
                        'font-weight': '900',
                        'font-family': 'Arial, Helvetica, sans-serif',
                        'letter-spacing': '-0.5px',
                      },
                    }, cost_str),
                ]),
              ])
            end
          end
          initial_stroke = border_color || 'transparent'
          initial_width = border_color ? (Hex::HIGHLIGHT_STROKE_WIDTH + 4) : 0
          initial_fill = is_hovered ? '#00ffff' : 'transparent'
          initial_fill_opacity = is_hovered ? '0.35' : '0'

          hex_children = [
            base_hex,
            h(:g, {
                attrs: {
                  transform: transform_str,
                  class: 'hex-highlight-wrapper',
                },
                style: { pointerEvents: 'none' },
              }, [
              h(:polygon, {
                  attrs: {
                    points: Hex::HIGHLIGHT_POINTS,
                    class: 'hex-highlight-poly',
                    'data-orig-stroke': initial_stroke,
                    'data-orig-width': initial_width.to_s,
                    'data-orig-fill': initial_fill,
                    'data-orig-fill-opacity': initial_fill_opacity,
                    stroke: initial_stroke,
                    'stroke-width': initial_width.to_s,
                    fill: initial_fill,
                    'fill-opacity': initial_fill_opacity,
                  },
                  style: { pointerEvents: 'none' },
                }),
              *overlays,
            ]),
          ]

          meme_overlay = hex_meme_revenue_overlay(hex, x, y, routes)
          hex_children << meme_overlay if meme_overlay

          g_props = {
            key: "dash-g-#{hex.id}",
            attrs: {
              id: "hex-#{hex.id}",
              class: "map-hex-container hex-#{hex.id}",
              'data-hex': hex.id.to_s,
              'data-tile-state': "#{hex.tile.name}-#{hex.tile.color}-#{hex.tile.rotation}",
              'data-transform': transform_str,
            },
            hook: Lib::TileLayAnimation.hook,
          }

          h(:g, g_props, hex_children)
        end
        @hexes.compact!

        map_w, map_h = map_size
        children = [render_map(map_w, map_h)]

        if current_entity && @tile_selector
          left = (@tile_selector.x + map_x) * @scale
          top = (@tile_selector.y + map_y) * @scale
          selector = render_selector(step, current_entity, entity_or_entities, actions, map_w, map_h, left, top)

          props = {
            style: { position: 'absolute', left: "#{left}px", top: "#{top}px" },
          }
          children.unshift(h(:div, props, [selector]))
        end

        props = {
          style: { width: 'max-content', height: 'max-content', margin: '0', position: 'relative' },
        }
        h(:div, props, children)
      end

      def render_selector(step, current_entity, entity_or_entities, actions, map_w, map_h, left, top)
        if @tile_selector.is_a?(Lib::TokenSelector)
          h(TokenSelector, zoom: 1.0)
        elsif @tile_selector.role != :map
        elsif @tile_selector.hex.tile != @tile_selector.tile
          h(TileConfirmation, zoom: 1.0)
        else
          tiles = step.upgradeable_tiles(entity_or_entities, @tile_selector.hex)
          all_upgrades = @game.all_potential_upgrades(@tile_selector.hex.tile, selected_company: @selected_company)
          phase_colors = step.potential_tile_colors(current_entity, @tile_selector.hex)
          select_tiles = all_upgrades.map do |tile|
            real_tile = tiles.find { |t| t.name == tile.name }
            if real_tile
              tiles.delete(real_tile)
              [real_tile, nil]
            elsif !@game.tile_valid_for_phase?(tile, hex: @tile_selector.hex, phase_color_cache: phase_colors)
              [tile, 'Later Phase']
            elsif @game.tiles.none? { |t| t.name == tile.name }
              [tile, 'None Left']
            end
          end.compact

          select_tiles.append(*tiles.map { |t| [t, nil] })

          return h(:div) if select_tiles.empty?

          distance = TileSelector::DISTANCE * 1.0
          ts_ds = [TileSelector::DROP_SHADOW_SIZE - 5, 0].max

          h(TileSelector, layout: @layout, tiles: select_tiles, actions: actions, zoom: 1.0,
                          top_row: (top < distance),
                          left_col: (left < distance),
                          right_col: (map_w - left < distance + ts_ds),
                          bottom_row: (map_h - top < distance + ts_ds))
        end
      end

      def extract_hovered_hexes(hovered_c_id)
        return [] unless hovered_c_id

        target_hexes = []
        all_companies = @game.respond_to?(:companies) ? (@game.companies || []) : []

        hovered_company = all_companies.find do |c|
          c.id.to_s == hovered_c_id || (c.respond_to?(:sym) && c.sym.to_s == hovered_c_id)
        end ||
                          (if @game.respond_to?(:minors)
                             @game.minors.find do |m|
                               m.id.to_s == hovered_c_id || (m.respond_to?(:sym) && m.sym.to_s == hovered_c_id)
                             end
                           end) ||
                          @game.corporations.find do |corp|
                            corp.id.to_s == hovered_c_id || (corp.respond_to?(:sym) && corp.sym.to_s == hovered_c_id)
                          end

        if hovered_company
          # If the hovered entity has placed tokens on the board, breathing tokens are sufficient.
          # Suppress hex highlights completely for tokened entities.
          has_placed = false
          if hovered_company.respond_to?(:tokens) && hovered_company.tokens
            has_placed = hovered_company.tokens.any? do |t|
              (t.respond_to?(:placed?) && t.placed?) || (t.respond_to?(:city) && t.city&.hex) || (t.respond_to?(:hex) && t.hex)
            end
          end
          return [] if has_placed

          if hovered_company.respond_to?(:coordinates) && hovered_company.coordinates
            Array(hovered_company.coordinates).each { |coord| target_hexes << coord.to_s }
          end
          if hovered_company.respond_to?(:city) && hovered_company.city&.respond_to?(:hex)
            target_hexes << hovered_company.city.hex.id.to_s
          end

          abilities = []
          if hovered_company.respond_to?(:all_abilities) && hovered_company.all_abilities
            abilities.concat(hovered_company.all_abilities)
          end
          abilities.concat(hovered_company.abilities) if hovered_company.respond_to?(:abilities) && hovered_company.abilities

          if @game.class.const_defined?(:COMPANIES)
            raw_def = @game.class::COMPANIES.find do |c_def|
              c_def[:sym].to_s == hovered_c_id || c_def[:name].to_s == hovered_c_id
            end
            if raw_def && raw_def[:abilities]
              raw_def[:abilities].each do |raw_ab|
                Array(raw_ab[:hexes]).each { |coord| target_hexes << coord.to_s } if raw_ab[:hexes]
                target_hexes << raw_ab[:hex].to_s if raw_ab[:hex]
              end
            end
          end

          abilities.each do |ab|
            Array(ab.hexes).each { |coord| target_hexes << coord.to_s } if ab.respond_to?(:hexes) && ab.hexes
            target_hexes << (ab.hex.respond_to?(:id) ? ab.hex.id : ab.hex).to_s if ab.respond_to?(:hex) && ab.hex
            Array(ab.coordinates).each { |coord| target_hexes << coord.to_s } if ab.respond_to?(:coordinates) && ab.coordinates

            target_corp = nil
            if ab.respond_to?(:corporation) && ab.corporation
              target_corp = @game.corporation_by_id(ab.corporation) || ab.corporation
            elsif ab.respond_to?(:minor) && ab.minor
              target_corp = (@game.respond_to?(:minor_by_id) ? @game.minor_by_id(ab.minor) : nil) || ab.minor
            end
            next unless target_corp && target_corp.respond_to?(:coordinates) && target_corp.coordinates

            Array(target_corp.coordinates).each do |coord|
              target_hexes << coord.to_s
            end
          end

          if hovered_company.respond_to?(:desc) && hovered_company.desc
            hovered_company.desc.scan(/\b[A-Za-z]\d{1,2}\b/).each do |h_id|
              target_hexes << h_id.upcase if @game.hex_by_id(h_id) || @game.hex_by_id(h_id.upcase)
            end
          end
        end
        target_hexes.uniq
      end

      def map_x
        GAP + FONT_SIZE
      end

      def map_y
        GAP + FONT_SIZE + (@layout == :flat ? (FONT_SIZE / 2.0) : FONT_SIZE)
      end

      def map_size
        if @layout == :flat
          [((((@cols.size * 1.5) + 0.5) * EDGE_LENGTH) + (2 * GAP)) * @scale,
           ((((@rows.size / 2.0) + 0.5) * SIDE_TO_SIDE) + (2 * GAP)) * @scale]
        else
          [(((((@cols.size / 2.0) + 0.5) * SIDE_TO_SIDE) + (2 * GAP)) + 1) * @scale,
           ((((@rows.size * 1.5) + 0.5) * EDGE_LENGTH) + (2 * GAP)) * @scale]
        end
      end

      def render_map(width, height)
        h(:svg, { attrs: { id: 'map', width: width.to_s, height: height.to_s } }, [
          h(:defs, [
            h(:pattern, {
                attrs: {
                  id: 'cyan-hatch',
                  width: '16',
                  height: '16',
                  patternUnits: 'userSpaceOnUse',
                  patternTransform: 'rotate(45)',
                },
              }, [
              h(:line, {
                  attrs: {
                    x1: '0',
                    y1: '0',
                    x2: '0',
                    y2: '16',
                    stroke: '#00ffff',
                    'stroke-width': '3.5',
                    'stroke-opacity': '0.5',
                  },
                }),
            ]),
          ]),

          h(:g, { attrs: { transform: "scale(#{@scale})" } }, [
            h(:g, { attrs: { id: 'map-hexes', transform: "translate(#{map_x} #{map_y})" } }, @hexes),
            h(Axis,
              cols: @cols,
              rows: @rows,
              axes: @game.axes,
              layout: @layout,
              font_size: FONT_SIZE,
              gap: GAP,
              map_x: map_x,
              map_y: map_y,
              start_pos: @start_pos),
          ]),
        ])
      end

      def map_zoom
        Lib::Storage['map_zoom'] || 1
      end
    end
  end
end
