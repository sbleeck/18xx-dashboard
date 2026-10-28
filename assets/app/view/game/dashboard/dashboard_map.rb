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

# Inside assets/app/view/game/dashboard/dashboard_map.rb
module View
  module Game
    class Token < Snabberb::Component
      unless method_defined?(:orig_pulse_render)
        alias orig_pulse_render render

        def render
          rendered = orig_pulse_render
          corp = @corporation || (@token.respond_to?(:corporation) ? @token.corporation : nil)
          return rendered unless corp

          corp_id = corp.id.to_s
          safe_id = `CSS.escape(#{corp_id})`

          %x{
          if (#{rendered} && #{rendered}.data) {
            if (!#{rendered}.data.attrs) #{rendered}.data.attrs = {};
            var existingCls = #{rendered}.data.attrs['class'] || #{rendered}.data.class || '';
            var addCls = 'map-token map-token-' + #{safe_id};
            #{rendered}.data.attrs['class'] = (existingCls + ' ' + addCls).trim();
            #{rendered}.data.attrs['data-corp'] = #{corp_id};
            if (!#{rendered}.data.style) #{rendered}.data.style = {};
            #{rendered}.data.style['cursor'] = 'pointer';
            #{rendered}.data.style['pointer-events'] = 'auto';
          }
        }
          rendered
        end
      end
    end
  end
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

            // Keep the actual laid hex where it belongs. Put the visual animation
            // in a dedicated SVG overlay layer that is always the final child of the
            // dashboard map, so neighbouring/later-rendered tiles cannot cover it.
            var mapSvg = hexContainer.ownerSVGElement;
            if (!mapSvg) return;
            var overlayLayer = mapSvg.querySelector('#dashboard-tile-animation-layer');
            if (!overlayLayer) {
              overlayLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
              overlayLayer.setAttribute('id', 'dashboard-tile-animation-layer');
              overlayLayer.setAttribute('pointer-events', 'none');
              mapSvg.appendChild(overlayLayer);
            } else if (overlayLayer.parentNode === mapSvg && overlayLayer !== mapSvg.lastChild) {
              mapSvg.appendChild(overlayLayer);
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
            overlayLayer.appendChild(shockwaveGroup);

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

            rendered_children = `Array.isArray(#{rendered}) ? #{rendered} : [#{rendered}]`
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

      # Dashboard Map 2.0: one financial visual language.
      #
      # This is the single size control for every map cost/revenue label.
      # All backgrounds are sized in em units, so they grow and shrink
      # with the money font.
      MAP_MONEY_SCALE = 1.5

      MAP_MONEY_FONT = "'Courier New', monospace"
      MAP_MONEY_COLOR = '#4c1d95'
      MAP_MONEY_NEGATIVE_COLOR = '#ffffff'

      module DashboardRevenueBadge
        FONT_SIZE = 17 * MAP_MONEY_SCALE
        PURPLE_NEGATIVE = '#b3e26a'

        def revenue_badge(text, x: 0, y: 0, fill: '#ffffff', phase: nil)
          text = text.to_s

          radius =
            case text.length
            when 1..2 then 0.72
            when 3    then 0.84
            else           0.96
            end

          text_color =
            if phase.to_s == 'brown'
              PURPLE_NEGATIVE
            else
              MAP_MONEY_COLOR
            end

          h(
            :g,
            {
              attrs: {
                transform: "translate(#{x} #{y})",
                class: 'dashboard-money dashboard-revenue-badge',
                'font-size': "#{FONT_SIZE}px",
              },
            },
            [
              h(:circle, {
                  attrs: {
                    cx: '0',
                    cy: '0',
                    r: "#{radius}em",
                    fill: fill,
                    stroke: '#777777',
                    'stroke-width': '0.08em',
                  },
                }),
              h('text.number', {
                  attrs: {
                    x: '0',
                    y: '0',
                    fill: text_color,
                    stroke: 'none',
                    'text-anchor': 'middle',
                    'dominant-baseline': 'central',
                    'alignment-baseline': 'central',
                    'font-family': MAP_MONEY_FONT,
                    'font-weight': '700',
                  },
                }, text),
            ]
          )
        end
      end

      class SingleRevenue < Snabberb::Component
        include DashboardRevenueBadge

        def render
          return h(:g) if @revenue.zero? && !@force

          h(
            :g,
            {
              attrs: {
                transform: @transform,
                class: 'dashboard-money dashboard-revenue dashboard-single-revenue',
              },
            },
            [
              revenue_badge(@revenue),
            ]
          )
        end
      end

      class MultiRevenue < Snabberb::Component
        include DashboardRevenueBadge

        def render
          computed_revenues = @revenues.map do |phase, revenue|
            display_phase = phase == :diesel ? :gray : phase

            fill =
              if display_phase.to_s.start_with?('#')
                display_phase
              else
                color_for(display_phase)
              end

            {
              text: "#{'D' if phase == :diesel}#{revenue}",
              fill: fill,
              phase: display_phase,
            }
          end

          rows = [@rows.to_i, 1].max
          step_size = (computed_revenues.size / rows.to_f).ceil

          badge_diameter = DashboardRevenueBadge::FONT_SIZE * 1.44
          horizontal_gap = DashboardRevenueBadge::FONT_SIZE * 0.18
          vertical_gap = DashboardRevenueBadge::FONT_SIZE * 0.18

          horizontal_step = badge_diameter + horizontal_gap
          vertical_step = badge_diameter + vertical_gap

          children = []

          computed_revenues.each_slice(step_size).with_index do |row_revenues, row|
            row_width = (row_revenues.size - 1) * horizontal_step
            start_x = -(row_width * 0.5)
            start_y = row * vertical_step

            row_revenues.each_with_index do |revenue, column|
              x = start_x + (column * horizontal_step)

              children << revenue_badge(
                revenue[:text],
                x: x,
                y: start_y,
                fill: revenue[:fill],
                phase: revenue[:phase]
              )
            end
          end

          rendered_rows = (computed_revenues.size / step_size.to_f).ceil
          content_height = (rendered_rows - 1) * vertical_step
          vertical_centering = -(content_height * 0.5)

          h(
            :g,
            {
              attrs: {
                transform: @transform,
                class: 'dashboard-money dashboard-revenue dashboard-multi-revenue',
              },
            },
            [
              h(
                :g,
                {
                  attrs: {
                    transform: "translate(0 #{vertical_centering})",
                  },
                },
                children
              ),
            ]
          )
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
      needs :hovered_routes, default: [], store: true
      needs :show_meme_revenue, default: nil, store: true
      needs :show_location_names, default: nil, store: true
      needs :simple_logos, default: nil, store: true

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


          window.highlightMapHexes = function(hexIds, _color) {
            if (!hexIds) return;
            var dashboard = document.getElementById('viz-master-frame');
            if (!dashboard) return;
            window.clearMapHexHighlights();
            var list = Array.isArray(hexIds) ? hexIds : (hexIds.to_a ? hexIds.to_a() : [hexIds]);
            var len = list.length || 0;
for (var i = 0; i < list.length; i++) {
              var rawId = String(list[i]);
             var targets = [
  dashboard.querySelector('#hex-' + rawId),
  dashboard.querySelector('.hex-' + rawId),
  dashboard.querySelector('#hex-' + rawId.toUpperCase()),
  dashboard.querySelector('.hex-' + rawId.toUpperCase()),
  dashboard.querySelector('#hex-' + rawId.toLowerCase()),
  dashboard.querySelector('.hex-' + rawId.toLowerCase())
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
var dashboard = document.getElementById('viz-master-frame');
if (!dashboard) return;
var polys = dashboard.querySelectorAll('.hex-highlight-poly');
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
          rescue StandardError
          end
        end

        border_objs = (hex.tile&.borders || []).select { |b| b.cost&.positive? }

        format_val = ->(val) { val.to_i.to_s }

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

          return format_val.call(base_cost)
        end

        connected_edges = step.respond_to?(:hex_neighbors) ? (step.hex_neighbors(current_entity, hex) || []) : []
        cost_edges = border_objs.map(&:edge)
        border_total = border_objs.sum(&:cost)

        if connected_edges.any? && connected_edges.all? { |e| cost_edges.include?(e) }
          total = base_cost + border_total
          return nil if total.zero?

          return format_val.call(total)
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
        entity ||= step.current_entity if step.respond_to?(:current_entity)
        entity ||= @game.round.current_entity if @game.round.respond_to?(:current_entity)
        entity ||= @game.current_entity if @game.respond_to?(:current_entity)
        entity ||= step.active_entities.first if step.respond_to?(:active_entities)
        entity ||= @game.round.entities.first if @game.round.respond_to?(:entities) && @game.round.operating?
        entity
      rescue NotImplementedError, StandardError
        nil
      end

      def show_meme_revenue?
        stored = [true, 'true'].include?(Lib::Storage['show_meme_revenue'])
        return stored if @show_meme_revenue.nil?

        @show_meme_revenue
      end

      def resolve_revenue_val(raw, tile_color = nil)
        return raw.to_i if raw.is_a?(Numeric)
        return raw.to_i if raw.is_a?(String) && raw =~ /^\d+$/
        return 0 unless raw.is_a?(Hash) && !raw.empty?

        phase = @game.phase if @game.respond_to?(:phase)
        p_name = phase&.name.to_s if phase

        # // --- START FIX ---
        # 1. Direct phase name or number match
        candidates = [
          p_name,
          p_name&.to_sym,
          (p_name.to_i if /^\d+$/.match?(p_name)),
        ].compact

        candidates.each do |k|
          val = raw[k]
          return val.to_i if val.is_a?(Numeric)
          return val.to_i if val.is_a?(String) && val =~ /^\d+$/
        end

        # 2. Check active phase tile colors in reverse order (e.g. [:yellow, :green, :brown, :gray])
        phase_tiles = if phase.respond_to?(:tiles) && phase.tiles&.any?
                        phase.tiles.map(&:to_s)
                      else
                        []
                      end

        phase_tiles.reverse_each do |color_str|
          [color_str.to_sym, color_str].each do |k|
            val = raw[k]
            return val.to_i if val.is_a?(Numeric)
            return val.to_i if val.is_a?(String) && val =~ /^\d+$/
          end
        end

        # 3. Numeric phase progression match (highest phase key in hash <= current phase)
        curr_phase_num = p_name[/\d+/]&.to_i
        if curr_phase_num&.positive?
          matching_keys = raw.keys.select do |k|
            k_num = k.is_a?(Numeric) ? k.to_i : k.to_s[/\d+/]&.to_i
            k_num && k_num <= curr_phase_num
          end
          if matching_keys.any?
            best_key = matching_keys.max_by { |k| k.is_a?(Numeric) ? k.to_i : k.to_s[/\d+/].to_i }
            val = raw[best_key]
            return val.to_i if val.is_a?(Numeric)
            return val.to_i if val.is_a?(String) && val =~ /^\d+$/
          end
        end

        # 4. Active tile_color fallback if permitted in the current phase
        if tile_color && (phase_tiles.empty? || phase_tiles.include?(tile_color.to_s))
          [tile_color.to_s, tile_color.to_sym].each do |k|
            val = raw[k]
            return val.to_i if val.is_a?(Numeric)
            return val.to_i if val.is_a?(String) && val =~ /^\d+$/
          end
        end

        # 5. Default to the initial phase revenue instead of the maximum end-game revenue
        # // --- DELETE --- raw.values.last.to_i
        raw.values.first.to_i
        # // --- END FIX ---
      end

      def stop_base_revenue(stop)
        return 0 unless stop

        raw = nil
        begin
          raw = stop.instance_variable_get(:@revenue)
        rescue StandardError
        end

        if raw.nil?
          begin
            raw = stop.instance_variable_get(:@base_revenue)
          rescue StandardError
          end
        end

        if raw.nil?
          begin
            raw = stop.instance_variable_get(:@revenues)
          rescue StandardError
          end
        end

        if raw.nil? && stop.respond_to?(:base_revenue)
          begin
            raw = stop.base_revenue
          rescue ArgumentError
            begin
              raw = stop.base_revenue(@game.phase) if @game.respond_to?(:phase)
            rescue StandardError
            end
          rescue StandardError
          end
        end

        if raw.nil? && stop.respond_to?(:revenue)
          begin
            r = stop.revenue
            raw = r if r.is_a?(Numeric) || r.is_a?(Hash)
          rescue StandardError
          end
        end

        if raw.nil?
          raw = %x{
            (function() {
              if (!stop) return null;
              if (typeof stop.revenue === 'number') return stop.revenue;
              if (typeof stop.base_revenue === 'number') return stop.base_revenue;
              if (stop.revenue && typeof stop.revenue === 'object') return stop.revenue;
              if (stop.revenues && typeof stop.revenues === 'object') return stop.revenues;
              if (typeof stop.$base_revenue === 'function') {
                try { return stop.$base_revenue(); } catch(e) {}
              }
              return null;
            })()
          }
        end

        if raw.respond_to?(:revenue)
          begin
            raw = raw.revenue
          rescue StandardError
          end
        end

        t_color = (stop.respond_to?(:tile) && stop.tile&.color) ||
                  (stop.respond_to?(:hex) && stop.hex&.tile&.color)

        val = resolve_revenue_val(raw, t_color)
        return val if val.positive?

        tile = stop.respond_to?(:tile) ? stop.tile : nil
        if tile
          parts = tile.respond_to?(:parts) ? (tile.parts || []) : []
          parts.each do |p|
            next unless p.class.name.to_s.include?('Revenue') ||
                        (p.respond_to?(:revenue) && !p.respond_to?(:paths) && !p.respond_to?(:slots))

            p_raw = p.respond_to?(:revenue) ? p.revenue : nil
            p_val = resolve_revenue_val(p_raw, tile.color)
            return p_val if p_val.positive?
          end
        end

        0
      end

      def tile_base_revenue(tile)
        return 0 unless tile

        parts = tile.respond_to?(:parts) ? (tile.parts || []) : []
        rev_parts = parts.select do |p|
          p.class.name.to_s.include?('Revenue') ||
            (p.respond_to?(:revenue) && !p.respond_to?(:paths) && !p.respond_to?(:slots))
        end

        return 0 if rev_parts.empty?

        rev_parts.sum do |p|
          raw = p.respond_to?(:revenue) ? p.revenue : nil
          resolve_revenue_val(raw, tile.color)
        end
      end

      def install_revenue_button_bridge
        active = show_meme_revenue?
        %x{
          var selfRef = #{self};
          window.__updateMemeBtnState = function() {
            var btn = document.getElementById('meme-revenue-toggle-btn');
            if (!btn) return;
            var isActive = #{active};
            try {
              var stored = localStorage.getItem('show_meme_revenue');
              if (stored !== null && stored !== undefined) {
                isActive = stored === 'true';
              }
            } catch(e) {}
            btn.setAttribute('role', 'checkbox');
            btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
            btn.style.backgroundColor = isActive ? '#10b981' : '#ffffff';
            btn.style.color = isActive ? '#ffffff' : '#333333';
            btn.style.borderColor = isActive ? '#059669' : '#999999';
          };
          window.__toggleMemeRevenue = function() {
            if (selfRef && selfRef.$toggle_meme_revenue) selfRef.$toggle_meme_revenue();
          };
          setTimeout(function() {
            if (window.__updateMemeBtnState) window.__updateMemeBtnState();
          }, 0);
        }
      end

      def stop_revenue_value(stop, route = nil)
        if route && stop
          if route.respond_to?(:revenue_for)
            begin
              r = route.revenue_for(stop)
              return r.to_i if r.is_a?(Numeric) && r.positive?
            rescue StandardError
            end
          end
          if stop.respond_to?(:route_revenue)
            begin
              train = route.respond_to?(:train) ? route.train : nil
              r = stop.route_revenue(route, train)
              return r.to_i if r.is_a?(Numeric) && r.positive?
            rescue StandardError
            end
          end
        end

        stop_base_revenue(stop)
      end

      def hex_meme_revenue_overlay(hex, x, y, routes)
        return nil unless show_meme_revenue?
        return nil unless hex&.tile

        tile = hex.tile
        tile_stops = if tile.respond_to?(:stops) && tile.stops&.any?
                       tile.stops
                     else
                       stops = []
                       stops.concat(tile.cities) if tile.respond_to?(:cities) && tile.cities
                       stops.concat(tile.towns) if tile.respond_to?(:towns) && tile.towns
                       stops.concat(tile.offboards) if tile.respond_to?(:offboards) && tile.offboards
                       stops
                     end

        return nil if tile_stops.empty? && tile_base_revenue(tile).zero?

        screaming_palette = ['#ff1493', '#00ffff', '#7fff00', '#ff00ff', '#ffea00', '#ff4500']
        visited_stops_with_route = []

        active_routes = Array(routes).select { |r| r.respond_to?(:paths_for) }

        if active_routes.any? && tile_stops.any?
          active_routes.each_with_index do |route, r_idx|
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
        end

        is_visited = visited_stops_with_route.any?

        cities = tile.respond_to?(:cities) ? (tile.cities || []) : []
        offboards = tile.respond_to?(:offboards) ? (tile.offboards || []) : []
        towns = tile.respond_to?(:towns) ? (tile.towns || []) : []

        total_rev = if cities.any?
                      city = cities.first
                      if is_visited
                        v_city = visited_stops_with_route.find { |ts, _, _| cities.include?(ts) }
                        v_city ? stop_revenue_value(v_city[0], v_city[1]) : stop_base_revenue(city)
                      else
                        stop_base_revenue(city)
                      end
                    elsif offboards.any?
                      ob = offboards.first
                      if is_visited
                        v_ob = visited_stops_with_route.find { |ts, _, _| offboards.include?(ts) }
                        v_ob ? stop_revenue_value(v_ob[0], v_ob[1]) : stop_base_revenue(ob)
                      else
                        stop_base_revenue(ob)
                      end
                    elsif towns.any?
                      tw = towns.first
                      if is_visited
                        v_tw = visited_stops_with_route.find { |ts, _, _| towns.include?(ts) }
                        v_tw ? stop_revenue_value(v_tw[0], v_tw[1]) : stop_base_revenue(tw)
                      else
                        stop_base_revenue(tw)
                      end
                    else
                      tile_base_revenue(tile)
                    end

        return nil if total_rev <= 0

        fill_color = if is_visited
                       first_route = visited_stops_with_route.first[1]
                       first_idx = visited_stops_with_route.first[2]
                       (first_route.respond_to?(:color) && first_route.color) || screaming_palette[first_idx % screaming_palette.size]
                     else
                       '#334155'
                     end

        # // --- START FIX ---
        text_str = total_rev.to_s
        font_size = 44
        pill_w = [(text_str.length * 24) + 20, 56].max
        pill_h = 48
        # // --- DELETE --- font_size = 28
        # // --- DELETE --- pill_w = [(text_str.length * 17) + 16, 46].max
        # // --- DELETE --- pill_h = 32
        # // --- END FIX ---

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
                # // --- START FIX ---
                rx: '8',
                ry: '8',
                fill: '#ffffff',
                'fill-opacity': '0.92',
                stroke: is_visited ? fill_color : '#334155',
                'stroke-width': is_visited ? '3.5' : '1.5',
                # // --- DELETE --- rx: '7',
                # // --- DELETE --- ry: '7',
                # // --- DELETE --- fill: '#0f172a',
                # // --- DELETE --- 'fill-opacity': is_visited ? '0.85' : '0.65',
                # // --- DELETE --- stroke: is_visited ? fill_color : '#475569',
                # // --- DELETE --- 'stroke-width': is_visited ? '2.5' : '1.5',
                # // --- END FIX ---
              },
            }),
          h(:text, {
              attrs: {
                x: '0',
                y: '1',
                'text-anchor': 'middle',
                'dominant-baseline': 'central',
                # // --- START FIX ---
                fill: '#000000',
                stroke: 'none',
                'font-family': "'Courier New', monospace",
                'font-size': "#{font_size}px",
                'font-weight': '900',
                'pointer-events': 'none',
                # // --- DELETE --- fill: '#4c1d95',
                # // --- DELETE --- stroke: '#ffffff',
                # // --- DELETE --- 'stroke-width': '3.5',
                # // --- DELETE --- 'stroke-linejoin': 'round',
                # // --- DELETE --- 'paint-order': 'stroke fill',
                # // --- END FIX ---
              },
            }, text_str),
        ])
      end

      # File: dashboard_map.rb
      # Method: render

      def render
        return h(:div, []) if (@layout = @game.layout) == :none

        install_revenue_button_bridge

        @hexes = @show_starting_map ? @game.clone([]).hexes : @game.hexes.dup

        axes_hexes = @hexes.reject(&:ignore_for_axes)
        @cols = compute_axes(axes_hexes.map(&:x))
        @rows = compute_axes(axes_hexes.map(&:y))

        @start_pos = [@cols.first, @rows.first]
        @scale = 1.0

        step = @game.round.active_step(@selected_company)

        current_entity = dashboard_current_entity(step)
        combo_entities = (@selected_combos || []).map { |id| @game.company_by_id(id) }.compact
        entity_or_entities = combo_entities.empty? ? current_entity : [current_entity, *combo_entities].compact
        actions = step && current_entity ? (step.actions(current_entity) || []) : []

        selected_hex = @tile_selector&.hex
        @hexes << @hexes.delete(selected_hex) if @hexes.include?(selected_hex)

        route_actions = %w[run_routes dividend]
        route_phase_active = actions.any? { |a| route_actions.include?(a) }
        is_history_mode = (@game.respond_to?(:historical?) && @game.historical?) || @historical_laid_hexes

        hovered_last_id = Lib::Storage['hovered_last_corp']
        hovered_corp = if hovered_last_id
                         all_corps = (@game.respond_to?(:all_corporations) ? @game.all_corporations : @game.corporations) || []
                         all_corps.find { |c| c.id.to_s == hovered_last_id.to_s } ||
                           ((@game.minors || []).find { |m| m.id.to_s == hovered_last_id.to_s } if @game.respond_to?(:minors))
                       end

        hovered_routes = []
        if hovered_corp
          begin
            actions_list = []
            actions_list = @game_data['actions'] || @game_data[:actions] || [] if defined?(@game_data) && @game_data
            if actions_list.empty? && respond_to?(:game_data) && game_data
              actions_list = game_data['actions'] || game_data[:actions] || []
            end
            actions_list = @game.raw_actions || [] if actions_list.empty? && @game.respond_to?(:raw_actions)
            actions_list = @game.actions || [] if actions_list.empty? && @game.respond_to?(:actions)

            run_action = actions_list.reverse.find do |act|
              a_type = if act.is_a?(Hash)
                         act['type'] || act[:type]
                       else
                         (act.respond_to?(:type) ? act.type : nil)
                       end
              a_ent = if act.is_a?(Hash)
                        act['entity'] || act[:entity]
                      else
                        (if act.respond_to?(:entity)
                           act.entity.respond_to?(:id) ? act.entity.id : act.entity
                         end)
                      end
              a_type.to_s == 'run_routes' && a_ent.to_s == hovered_corp.id.to_s
            end

            raw_routes = if run_action
                           if run_action.is_a?(Hash)
                             run_action['routes'] || run_action[:routes]
                           else
                             (run_action.respond_to?(:routes) ? run_action.routes : [])
                           end
                         else
                           []
                         end

            hovered_routes = Array(raw_routes).map do |r|
              if r.respond_to?(:paths_for)
                r
              elsif r.is_a?(Hash) && defined?(Engine::Route)
                train_id = r['train'] || r[:train]
                train = (hovered_corp.trains.find { |t| t.id == train_id } if hovered_corp.respond_to?(:trains)) ||
                        (@game.train_by_id(train_id) if @game.respond_to?(:train_by_id)) ||
                        (@game.trains.find { |t| t.id == train_id } if @game.respond_to?(:trains)) ||
                        (hovered_corp.trains.first if hovered_corp.respond_to?(:trains) && hovered_corp.trains&.any?) ||
                        (@game.trains.first if @game.respond_to?(:trains) && @game.trains&.any?)

                conn = r['connections'] || r[:connections] || r['connection_hexes'] || r[:connection_hexes]
                hexes = r['hexes'] || r[:hexes]
                routes_param = r['routes'] || r[:routes]
                phase = @game.respond_to?(:phase) ? @game.phase : nil

                if train
                  begin
                    Engine::Route.new(@game, phase, train, connection_hexes: conn, hexes: hexes, routes: routes_param)
                  rescue ArgumentError
                    begin
                      Engine::Route.new(@game, phase, train, connection_hexes: conn, hexes: hexes)
                    rescue ArgumentError
                      begin
                        Engine::Route.new(@game, phase, train, connection_hexes: conn)
                      rescue StandardError
                        nil
                      end
                    rescue StandardError
                      nil
                    end
                  rescue StandardError
                    nil
                  end
                end
              end
            end.compact.select { |r| r.respond_to?(:paths_for) }
          rescue StandardError
            hovered_routes = []
          end
        end

        candidate_routes = if hovered_routes.any?
                             hovered_routes
                           elsif route_phase_active
                             @routes
                           elsif is_history_mode
                             @routes.any? ? @routes : @historical_routes
                           else
                             []
                           end

        routes = Array(candidate_routes).select { |r| r.respond_to?(:paths_for) }

        track_action_active = actions.include?('lay_tile')
        token_action_active = actions.include?('place_token') || actions.include?('hex_token')

        hovered_c_id = Lib::Storage['hovered_company_id']
        hovered_hex_set = extract_hovered_hexes(hovered_c_id).map { |h| h.to_s.upcase }

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
          is_hovered = hovered_hex_set.include?(hex.id.to_s.upcase)

          base_hex = h(
              Hex,
              hex: hex,
              opacity: @show_starting_map ? 1.0 : (@opacity || 1.0),
              entity: current_entity,
              clickable: hex_selected ? (hex == selected_hex && clickable) : clickable,
              actions: current_entity ? actions : [],
              routes: routes,
              start_pos: @start_pos,
              highlight: false
            )

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
            # Cyan breathing means: this is a spatial opportunity available now.
            # After selection the chosen hex stays cyan but becomes static; the
            # committed tile change is then communicated by the tile-lay animation.
            breathing = !hex_selected
            hatch_children = []
            border_children = []

            if breathing
              hatch_children << h(:animate, attrs: {
                                    attributeName: 'fill-opacity',
                                    values: '0.18;0.52;0.18',
                                    dur: '1.8s',
                                    repeatCount: 'indefinite',
                                  })
              border_children << h(:animate, attrs: {
                                     attributeName: 'stroke-opacity',
                                     values: '0.45;1.0;0.45',
                                     dur: '1.8s',
                                     repeatCount: 'indefinite',
                                   })
              border_children << h(:animate, attrs: {
                                     attributeName: 'stroke-width',
                                     values: '8;14;8',
                                     dur: '1.8s',
                                     repeatCount: 'indefinite',
                                   })
            end

            overlays << h(:polygon, {
                            attrs: {
                              points: Hex::HIGHLIGHT_POINTS,
                              fill: 'url(#cyan-hatch)',
                              'fill-opacity': breathing ? '0.18' : '0.34',
                              'pointer-events': 'none',
                            },
                          }, hatch_children)

            overlays << h(:polygon, {
                            attrs: {
                              points: Hex::HIGHLIGHT_POINTS,
                              fill: 'none',
                              stroke: '#00ffff',
                              'stroke-width': breathing ? '8' : '12',
                              'stroke-opacity': breathing ? '0.45' : '1',
                              'stroke-linejoin': 'round',
                              'stroke-linecap': 'square',
                              pathLength: '576',
                              'stroke-dasharray': '40 56',
                              'stroke-dashoffset': '20',
                              'pointer-events': 'none',
                            },
                          }, border_children)

            cost_str = if current_entity
                         hex_cost_display(step, entity_or_entities, hex, tile: (hex == selected_hex ? active_tile : nil))
                       end
            if cost_str
              scale_factor = case cost_str.length
                             when 1..2 then 1.2
                             when 3    then 1.0
                             when 4    then 0.85
                             else 0.75
                             end

              rot_angle = hex.layout == :pointy ? 60 : 90

              overlays << h(:g, { attrs: { 'pointer-events': 'none' } }, [
                h(:polygon, {
                    attrs: {
                      points: '8.5,-80 48.5,-80 76.5,-32 36.5,-32',
                      fill: '#f8fafc',
                      stroke: '#4c1d95',
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
                        fill: '#4c1d95',
                        class: 'dashboard-money dashboard-tile-cost',
                        'font-weight': '700',
                        'font-family': "'Courier New', monospace",
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
          nil
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
          if hovered_company.respond_to?(:city) && hovered_company.city.respond_to?(:hex)
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
            next unless target_corp.respond_to?(:coordinates) && target_corp&.coordinates

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
h(:style, {}, %(


  #map {
    --font-money: 'Courier New', monospace;
    --color-money-text: #4c1d95;
    --map-money-size: 150%;
  }

#map .dashboard-money,
#map .dashboard-money text {
  font-family: var(--font-money) !important;
  font-weight: 700 !important;
}

) +
%(
  #map-axis text,
  #map > g > g:not(#map-hexes) text {
    fill: #000000 !important;
  }
  #map-hexes g.tile__text text {
    font-size: 14.85px !important;
    font-weight: bold !important;
  }
) +
%(


  #map .dashboard-tile-cost {
    font-size: 12px !important;
    letter-spacing: 0 !important;
  }
)),
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
            h(:g, { attrs: { id: 'map-axis' } }, [
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
          ]),
        ])
      end

      def map_zoom
        Lib::Storage['map_zoom'] || 1
      end
    end
  end
end
