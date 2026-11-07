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

        def render_count_badge(label, num, shift: 0)
          h(:div, {
              style: {
                position: 'absolute',
                top: '0px',
                left: "#{(WIDTH * shift) + 1}px",
                width: "#{WIDTH - 2}px",
                boxSizing: 'border-box',
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                padding: '1px 4px',
                backgroundColor: '#ffffff',
                color: '#000000',
                border: '1px solid #000000',
                fontSize: '11px',
                fontWeight: 'bold',
                lineHeight: '1.2',
                borderRadius: '2px',
                zIndex: '5',
                pointerEvents: 'none',
              },
            }, [
              h(:span, label.to_s),
              h(:span, {
                  style: {
                    fontWeight: 'bold',
                    color: '#000000',
                  },
                }, "×#{num}"),
            ])
        end

        def manifest_scale
          raw = Lib::Storage['dashboard_tile_manifest_scale']
          value = raw ? raw.to_f : 1.0
          [[value, 0.5].max, 2.5].min
        rescue StandardError
          1.0
        end

        def change_manifest_scale(factor)
          Lib::Storage['dashboard_tile_manifest_scale'] = [[manifest_scale * factor, 0.5].max, 2.5].min
          update
        end

        def reset_manifest_scale
          Lib::Storage['dashboard_tile_manifest_scale'] = 1.0
          update
        end

        def install_manifest_tile_interactions
          %x{
    // Mouse-driven desktop drag. This intentionally avoids the browser's
    // native HTML5 drag API because Snabberb may redraw the source vnode
    // during dragstart/dragend, leaving Snabbdom with detached DOM nodes.
    if (!document.__dashboardTileManifestMouseDragInstalled) {
      document.__dashboardTileManifestMouseDragInstalled = true;
      var d = { armed: false, active: false, tileName: null, source: null,
                startX: 0, startY: 0, ghost: null, overHex: null };

      function manifestTile(target) {
        if (!target || !target.closest || !target.closest('#tile_manifest')) return null;
        return target.closest('[id^="tile_"]');
      }
      function nameOf(tile) {
        return tile && tile.id && tile.id.indexOf('tile_') === 0 ? tile.id.substring(5) : null;
      }
      function hasStock(tile) {
        var m = String((tile && tile.textContent) || '').match(/[x×]\\s*(\\d+)/i);
        return !m || parseInt(m[1], 10) > 0;
      }
      function pointHex(x, y) {
        var el = document.elementFromPoint(x, y);
        return el && el.closest ? el.closest('.map-hex-container') : null;
      }
      function legal(hex, name) {
        if (!hex || !name) return false;
        var names = String(hex.getAttribute('data-tile-drop-names') || '').split(',');
        return names.indexOf(String(name)) !== -1;
      }
      function markExactLegal(name) {
        document.querySelectorAll('.map-hex-container').forEach(function(hex) {
          hex.classList.toggle('dashboard-tile-drop-exact-legal', legal(hex, name));
        });
      }
      function clearExactLegal() {
        document.querySelectorAll('.map-hex-container.dashboard-tile-drop-exact-legal').forEach(function(hex) {
          hex.classList.remove('dashboard-tile-drop-exact-legal');
        });
      }
      function clearOver() {
        if (d.overHex) d.overHex.classList.remove('dashboard-tile-drop-over');
        d.overHex = null;
      }
      function removeGhost() {
        if (d.ghost && d.ghost.parentNode) d.ghost.parentNode.removeChild(d.ghost);
        d.ghost = null;
      }
      function reset() {
        clearOver(); removeGhost();
        var map = document.getElementById('map');
        if (map) map.classList.remove('dashboard-tile-drag-active');
        document.documentElement.classList.remove('dashboard-clean-tile-drag');
        clearExactLegal();
        d.armed = false; d.active = false; d.tileName = null; d.source = null;
      }
      function reject(hex) {
        if (!hex) return;
        hex.classList.add('dashboard-tile-drop-rejected');
        setTimeout(function() { if (hex && hex.classList) hex.classList.remove('dashboard-tile-drop-rejected'); }, 320);
      }
      function makeGhost(tile, x, y) {
        var visual = tile.closest('svg') || tile;
        var rect = visual.getBoundingClientRect();
        var ghost = visual.cloneNode(true);
        ghost.removeAttribute('id');
        ghost.querySelectorAll('[id]').forEach(function(el) { el.removeAttribute('id'); });
        ghost.style.position = 'fixed';
        ghost.style.left = '0'; ghost.style.top = '0';
        ghost.style.width = rect.width + 'px'; ghost.style.height = rect.height + 'px';
        ghost.style.margin = '0'; ghost.style.zIndex = '2147483647';
        ghost.style.pointerEvents = 'none'; ghost.style.opacity = '0.92';
        ghost.style.filter = 'drop-shadow(0 5px 7px rgba(0,0,0,.45))';
        ghost.style.transformOrigin = 'center center';
        document.body.appendChild(ghost);
        d.ghost = ghost;
        moveGhost(x, y);
      }
      function moveGhost(x, y) {
        if (!d.ghost) return;
        var w = d.ghost.getBoundingClientRect().width;
        var h = d.ghost.getBoundingClientRect().height;
        d.ghost.style.transform = 'translate(' + (x - w / 2) + 'px,' + (y - h / 2) + 'px) scale(1.08)';
      }
      function choose(name, attempt) {
        var focus = document.querySelector('.dashboard-tile-selector-focus[data-drag-tile-name="' + String(name) + '"]');
        if (!focus) {
          if (attempt < 24) setTimeout(function() { choose(name, attempt + 1); }, 25);
          return;
        }

        // Prefer an explicitly named candidate, but the map deliberately
        // renders only one candidate for a drag drop, so the fallback is safe.
        var wanted = focus.querySelector('[data-tile-name="' + String(name) + '"]') ||
                     focus.querySelector('#tile_' + String(name)) ||
                     focus.querySelector('[id^="tile_' + String(name) + '"]');
        if (!wanted) {
          var svgs = focus.querySelectorAll('svg');
          wanted = svgs.length ? svgs[svgs.length - 1] : null;
        }
        if (!wanted) {
          if (attempt < 24) setTimeout(function() { choose(name, attempt + 1); }, 25);
          return;
        }

        // TileSelector may attach its handler to a group within the SVG.
        var clickTarget = wanted.querySelector &&
          (wanted.querySelector('[data-tile-name]') || wanted.querySelector('[id^="tile_"]') || wanted.querySelector('g'));
        clickTarget = clickTarget || wanted;
        clickTarget.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
        try { localStorage.removeItem('dashboard_drag_tile_name'); } catch(e) {}
      }

      function dropOn(name, hex, hitTarget) {
        if (!name || !legal(hex, name)) { reject(hex); return; }
        // Tell DashboardMap which exact legal tile was dragged before opening
        // the normal map selector. The Ruby renderer then reduces that selector
        // to this one tile only.
        try { localStorage.setItem('dashboard_drag_tile_name', String(name)); } catch(e) {}
        var clickTarget = (hitTarget && hex.contains(hitTarget)) ? hitTarget : hex;
        clickTarget.dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          view: window
        }));
      }

      document.addEventListener('mouseover', function(ev) {
        if (d.armed || d.active) return;
        var tile = manifestTile(ev.target), name = nameOf(tile);
        if (name && window.highlightMapTilesByName) window.highlightMapTilesByName(name);
      });
      document.addEventListener('mouseout', function(ev) {
        if (d.armed || d.active) return;
        var oldTile = manifestTile(ev.target);
        if (!oldTile || manifestTile(ev.relatedTarget) === oldTile) return;
        if (window.clearMapHexHighlightChannel) window.clearMapHexHighlightChannel('related');
      });

      document.addEventListener('mousedown', function(ev) {
        if (ev.button !== 0) return;
        var tile = manifestTile(ev.target), name = nameOf(tile);
        if (!tile || !name || !hasStock(tile)) return;
        var map = document.getElementById('map');
        if (!map) return;
        markExactLegal(name);
        if (!map.querySelector('.dashboard-tile-drop-exact-legal')) { clearExactLegal(); return; }
        ev.preventDefault();
        document.documentElement.classList.add('dashboard-clean-tile-drag');
        d.armed = true; d.active = false; d.tileName = name; d.source = tile;
        d.startX = ev.clientX; d.startY = ev.clientY;
      }, true);

      document.addEventListener('mousemove', function(ev) {
        if (!d.armed) return;
        if (!d.active) {
          var dx = ev.clientX - d.startX, dy = ev.clientY - d.startY;
          if ((dx * dx + dy * dy) < 36) return;
          d.active = true;
          var map = document.getElementById('map');
          if (map) map.classList.add('dashboard-tile-drag-active');
          if (window.clearMapHexHighlightChannel) window.clearMapHexHighlightChannel('related');
          makeGhost(d.source, ev.clientX, ev.clientY);
        }
        ev.preventDefault();
        moveGhost(ev.clientX, ev.clientY);
        clearOver();
        var hex = pointHex(ev.clientX, ev.clientY);
        if (legal(hex, d.tileName)) {
          d.overHex = hex;
          hex.classList.add('dashboard-tile-drop-over');
        }
      }, true);

      document.addEventListener('mouseup', function(ev) {
        if (!d.armed) return;
        var wasActive = d.active, name = d.tileName;
        var hitTarget = wasActive ? document.elementFromPoint(ev.clientX, ev.clientY) : null;
        var hex = hitTarget && hitTarget.closest ? hitTarget.closest('.map-hex-container') : null;
        var valid = wasActive && legal(hex, name);
        if (wasActive) { ev.preventDefault(); ev.stopPropagation(); }
        reset();
        if (wasActive) {
          if (valid) dropOn(name, hex, hitTarget); else reject(hex);
        }
      }, true);

      document.addEventListener('keydown', function(ev) {
        if (ev.key === 'Escape' && d.armed) reset();
      }, true);
      window.addEventListener('blur', function() { if (d.armed) reset(); });
    }
  }
          nil
        end

        def render_tile_manifest
          remaining = @game.tiles.group_by(&:name)

          if @game.tile_groups.empty?
            children = @game.all_tiles.sort.group_by(&:name).flat_map do |name, tiles|
              num = remaining[name]&.size || 0
              unavailable = num.positive? ? nil : 'None Left'
              tile = tiles.first
              next if tile.hidden

              extra = render_tile_selector(remaining, tile) + [render_count_badge(name, num)]
              render_tile_blocks(name,
                                 tile: tile,
                                 num: num,
                                 unavailable: unavailable,
                                 layout: @game.layout,
                                 clickable: true,
                                 extra_children: extra)
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

                extra = render_tile_selector(remaining, tile) + [render_count_badge(name, num)]
                render_tile_blocks(name,
                                   tile: tile,
                                   num: num,
                                   unavailable: unavailable,
                                   layout: @game.layout,
                                   clickable: true,
                                   extra_children: extra)
              else
                name_a, name_b = group
                num = remaining[name_a]&.size || 0

                unavailable = num.positive? ? nil : 'None Left'

                tile_a = all_tiles[name_a].first
                tile_b = all_tiles[name_b].first

                next if tile_a.hidden && tile_b.hidden

                extra_a = render_tile_selector(remaining, tile_a) + [render_count_badge(name_a, num, shift: 0)]
                extra_b = render_tile_selector(remaining, tile_b, shift: 1) + [render_count_badge(name_b, num, shift: 1)]
                render_tile_sides(name_a,
                                  name_b,
                                  tile_a: tile_a,
                                  tile_b: tile_b,
                                  num: num,
                                  unavailable: unavailable,
                                  layout: @game.layout,
                                  clickable: true,
                                  extra_children_a: extra_a,
                                  extra_children_b: extra_b)
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

          h('div#tiles', [h('div#tile_manifest', props, children)])
        end

        def render
          install_manifest_tile_interactions
          h(:div, {
              attrs: { id: 'dashboard-tile-manifest-embedded' },
              style: {
                display: 'block',
                width: 'max-content',
                height: 'max-content',
                backgroundColor: '#ffffff',
                boxSizing: 'border-box',
              },
            }, [
              h(:style, {}, %(
                html.dashboard-clean-tile-drag, html.dashboard-clean-tile-drag * {
                  user-select: none !important; -webkit-user-select: none !important;
                  cursor: grabbing !important;
                }
                #tile_manifest, #tile_manifest * { user-select: none !important; -webkit-user-select: none !important; }
                #tile_manifest [id^='tile_'] { cursor: grab; user-select: none; }
                #tile_manifest [id^='tile_']:active { cursor: grabbing; }
                .dashboard-tile-selector-focus.dashboard-drag-tile-not-available { outline: 6px solid #dc2626 !important; outline-offset: 4px; }
              )),
              render_tile_manifest,
            ])
        end
      end
    end
    DashboardTileManifest = Dashboard::TileManifest
  end
end
