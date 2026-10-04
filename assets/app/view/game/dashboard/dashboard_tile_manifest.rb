# frozen_string_literal: true

# backtick_javascript: true

require 'lib/settings'
require 'view/tiles'
require 'view/game/tile_selector'

module View
  module Game
    module Dashboard
      class TileManifest < View::Tiles
        include Lib::Settings

        needs :game
        needs :tile_selector, default: nil, store: true
        needs :on_close, default: nil

        # Force tile names/numbers to always be visible in all browsers
        def setting_for(key, _game = nil)
          return false if key.to_s == 'hide_tile_names'

          super
        end

        def render_tile_selector(remaining, tile, shift: 0)
          return [] unless @tile_selector
          return [] if @tile_selector.role != :tile_page || @tile_selector.hex&.tile&.name != tile.name

          upgrade_tiles = @game.all_potential_upgrades(@tile_selector.hex.tile, tile_manifest: true).map do |t|
            Engine::Tile::ALL_EDGES.select do |r|
              break if @tile_selector.hex.tile.paths.all? { |path| t.paths.any? { |p| path <= p } }

              t.rotate!(r)
            end
            [t, remaining[t.name]&.any? ? nil : 'None Left']
          end

          return [] if upgrade_tiles.empty?

          m = Native(`(document.getElementById('tile_manifest') || document.getElementById('dashboard-tile-manifest-dialog')).getBoundingClientRect()`)
          c = Native(`document.getElementById('tile_' + #{tile.name}).getBoundingClientRect()`)
          ts_ds = [View::Game::TileSelector::DROP_SHADOW_SIZE - 5, 0].max
          left_col = c.left - m.left < WIDTH
          right_col = m.right - c.right < WIDTH + ts_ds
          bottom_row = m.bottom - c.bottom < WIDTH + ts_ds
          top_row = c.top - m.top < WIDTH

          props = {
            style: {
              position: 'absolute',
              left: "#{(WIDTH * shift) + (WIDTH / 2)}px",
              top: "#{(WIDTH / 2) - 1}px",
            },
          }

          selector = h(View::Game::TileSelector, layout: @game.layout, tiles: upgrade_tiles, unavailable_clickable: true,
                                                 role: :tile_page, left_col: left_col, right_col: right_col,
                                                 bottom_row: bottom_row, top_row: top_row)

          parent_props = {
            style: {
              overflow: 'inherit',
              margin: '1rem 0',
              position: 'absolute',
            },
          }

          [h(:div, parent_props, [h(:div, props, [selector])])]
        end

        def render_tile_manifest
          remaining = @game.tiles.group_by(&:name)

          if @game.tile_groups.empty?
            children = @game.all_tiles.sort.group_by(&:name).flat_map do |name, tiles|
              num = remaining[name]&.size || 0
              unavailable = num.positive? ? nil : 'None Left'
              tile = tiles.first
              next if tile.hidden

              render_tile_blocks(name,
                                 tile: tile,
                                 num: num,
                                 unavailable: unavailable,
                                 layout: @game.layout,
                                 clickable: true,
                                 extra_children: render_tile_selector(remaining, tile))
            end.compact
          else
            all_tiles = @game.all_tiles.sort.group_by(&:name)
            children = @game.tile_groups.flat_map do |group|
              if group.one?
                name = group.first
                num = remaining[name]&.size || 0
                unavailable = num.positive? ? nil : 'None Left'
                tile = all_tiles[name].first
                next if tile.hidden

                render_tile_blocks(name,
                                   tile: tile,
                                   num: num,
                                   unavailable: unavailable,
                                   layout: @game.layout,
                                   clickable: true,
                                   extra_children: render_tile_selector(remaining, tile))
              else
                name_a, name_b = group
                num = remaining[name_a]&.size || 0

                unavailable = num.positive? ? nil : 'None Left'

                tile_a = all_tiles[name_a].first
                tile_b = all_tiles[name_b].first

                next if tile_a.hidden && tile_b.hidden

                render_tile_sides(name_a,
                                  name_b,
                                  tile_a: tile_a,
                                  tile_b: tile_b,
                                  num: num,
                                  unavailable: unavailable,
                                  layout: @game.layout,
                                  clickable: true,
                                  extra_children_a: render_tile_selector(remaining, tile_a),
                                  extra_children_b: render_tile_selector(remaining, tile_b, shift: 1))
              end
            end.compact
          end

          props = {
            style: {
              display: 'flex',
              flexWrap: 'wrap',
              justifyContent: 'center',
              margin: '1vmin',
            },
          }

          h('div#tile_manifest', props, children)
        end

        def render
          is_minimized = Lib::Storage['dashboard_tile_manifest_minimized'] || false

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('dashboard_tile_manifest_left');
              return (l && l !== 'undefined' && l !== 'null' && !isNaN(parseFloat(l))) ? parseFloat(l) : null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('dashboard_tile_manifest_top');
              return (t && t !== 'undefined' && t !== 'null' && !isNaN(parseFloat(t))) ? parseFloat(t) : null;
            } catch(e) { return null; }
          })())

          on_header_mousedown = lambda do |event|
            %x(
            var ev = #{event} || (typeof arguments !== 'undefined' ? arguments[0] : null) || window.event;
            if (!ev) return;

            var target = ev.target || ev.srcElement;
            if (target) {
              var tag = (target.tagName || '').toUpperCase();
              if (tag === 'BUTTON' || tag === 'INPUT' || (target.closest && target.closest('button'))) {
                return;
              }
            }

            if (ev.preventDefault) {
              ev.preventDefault();
            }

            var modal = document.getElementById('dashboard-tile-manifest-dialog');
            if (!modal) return;

            var header = document.getElementById('dashboard-tile-manifest-header');
            if (header) {
              header.style.cursor = 'grabbing';
            }

            var rect = modal.getBoundingClientRect();
            var shiftX = ev.clientX - rect.left;
            var shiftY = ev.clientY - rect.top;

            modal.style.position = 'fixed';
            modal.style.left = rect.left + 'px';
            modal.style.top = rect.top + 'px';
            modal.style.margin = '0';
            modal.style.transform = 'none';

            function onMouseMove(moveEv) {
              var mEv = moveEv || window.event;
              if (mEv.preventDefault) mEv.preventDefault();

              var newLeft = mEv.clientX - shiftX;
              var newTop = mEv.clientY - shiftY;

              var maxLeft = window.innerWidth - 60;
              var maxTop = window.innerHeight - 40;

              if (newLeft < 10) newLeft = 10;
              if (newLeft > maxLeft) newLeft = maxLeft;
              if (newTop < 0) newTop = 0;
              if (newTop > maxTop) newTop = maxTop;

              modal.style.left = newLeft + 'px';
              modal.style.top = newTop + 'px';
            }

            function onMouseUp(upEv) {
              document.removeEventListener('mousemove', onMouseMove, true);
              document.removeEventListener('mouseup', onMouseUp, true);
              window.removeEventListener('mousemove', onMouseMove, true);
              window.removeEventListener('mouseup', onMouseUp, true);

              if (header) {
                header.style.cursor = 'grab';
              }

              var finalRect = modal.getBoundingClientRect();
              if (finalRect && !isNaN(finalRect.left) && !isNaN(finalRect.top)) {
                try {
                  sessionStorage.setItem('dashboard_tile_manifest_left', finalRect.left);
                  sessionStorage.setItem('dashboard_tile_manifest_top', finalRect.top);
                } catch(err) {}
              }
            }

            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('mouseup', onMouseUp, true);
            window.addEventListener('mousemove', onMouseMove, true);
            window.addEventListener('mouseup', onMouseUp, true);
            )
          end

          reset_pos = lambda do
            %x(
            try {
              sessionStorage.removeItem('dashboard_tile_manifest_left');
              sessionStorage.removeItem('dashboard_tile_manifest_top');
            } catch(e) {}
            var modal = document.getElementById('dashboard-tile-manifest-dialog');
            if (modal) {
              modal.style.left = '50%';
              modal.style.top = '50%';
              modal.style.transform = 'translate(-50%, -50%)';
              modal.style.margin = '0';
            }
            )
            update
          end

          toggle_minimize = lambda do
            Lib::Storage['dashboard_tile_manifest_minimized'] = !is_minimized
            update
          end

          close_overlay = lambda do
            Lib::Storage['dashboard_tile_manifest'] = false
            @on_close&.call
            update
          end

          dialog_style = {
            width: '92%',
            maxWidth: '1120px',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.4), 0 8px 10px -6px rgba(0, 0, 0, 0.2)',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            border: '1px solid #cbd5e1',
            pointerEvents: 'auto',
            position: 'fixed',
            margin: '0',
            zIndex: '100001',
          }

          if saved_left && saved_top
            dialog_style[:left] = "#{saved_left}px"
            dialog_style[:top] = "#{saved_top}px"
            dialog_style[:transform] = 'none'
          else
            dialog_style[:left] = '50%'
            dialog_style[:top] = '50%'
            dialog_style[:transform] = 'translate(-50%, -50%)'
          end

          dialog_style[:maxHeight] = is_minimized ? 'auto' : '82vh'

          header_controls = [
            h(:button, {
                attrs: { type: 'button', title: is_minimized ? 'Expand overlay' : 'Minimize overlay' },
                style: {
                  padding: '0 8px',
                  height: '1.6rem',
                  fontSize: '0.78rem',
                  fontWeight: '600',
                  backgroundColor: '#f1f5f9',
                  color: '#334155',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  cursor: 'pointer',
                },
                on: { click: toggle_minimize },
              }, is_minimized ? 'Expand' : 'Minimize'),
            h(:button, {
                attrs: { type: 'button', title: 'Close overlay' },
                style: {
                  padding: '0 8px',
                  height: '1.6rem',
                  fontSize: '0.85rem',
                  fontWeight: 'bold',
                  backgroundColor: '#fee2e2',
                  color: '#991b1b',
                  border: '1px solid #fca5a5',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  lineHeight: '1',
                },
                on: { click: close_overlay },
              }, '✕'),
          ]

          body_content = if is_minimized
                           nil
                         else
                           h(:div, {
                               style: {
                                 overflowY: 'auto',
                                 maxHeight: 'calc(82vh - 52px)',
                                 padding: '0.5rem 1rem 1rem 1rem',
                               },
                             }, [render_tile_manifest])
                         end

          remaining_count = @game.tiles.size

          dialog_children = [
            h(:div, {
                attrs: { id: 'dashboard-tile-manifest-header' },
                style: {
                  padding: '0.6rem 1rem',
                  borderBottom: is_minimized ? 'none' : '1px solid #e2e8f0',
                  backgroundColor: '#f8fafc',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  cursor: 'grab',
                  userSelect: 'none',
                },
                on: {
                  mousedown: on_header_mousedown,
                  dblclick: reset_pos,
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'baseline', gap: '0.6rem' } }, [
                h(:h2, { style: { margin: '0', fontSize: '1.15rem', color: '#0f172a', fontWeight: 'bold' } }, 'Tile Manifest'),
                h(:span, { style: { fontSize: '0.8rem', color: '#64748b' } },
                  "(#{remaining_count} remaining tiles • drag header to move, dblclick to center)"),
              ]),
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, header_controls),
            ]),
          ]
          dialog_children << body_content if body_content

          h(:div, {
              attrs: { id: 'dashboard-tile-manifest-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'none',
                zIndex: '100000',
              },
            }, [
              h(:div, {
                  attrs: { id: 'dashboard-tile-manifest-dialog' },
                  style: dialog_style,
                }, dialog_children),
            ])
        end
      end
    end
    DashboardTileManifest = Dashboard::TileManifest
  end
end
