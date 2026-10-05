# frozen_string_literal: true

require 'lib/settings'
require 'lib/hex'
require 'view/game/token'
require 'view/game/par_chart'
require 'view/game/loan_chart'

module View
  module Game
    module StockMarketAnimation
      def self.capture_pre_render
        %x{
          window._stockMarketTokens = window._stockMarketTokens || {};

          // Remove any in-flight animation clones before measuring resting tokens
          var oldClones = window.document.querySelectorAll('.stock-market-anim-clone');
          for (var k = 0; k < oldClones.length; k++) {
            if (oldClones[k].parentNode) {
              oldClones[k].parentNode.removeChild(oldClones[k]);
            }
          }

          var tokens = window.document.querySelectorAll('.stock-market-token');
          for (var i = 0; i < tokens.length; i++) {
            var token = tokens[i];
            token.style.opacity = '1';
            var id = token.getAttribute('data-corp') || token.id;
            if (id) {
              var r = token.getBoundingClientRect();
              if (r.width > 0 && r.height > 0) {
                window._stockMarketTokens[id] = {
                  left: r.left,
                  top: r.top,
                  width: r.width,
                  height: r.height,
                  src: token.getAttribute('src') || token.getAttribute('href') || ''
                };
              }
            }
          }
        }
      end

      def self.animate_movements
        %x{
          window.requestAnimationFrame(function() {
            window.requestAnimationFrame(function() {
              if (!window._stockMarketTokens) return;
              var newTokens = window.document.querySelectorAll('.stock-market-token');

              for (var i = 0; i < newTokens.length; i++) {
                (function(token) {
                  var id = token.getAttribute('data-corp') || token.id;
                  var prev = window._stockMarketTokens[id];
                  if (!prev) return;

                  var curr = token.getBoundingClientRect();
                  if (curr.width === 0 || curr.height === 0) return;

                  var dx = prev.left - curr.left;
                  var dy = prev.top - curr.top;
                  var dist = Math.sqrt(dx * dx + dy * dy);

                  // Trigger animation only if the token actually changed market spaces
                  if (dist > 3) {
                    var clone;
                    var isImg = token.tagName.toLowerCase() === 'img';
                    if (isImg) {
                      clone = token.cloneNode(true);
                    } else {
                      clone = window.document.createElement('img');
                      clone.src = prev.src || token.getAttribute('href') || '';
                      clone.style.borderRadius = '50%';
                    }

                    // Use a dedicated animation class and strip ID/data-corp so rapid turns
                    // never measure or chain-scale an active clone
                    clone.className = 'stock-market-anim-clone';
                    clone.removeAttribute('id');
                    clone.removeAttribute('data-corp');

                    // Base dimensions remain the standard resting size
                    clone.style.position = 'fixed';
                    clone.style.left = prev.left + 'px';
                    clone.style.top = prev.top + 'px';
                    clone.style.width = prev.width + 'px';
                    clone.style.height = prev.height + 'px';
                    clone.style.zIndex = '999999';
                    clone.style.pointerEvents = 'none';
                    clone.style.margin = '0';
                    clone.style.boxSizing = 'border-box';
                    clone.style.outline = '3px solid #38bdf8';
                    clone.style.outlineOffset = '2px';
                    clone.style.borderRadius = '50%';

                    window.document.body.appendChild(clone);
                    token.style.opacity = '0';

                    var deltaX = curr.left - prev.left;
                    var deltaY = curr.top - prev.top;

                    // Standard size at start (1.0x), max 2.0x during flight, settling to 1.0x
                    var keyframes = [
                      {
                        transform: 'translate(0px, 0px) scale(1)',
                        filter: 'drop-shadow(0 2px 4px rgba(0,0,0,0.35))',
                        offset: 0
                      },
                      {
                        transform: 'translate(0px, -26px) scale(2.0)',
                        filter: 'drop-shadow(0 28px 24px rgba(0,0,0,0.65))',
                        offset: 0.22
                      },
                      {
                        transform: 'translate(' + deltaX + 'px, ' + (deltaY - 26) + 'px) scale(2.0)',
                        filter: 'drop-shadow(0 28px 24px rgba(0,0,0,0.65))',
                        offset: 0.76
                      },
                      {
                        transform: 'translate(' + deltaX + 'px, ' + (deltaY + 2) + 'px) scale(1.06)',
                        filter: 'drop-shadow(0 4px 6px rgba(0,0,0,0.35))',
                        offset: 0.92
                      },
                      {
                        transform: 'translate(' + deltaX + 'px, ' + deltaY + 'px) scale(1)',
                        filter: 'drop-shadow(0 2px 4px rgba(0,0,0,0.35))',
                        offset: 1
                      }
                    ];

                    var anim = clone.animate(keyframes, {
                      duration: 600,
                      easing: 'cubic-bezier(0.25, 1, 0.35, 1)',
                      fill: 'forwards'
                    });

                    var finishHandler = function() {
                      token.style.opacity = '1';
                      if (clone.parentNode) {
                        clone.parentNode.removeChild(clone);
                      }
                    };

                    anim.onfinish = finishHandler;
                    anim.oncancel = finishHandler;
                  }
                })(newTokens[i]);
              }
            });
          });
        }
      end
    end

    class DashboardStock < Snabberb::Component
      include Lib::Settings

      needs :game
      needs :user, default: nil, store: true
      needs :show_bank, default: false
      needs :explain_colors, default: true

      COLOR_MAP = {
        red: '#ffaaaa',
        blue: '#35a7ff',
        brown: '#8b4513',
        orange: '#ffbb55',
        yellow: '#ffff99',
        black: '#000000',
        gray: '#888888',
        green: '#aaffaa',
        white: '#ffffff',
        olive: '#d1e189',
        purple: '#9a4eae',
        peach: '#ffe5b4',
      }.freeze

      PAD = 4
      BORDER = 1
      WIDTH_TOTAL = 50
      TOKEN_SIZE = 25
      TOKEN_SIZES = { small: 25, medium: 32, large: 40 }.freeze

      VERTICAL_TOKEN_PAD = 4
      MIN_NUM_TOKENS = 3
      PRICE_HEIGHT = 20
      MIN_TOKENS_HEIGHT = MIN_NUM_TOKENS * (TOKEN_SIZE + VERTICAL_TOKEN_PAD)

      HEIGHT_TOTAL = 50
      TOKEN_PAD = 3
      BOX_WIDTH = WIDTH_TOTAL - (2 * BORDER)
      LEFT_MARGIN = TOKEN_PAD
      RIGHT_MARGIN = BOX_WIDTH - TOKEN_PAD
      LEFT_TOKEN_POS = LEFT_MARGIN
      RIGHT_TOKEN_POS = RIGHT_MARGIN - TOKEN_SIZE
      MID_TOKEN_POS = (LEFT_TOKEN_POS + RIGHT_TOKEN_POS) / 2
      TOKEN_BORDER_WIDTH = 2

      HEX_WIDTH_TOTAL = 20
      HEX_PAD_FROM_CENTER = (HEX_WIDTH_TOTAL / 2) - BORDER
      HEX_HALF_TOKEN = TOKEN_SIZE / 2
      HEX_MID_TOKEN_POS = -HEX_HALF_TOKEN
      HEX_LEFT_TOKEN_POS = HEX_MID_TOKEN_POS - HEX_PAD_FROM_CENTER
      HEX_RIGHT_TOKEN_POS = HEX_MID_TOKEN_POS + HEX_PAD_FROM_CENTER
      HEX_TOKEN_BORDER_WIDTH = 2

      TOKEN_STYLE_1D = {
        textAlign: 'center',
        lineHeight: '0',
      }.freeze

      PRICE_STYLE_1D = {
        fontSize: '100%',
        textAlign: 'center',
      }.freeze

      PRICE_STYLE_INFO = {
        fontSize: '80%',
        textAlign: 'center',
        position: 'absolute',
        bottom: "#{PAD}px",
        width: "#{WIDTH_TOTAL - (2 * PAD) - (2 * BORDER)}px",
      }.freeze

      def active_corporations(corporations)
        corporations.reject(&:closed?)
      end

      def box_style_1d
        {
          position: 'relative',
          display: 'inline-block',
          padding: "#{PAD}px",
          margin: '0',
          verticalAlign: 'top',
          width: "#{WIDTH_TOTAL - (2 * PAD) - (2 * BORDER)}px",
          border: "solid #{BORDER}px rgba(0,0,0,0.2)",
          color: color_for(:font2),
        }
      end

      def box_height_1d
        tokens_height = [*@game.stock_market.market.first.map do |p|
                           active_corporations(p.corporations).sum do |c|
                             TOKEN_SIZES[@game.corporation_size(c)] + VERTICAL_TOKEN_PAD
                           end
                         end,
                         MIN_TOKENS_HEIGHT].max
        "#{tokens_height + VERTICAL_TOKEN_PAD + PRICE_HEIGHT - (2 * BORDER)}px"
      end

      CROSSHATCH_TYPES = %i[par_overlap convert_range].freeze
      BORDER_TYPES = %i[max_price max_price_1].freeze

      def cell_style(box_style, types)
        normal_types = types.reject { |t| BORDER_TYPES.include?(t) }
        color = @game.class::STOCKMARKET_COLORS[normal_types&.first]
        color_to_use = color ? COLOR_MAP[color] : color_for(:bg2)

        style = if !!normal_types.intersect?(CROSSHATCH_TYPES) && normal_types.size > 1
                  secondary = @game.class::STOCKMARKET_COLORS[(normal_types & CROSSHATCH_TYPES).first]
                  secondary_color = secondary ? COLOR_MAP[secondary] : color_for(:bg2)
                  box_style.merge(background: "repeating-linear-gradient(45deg, #{color_to_use}, #{color_to_use} 10px,
                    #{secondary_color} 10px, #{secondary_color} 20px)")
                else
                  box_style.merge(backgroundColor: color_to_use)
                end

        if types.intersect?(BORDER_TYPES)
          style[:borderRightWidth] = "#{BORDER * 4}px"
          style[:borderRightColor] = @game.class::STOCKMARKET_COLORS[(types & BORDER_TYPES).first]
          style[:width] = "#{WIDTH_TOTAL - (2 * PAD) - (2 * BORDER) - 3}px"
        end
        if color == :black
          style[:color] = 'gainsboro'
          style[:borderColor] = color_for(:font)
        end

        style
      end

      def grid_1d_price(price)
        if price.acquisition?
          h(:div, { style: PRICE_STYLE_1D }, 'Acq.')
        elsif price.type == :safe_par
          h(:div, { style: PRICE_STYLE_1D.merge(textDecoration: 'underline') }, price.price)
        else
          h(:div, { style: PRICE_STYLE_1D }, price.price)
        end
      end

      def operated?(corporation)
        return false unless @game.round.operating?

        order = @game.round.entities.index(corporation)
        idx = @game.round.entities.index(@game.round.current_entity)
        order < idx if order && idx
      end

      def token_props(corporation, index = nil, num = nil, spacing = nil)
        props = {
          attrs: {
            id: "stock-token-#{corporation.id}",
            class: 'stock-market-token',
            'data-corp': corporation.id,
            src: logo_for_user(corporation),
            title: corporation.name,
            width: "#{TOKEN_SIZES[@game.corporation_size(corporation)]}px",
          },
          style: { marginTop: "#{VERTICAL_TOKEN_PAD}px" },
        }
        if index
          props[:attrs][:width] = "#{TOKEN_SIZE}px"
          props[:style] = {
            position: 'absolute',
            left: num > 1 ? "#{LEFT_TOKEN_POS + ((num - index - 1) * spacing)}px" : "#{MID_TOKEN_POS}px",
            zIndex: num - index,
          }
        end
        if operated?(corporation)
          props[:attrs][:title] = "#{corporation.name} has operated"
          props[:style][:opacity] = '0.6'
          props[:style][:clipPath] = 'polygon(50% 0%, 100% 50%, 50% 100%, 0% 50%)'
          border = 'dashed'
        end
        if (show_player_colors = setting_for(:show_player_colors, @game))
          border_color = if show_player_colors && (owner = corporation.owner) && @game.players.include?(owner)
                           player_colors(@game.players)[owner]
                         else
                           'transparent'
                         end
          props[:style][:border] = "#{TOKEN_BORDER_WIDTH}px #{border || 'solid'} #{border_color}"
          props[:style][:borderRadius] = props[:attrs][:width]
          props[:style][:boxSizing] = 'border-box'
          props[:style][:clipPath] = 'none'
        end

        props
      end

      def token_svgs(corporation, index = nil, num = nil, spacing = nil)
        width = TOKEN_SIZES[@game.corporation_size(corporation)]

        props = {
          attrs: {
            id: "stock-token-#{corporation.id}",
            class: 'stock-market-token',
            'data-corp': corporation.id,
            href: logo_for_user(corporation),
            title: corporation.name,
            width: "#{width}px",
            x: "#{HEX_MID_TOKEN_POS}px",
            y: "#{HEX_MID_TOKEN_POS}px",
          },
        }

        x_translation = !index.nil? && num > 1 ? HEX_MID_TOKEN_POS - (HEX_LEFT_TOKEN_POS + (index * spacing)) : 0

        border_color = if setting_for(:show_player_colors, @game) && (owner = corporation.owner) && @game.players.include?(owner)
                         player_colors(@game.players)[owner]
                       else
                         'transparent'
                       end
        if operated?(corporation)
          props[:attrs][:title] = "#{corporation.name} has operated"
          props[:attrs]['clip-path'] = 'polygon(50% 0%, 100% 50%, 50% 100%, 0% 50%)'

          under_shape = [
            h(:polygon, {
                attrs: {
                  points: "-#{(width / 2) + 1},0 0,#{(width / 2) + 1} #{(width / 2) + 1},0 0,-#{(width / 2) + 1}",
                  stroke: corporation.color,
                  'stroke-width': 2,
                  fill: 'transparent',
                },
              }),
            h(:polygon, {
                attrs: {
                  points: "-#{(width / 2) + 1},0 0,#{(width / 2) + 1} #{(width / 2) + 1},0 0,-#{(width / 2) + 1}",
                  stroke: border_color,
                  'stroke-width': 2,
                  fill: 'transparent',
                  'stroke-dasharray': '4',
                },
              }),
          ]
        else
          under_shape = [h(:circle, {
                             attrs: {
                               cx: 0,
                               cy: 0,
                               stroke: border_color,
                               'stroke-width': 2,
                               fill: 'transparent',
                               r: "#{width / 2}px",
                             },
                           })]
        end

        g_props = {
          attrs: {
            transform: "translate(#{x_translation},0)",
          },
        }

        h(:g, g_props, [h(:image, props), *under_shape])
      end

      def par_bars(colors)
        bar_style = {
          border: '1px solid black',
          height: '3px',
          margin: '1px',
        }

        bars = colors.map do |color|
          bar_style[:backgroundColor] = color

          h(:div, { style: bar_style })
        end
        h(:div, bars)
      end

      def grid_1d
        row = @game.stock_market.market.first.map do |price|
          tokens = active_corporations(price.corporations).map { |corporation| h(:img, token_props(corporation)) }

          box_style = box_style_1d
          box_style[:height] = box_height_1d
          box_style = box_style.merge('margin-right': '10px') unless price.normal_movement?

          elements = [grid_1d_price(price)]
          unless (colors = @game.market_par_bars(price)).empty?
            elements << par_bars(colors)
          end
          elements << h(:div, { style: TOKEN_STYLE_1D }, tokens)

          h(:div, { style: cell_style(box_style, price.types) }, elements)
        end

        rows = row.size < 60 ? [row] : [row.shift((row.size / 2.0).ceil), row]
        rows.map { |r| h(:div, { style: { width: 'max-content' } }, r) }
      end

      def grid_zigzag(zigzag)
        box_style = box_style_1d

        half_box_style = box_style_1d
        half_box_style[:width] = "#{(WIDTH_TOTAL / 2) - (2 * PAD) - (2 * BORDER)}px"

        box_height = box_height_1d
        box_style[:height] = box_height
        half_box_style[:height] = box_height

        row0 = []
        row1 = [h(:div, style: cell_style(half_box_style, @game.stock_market.market.first.first.types))]

        @game.stock_market.market.first.each_with_index do |price, idx|
          tokens = active_corporations(price.corporations).map { |corporation| h(:img, token_props(corporation)) }

          cell_elements = [h(:div, { style: PRICE_STYLE_1D }, price.price),
                           h(:div, { style: TOKEN_STYLE_1D }, tokens)]
          cell_elements << h(:div, { style: PRICE_STYLE_INFO }, price.info) if price.info

          element = h(:div, { style: cell_style(box_style, price.types) }, cell_elements)
          if idx.even?
            row0 << element
          else
            row1 << element
          end
        end

        shorter_row = row1.size > row0.size ? row0 : row1
        shorter_row << h(:div, style: cell_style(half_box_style, @game.stock_market.market.first.last.types))

        rows = zigzag == :flip ? [row1, row0] : [row0, row1]
        rows.map { |row| h(:div, { style: { width: 'max-content' } }, row) }
      end

      def cell_style_hex(types)
        normal_types = types.reject { |t| BORDER_TYPES.include?(t) }
        color = @game.class::STOCKMARKET_COLORS[normal_types&.first]
        color_to_use = color ? COLOR_MAP[color] : color_for(:bg2)

        output = {}
        output[:fill] = color_to_use
        output[:stroke] = '#B0B0B0'
        output['stroke-width'] = 2
        output
      end

      def grid_hex
        size = 40
        col_spacing = (size * Math.sqrt(3)).round(2)
        row_spacing = (size * 3 / 2).round(2)
        num_rows = @game.stock_market.market.size
        max_cols = @game.stock_market.market.map.with_index { |r, i| r.size + ((num_rows - (i + 1)) / 2.0) }.max

        props = {
          attrs: {
            id: 'hex-market',
            width: (col_spacing * max_cols).to_s,
            height: (row_spacing * (num_rows + 0.5)).to_s,
          },
        }

        text_props = {
          attrs: {
            'dominant-baseline': 'middle',
            'text-anchor': 'middle',
            'font-size': '80%',
            transform: "translate(0, -#{row_spacing * 0.4})",
          },
        }

        col_border = 0
        row_border = row_spacing

        market_hexes = []
        @game.stock_market.market.each_with_index do |row, r_index|
          c_offset = (num_rows - r_index) / 2.0
          row.each_with_index do |price, c_index|
            next if price.nil?

            corporations = active_corporations(price.corporations)
            num = corporations.size
            spacing = num > 1 ? (HEX_RIGHT_TOKEN_POS - HEX_LEFT_TOKEN_POS) / (num - 1) : 0
            tokens = corporations.reverse.map.with_index { |corp, index| token_svgs(corp, index, num, spacing) }

            market_hexes <<
              h(:g,
                {
                  attrs: {
                    transform: "translate(#{col_spacing * (c_index + c_offset)}, #{row_spacing * (r_index - 0.25)})",
                  },
                },
                [h(:polygon,
                   {
                     attrs: {
                       transform: 'rotate(30)', points: Lib::Hex.points(scale: size / 100)
                     }.merge(cell_style_hex(price.types)),
                   }),
                 *tokens,
                 h(:text, text_props, price.price)])
          end
        end

        [h(:svg, props, [h(:g, { attrs: { transform: "translate(#{col_border},#{row_border})" } }, market_hexes)])]
      end

      def grid_2d
        (@game.stock_market.market + [[]]).each_cons(2).with_index.map do |rows, row_i|
          row_prices, next_row = rows
          first_price = true

          row = row_prices.each_with_index.map do |price, col_i|
            if price
              corporations = active_corporations(price.corporations)
              num = corporations.size
              spacing = num > 1 ? (RIGHT_TOKEN_POS - LEFT_TOKEN_POS) / (num - 1) : 0
              tokens = corporations.map.with_index { |corp, index| h(:img, token_props(corp, index, num, spacing)) }

              if first_price && !next_row.empty? && next_row[col_i]
                align = { left: 0, bottom: 0 }
                arrow = '⭣'
              elsif !row_i.zero? && @game.stock_market.right_ledge?([row_i, col_i])
                align = { right: 0, top: 0 }
                arrow = '⭡'
              else
                align = {}
                arrow = ''
              end

              first_price = false

              h(:div, { style: cell_style(@box_style_2d, price.types) },
                [
                  h('div.xsmall_font', price.price),
                  h(:div, tokens),
                  h(:div, { style: { color: '#00000060', position: 'absolute', 'font-size': '170%' }.merge(align) },
                    arrow),
                  price.info ? h(:div, { style: PRICE_STYLE_INFO }, price.info) : nil,
                ].compact)
            else
              h(:div, { style: @space_style_2d }, '')
            end
          end

          h(:div, { style: { width: 'max-content' } }, row)
        end
      end

      def logo_for_user(entity)
        setting_for(:simple_logos, @game) ? entity.simple_logo : entity.logo
      end

      def render_legend
        return nil unless @explain_colors
        return nil unless @game.class.const_defined?(:MARKET_TEXT)

        type_text = @game.class::MARKET_TEXT

        type_to_first_col = {}
        @game.stock_market.market.reverse.flatten.compact.each do |sp|
          this_col = sp.coordinates ? sp.coordinates[1] : 0
          sp.types&.each do |t|
            min_col = type_to_first_col[t]
            type_to_first_col[t] = this_col if !min_col || this_col < min_col
          end
        end
        types_in_market = type_to_first_col.sort_by { |_t, col| col }.map(&:first).select { |t| type_text[t] }

        return nil if types_in_market.empty?

        legend_items = types_in_market.map do |type|
          line_props = {
            style: {
              display: 'grid',
              grid: '1fr / auto 1fr',
              gap: '0.5rem',
              alignItems: 'center',
            },
          }

          h(:div, line_props, [
            h(:div, { style: cell_style(@box_style_2d, [type]) }, []),
            h(:div, { style: { maxWidth: '24rem' } }, type_text[type]),
          ])
        end

        legend_props = {
          style: {
            display: 'flex',
            flexDirection: 'column',
            gap: '0.75rem',
            marginLeft: '1.5rem',
            alignSelf: 'flex-start',
          },
        }

        h('div#legend', legend_props, legend_items)
      end

      def render
        StockMarketAnimation.capture_pre_render

        market_highlight_css = <<~CSS
          @keyframes stock-marker-pulse {
            0% {
              transform: scale(1);
            }
            50% {
              transform: scale(2.0);
            }
            100% {
              transform: scale(1);
            }
          }

          .stock-market-token-highlight {
            animation: stock-marker-pulse 0.65s infinite ease-in-out !important;
            transform-origin: center center !important;
            transform-box: fill-box !important;
            z-index: 999999 !important;
            filter: drop-shadow(0 0 6px rgba(0, 0, 0, 0.85)) drop-shadow(0 0 2px #ffffff) !important;
          }

          :has(> .stock-market-token-highlight),
          :has(.stock-market-token-highlight) {
            z-index: 99999 !important;
          }
        CSS

        %x{
          if (typeof window !== 'undefined') {
            window.highlightStockMarketToken = function(corpId) {
              if (!corpId) return;
              if (window._highlightedMarketCorp === corpId) return;
              window.clearStockMarketTokenHighlight();
              window._highlightedMarketCorp = corpId;

              var allTokens = document.querySelectorAll('.stock-market-token');
              for (var i = 0; i < allTokens.length; i++) {
                var t = allTokens[i];
                var tCorp = t.getAttribute('data-corp');
                if (tCorp === corpId || t.id === 'stock-token-' + corpId) {
                  t.classList.add('stock-market-token-highlight');
                  var cell = t.closest('div');
                  if (cell) {
                    cell.style.zIndex = '99999';
                    window._elevatedMarketCell = cell;
                  }
                }
              }
            };

            window.clearStockMarketTokenHighlight = function() {
              window._highlightedMarketCorp = null;
              if (window._elevatedMarketCell) {
                window._elevatedMarketCell.style.zIndex = '';
                window._elevatedMarketCell = null;
              }
              var highlighted = document.querySelectorAll('.stock-market-token-highlight');
              for (var i = 0; i < highlighted.length; i++) {
                highlighted[i].classList.remove('stock-market-token-highlight');
              }
            };
          }
        }

        @space_style_2d = {
          position: 'relative',
          display: 'inline-block',
          padding: "#{PAD}px",
          width: "#{WIDTH_TOTAL - (2 * PAD) - (2 * BORDER)}px",
          height: "#{HEIGHT_TOTAL - (2 * PAD) - (2 * BORDER)}px",
          border: "solid #{BORDER}px rgba(0,0,0,0)",
          margin: '0',
          verticalAlign: 'top',
        }

        @box_style_2d = @space_style_2d.merge(
          border: "solid #{BORDER}px rgba(0,0,0,0.2)",
          color: color_for(:font2),
        )

        grid = if @game.stock_market.hex_market?
                 grid_hex
               elsif @game.stock_market.one_d?
                 if !(zigzag = @game.stock_market.zigzag).nil?
                   grid_zigzag(zigzag)
                 else
                   grid_1d
                 end
               else
                 grid_2d
               end

        grid_props = {
          style: {
            width: 'max-content',
            height: 'max-content',
            overflow: 'visible',
            margin: '0',
            padding: '0',
          },
        }

        grid_elm = h(:div, grid_props, grid)
        legend_elm = render_legend

        StockMarketAnimation.animate_movements

        container_props = {
          style: {
            display: 'flex',
            flexDirection: 'row',
            alignItems: 'flex-start',
            width: 'max-content',
          },
        }

        h(:div, container_props, [h(:style, market_highlight_css), grid_elm, legend_elm].compact)
      end
    end

    DashboardStockMarket = DashboardStock
  end
end
