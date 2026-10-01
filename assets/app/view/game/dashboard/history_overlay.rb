# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/params'
require 'lib/settings'
require 'lib/storage'

# Robust SVG numeric-attribute safety shield.
# Snabbdom may attempt to write an empty cx/cy/r while changing historical states.
# These names are SVG geometry attributes, so sanitize them by attribute name before
# Safari receives the value. Do not depend on tagName detection during a VDOM patch.
%x{
  (function() {
    if (window.__history_svg_numeric_shield_v2) return;
    window.__history_svg_numeric_shield_v2 = true;

    var elementSetAttribute = Element.prototype.setAttribute;
    var elementSetAttributeNS = Element.prototype.setAttributeNS;

    var safeSvgNumericValue = function(name, value) {
      var attr = String(name || '').toLowerCase();
      if (attr.indexOf(':') !== -1) attr = attr.split(':').pop();
      if (attr !== 'cx' && attr !== 'cy' && attr !== 'r') return value;

      if (value === null || value === undefined ||
          (typeof Opal !== 'undefined' && value === Opal.nil)) {
        return attr === 'r' ? '1' : '0';
      }

      var text = String(value).trim();
      if (text === '' || text === 'NaN' || text === 'null' || text === 'undefined') {
        return attr === 'r' ? '1' : '0';
      }
      return value;
    };

    Element.prototype.setAttribute = function(name, value) {
      return elementSetAttribute.call(this, name, safeSvgNumericValue(name, value));
    };

    Element.prototype.setAttributeNS = function(namespace, name, value) {
      return elementSetAttributeNS.call(this, namespace, name, safeSvgNumericValue(name, value));
    };
  })();
}

# Defensively handle raw action entity strings like "GT_7" during animate_last_action
class String
  def dig(*_args)
    nil
  end
end

# Monkey-patch Lib::Params to support runtime overrides and preserve tab anchors (e.g. #dashboard)
module Lib
  module Params
    class << self
      alias _orig_get_param [] unless method_defined?(:_orig_get_param)
      alias _orig_add_dashboard_anchor add unless method_defined?(:_orig_add_dashboard_anchor)

      def [](key)
        url_val = _orig_get_param(key)
        if @overrides && @overrides.key?(key.to_s)
          @overrides[key.to_s] = url_val if url_val && !url_val.empty? && url_val != @overrides[key.to_s]
          return @overrides[key.to_s]
        end

        url_val
      end

      def []=(key, val)
        @overrides ||= {}
        if val.nil? || val.to_s.empty?
          @overrides.delete(key.to_s)
        else
          @overrides[key.to_s] = val.to_s
        end
      end

      def add(route, param, value)
        route_str = route.to_s
        anchor = route_str.split('#')[1]&.split('?')&.first
        base_route = route_str.split('#').first
        res = _orig_add_dashboard_anchor(base_route, param, value)
        anchor && !anchor.empty? ? "#{res.split('#').first}##{anchor}" : res
      end
    end
  end
end

# Ensure GamePage does not cache stale @cursor values across history steps
module View
  class GamePage < Snabberb::Component
    def cursor
      param = Lib::Params['action']
      return param.to_i if param && !param.to_s.empty?

      nil
    end
  end
end

module View
  module Game
    module Dashboard
      class HistoryOverlay < Snabberb::Component
        include Lib::Settings

        needs :game, store: true
        needs :game_data, store: true, default: nil
        needs :show_history_overlay, store: true, default: false
        needs :app_route, store: true, default: nil
        needs :on_close, default: nil

        def total_actions
          acts = if @game_data && @game_data['actions']&.any?
                   @game_data['actions'].last['id'] || @game_data['actions'].size
                 elsif @game.respond_to?(:raw_actions) && @game.raw_actions&.any?
                   last = @game.raw_actions.last
                   if last.is_a?(Hash)
                     last['id'] || last[:id]
                   else
                     (last.respond_to?(:id) ? last.id : @game.raw_actions.size)
                   end
                 elsif @game.respond_to?(:last_game_action_id)
                   @game.last_game_action_id
                 else
                   0
                 end

          # Maintain maximum seen action id so navigating to Action 1 does not collapse total_actions
          @max_seen_action = [@max_seen_action || 0, acts.to_i].max
          @max_seen_action
        end

        def current_cursor
          param = Lib::Params['action']
          param && !param.to_s.empty? ? param.to_i : total_actions
        end

        def viewing_history?
          param = Lib::Params['action']
          !param.nil? && !param.to_s.empty? && param.to_i < total_actions
        end

        def close_overlay
          Lib::Storage['cmd_history_overlay'] = nil
          begin
            store(:show_history_overlay, false)
          rescue StandardError
            nil
          end
          @on_close&.call if @on_close.respond_to?(:call)
          %x{
            var hud = document.getElementById('history_floating_hud');
            if (hud) hud.style.display = 'none';
          }
        end

        def round_action_ids
          if @game.respond_to?(:round_history) && @game.round_history&.any?
            return @game.round_history.map do |r|
              raw_id = if r.is_a?(Hash)
                         r['action_id'] || r[:action_id] || r['id'] || r[:id]
                       elsif r.respond_to?(:action_id)
                         r.action_id
                       else
                         r
                       end
              raw_id.to_i if raw_id
            end.compact.select(&:positive?).uniq.sort
          end

          %x{
            if (window._round_history && Array.isArray(window._round_history)) {
              return window._round_history
                .map(function(id) { return parseInt(id, 10); })
                .filter(function(id) { return Number.isFinite(id) && id > 0; })
                .sort(function(a, b) { return a - b; });
            }
          }
          []
        end

        def prev_round_action
          curr = current_cursor
          rounds = round_action_ids
          if rounds.any?
            candidates = rounds.select { |id| id < curr }
            return candidates.last if candidates.any?
          end
          nil
        end

        def next_round_action
          curr = current_cursor
          rounds = round_action_ids
          if rounds.any?
            candidates = rounds.select { |id| id > curr }
            return candidates.first if candidates.any?
          end
          nil
        end

        def jump_prev_round
          target = prev_round_action
          if target
            set_action(target)
          else
            dispatch_keyboard_nav('ArrowUp')
          end
        end

        def jump_next_round
          target = next_round_action
          if target
            set_action(target)
          else
            dispatch_keyboard_nav('ArrowDown')
          end
        end

        def dispatch_keyboard_nav(key_name)
          %x{
            var k = #{key_name};
            var code = k === 'ArrowUp' ? 38 : (k === 'ArrowDown' ? 40 : 0);
            var evt = new KeyboardEvent('keydown', {
              key: k,
              code: k,
              which: code,
              keyCode: code,
              bubbles: true,
              cancelable: true
            });
            window.dispatchEvent(evt);
            document.dispatchEvent(evt);
          }
        end

        def schedule_scrub(val)
          %x{
            var targetVal = parseInt(#{val}, 10);
            var total = #{total_actions};
            var label = document.getElementById('hist_viewing_text');

            if (label && Number.isFinite(targetVal)) {
              label.innerText = 'Viewing: Action #' + targetVal + ' of ' + total;
            }
          }
        end

        def sync_slider(action_id, max_id)
          %x{
            window.requestAnimationFrame(function() {
              var slider = document.getElementById('hist_slider_input');
              var label = document.getElementById('hist_viewing_text');
              var value = String(#{action_id});
              var maximum = String(#{max_id});

              if (slider) {
                slider.min = '1';
                slider.max = maximum;
                slider.value = value;
              }

              if (label) {
                label.textContent = 'Viewing: Action #' + value + ' of ' + maximum;
              }
            });
          }
        end

        def set_action(target_id)
          max_id = [total_actions.to_i, 1].max
          target = [[target_id.to_i, 1].max, max_id].min
          new_cursor = target >= max_id ? nil : target
          target_val = new_cursor || max_id

          Lib::Params['action'] = new_cursor ? new_cursor.to_s : nil

          curr_route = @app_route
          if !curr_route || curr_route.empty?
            curr_route = `window.location.pathname + window.location.search + window.location.hash`
          end
          new_route = Lib::Params.add(curr_route, 'action', new_cursor)

          %x{
            if (window.history && window.history.replaceState) {
              window.history.replaceState(null, '', #{new_route});
            }
          }

          store(:app_route, new_route)
          update if respond_to?(:update)
          sync_slider(target_val, max_id)
        end

        def step_action(delta)
          set_action(current_cursor + delta)
        end

        def play_from_here
          curr = current_cursor
          total = total_actions
          return if curr >= total

          confirmed = `confirm("Discard all actions after #" + #{curr} + " and resume play from here?")`
          return unless confirmed

          if @game_data && @game_data['actions']
            filtered = @game_data['actions'].select do |a|
              aid = if a.is_a?(Hash)
                      a['id'] || a[:id]
                    else
                      (a.respond_to?(:id) ? a.id : nil)
                    end
              aid ? aid.to_i <= curr : true
            end
            @game_data['actions'] = filtered
            Lib::Storage[@game_data['id']] = @game_data if @game_data['id']
          end

          %x{
            (function() {
              try {
                var gameData = #{@game_data.to_n};
                if (gameData && gameData.actions) {
                  var targetId = #{curr};
                  var list = [];
                  for (var i = 0; i < gameData.actions.length; i++) {
                    var act = gameData.actions[i];
                    var aid = act.id !== undefined ? act.id : (act.get && act.get('id'));
                    if (aid === undefined || aid <= targetId) {
                      list.push(act);
                    }
                  }
                  gameData.actions = list;
                  if (gameData.id) {
                    localStorage.setItem('game_' + gameData.id, JSON.stringify(gameData));
                    localStorage.setItem(gameData.id, JSON.stringify(gameData));
                  }
                }
              } catch(e) {
                console.error('Failed syncing truncated actions', e);
              }

              var url = new URL(window.location.href);
              url.searchParams.delete('action');
              window.location.href = url.pathname + (url.searchParams.toString() ? '?' + url.searchParams.toString() : '') + url.hash;
            })()
          }
        end

        def start_drag(e)
          %x{
            var ev = #{e};
            if (!ev || ev.button !== 0) return;
            var target = ev.target;
            if (target && (target.tagName === 'BUTTON' || target.tagName === 'INPUT' || (target.closest && target.closest('button, input')))) {
              return;
            }
            if (ev.preventDefault) ev.preventDefault();

            var hud = document.getElementById('history_floating_hud');
            if (!hud) return;

            var rect = hud.getBoundingClientRect();
            var startX = ev.clientX;
            var startY = ev.clientY;
            var origLeft = rect.left;
            var origTop = rect.top;

            hud.style.transform = 'none';
            hud.style.left = origLeft + 'px';
            hud.style.top = origTop + 'px';
            hud.style.margin = '0';
            document.body.style.userSelect = 'none';

            var onMove = function(me) {
              var dx = me.clientX - startX;
              var dy = me.clientY - startY;
              var maxLeft = window.innerWidth - hud.offsetWidth - 10;
              var maxTop = window.innerHeight - hud.offsetHeight - 10;
              var newLeft = Math.max(10, Math.min(maxLeft, origLeft + dx));
              var newTop = Math.max(10, Math.min(maxTop, origTop + dy));
              hud.style.left = newLeft + 'px';
              hud.style.top = newTop + 'px';
            };

            var onUp = function() {
              window.removeEventListener('mousemove', onMove);
              window.removeEventListener('mouseup', onUp);
              document.body.style.userSelect = '';
              try {
                localStorage.setItem('hist_hud_pos', JSON.stringify({ left: hud.style.left, top: hud.style.top }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
          }
        end

        def nav_btn(label, onclick, disabled: false, primary: false, danger: false)
          bg = if disabled
                 '#f1f5f9'
               elsif danger
                 '#dc2626'
               elsif primary
                 '#2563eb'
               else
                 '#f8fafc'
               end

          color = if disabled
                    '#94a3b8'
                  elsif primary || danger
                    '#ffffff'
                  else
                    '#0f172a'
                  end

          border = if disabled
                     '1px solid #e2e8f0'
                   elsif danger
                     '1px solid #b91c1c'
                   elsif primary
                     '1px solid #1d4ed8'
                   else
                     '1px solid #cbd5e1'
                   end

          h(:button, {
              attrs: { disabled: disabled, type: 'button' },
              style: {
                padding: '0 10px',
                height: '1.85rem',
                fontSize: '0.82rem',
                fontWeight: 'bold',
                backgroundColor: bg,
                color: color,
                border: border,
                borderRadius: '4px',
                cursor: disabled ? 'not-allowed' : 'pointer',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                boxShadow: disabled ? 'none' : '0 1px 2px rgba(0, 0, 0, 0.05)',
                whiteSpace: 'nowrap',
              },
              on: disabled ? {} : { click: onclick },
            }, label)
        end

        def render
          total = total_actions
          curr = current_cursor
          is_hist = viewing_history?

          saved_pos = %x{
            (function() {
              try {
                var p = JSON.parse(localStorage.getItem('hist_hud_pos'));
                if (p && typeof p.left === 'string' && typeof p.top === 'string' && p.left.indexOf('px') !== -1 && p.top.indexOf('px') !== -1) {
                  return p;
                }
              } catch(e) {}
              return null;
            })()
          }
          pos_native = Native(saved_pos) if saved_pos
          has_pos = pos_native && pos_native['left'] && pos_native['top']

          hud_style = {
            position: 'fixed',
            top: has_pos ? pos_native['top'] : '80px',
            left: has_pos ? pos_native['left'] : '50%',
            transform: has_pos ? 'none' : 'translateX(-50%)',
            width: '560px',
            maxWidth: '92vw',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 12px 28px -5px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            border: '1px solid #94a3b8',
            zIndex: '999999',
            pointerEvents: 'auto',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            userSelect: 'none',
          }

          h('div#history_floating_hud', { style: hud_style }, [
            h('div#history_hud_handle', {
                style: {
                  padding: '0.55rem 0.9rem',
                  borderBottom: '1px solid #e2e8f0',
                  backgroundColor: '#f1f5f9',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  cursor: 'grab',
                },
                on: {
                  mousedown: ->(e) { start_drag(e) },
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', pointerEvents: 'none' } }, [
                h(:span, { style: { fontSize: '1rem', color: '#64748b' } }, '⠿'),
                h(:h3, { style: { margin: '0', fontSize: '1rem', color: '#0f172a', fontWeight: 'bold' } },
                  'Game History Navigation'),
                h(:span, {
                    style: {
                      fontSize: '0.72rem',
                      padding: '2px 6px',
                      borderRadius: '4px',
                      fontWeight: 'bold',
                      backgroundColor: is_hist ? '#fef08a' : '#dcfce7',
                      color: is_hist ? '#854d0e' : '#166534',
                      border: is_hist ? '1px solid #facc15' : '1px solid #86efac',
                    },
                  }, is_hist ? "HISTORICAL (Action ##{curr})" : 'LIVE'),
              ]),
              h(:button, {
                  attrs: { id: 'btn_close_history_overlay', type: 'button', title: 'Close Navigation HUD' },
                  style: {
                    background: 'none',
                    border: 'none',
                    fontSize: '1.25rem',
                    color: '#64748b',
                    cursor: 'pointer',
                    padding: '2px 8px',
                    borderRadius: '4px',
                    lineHeight: '1',
                    pointerEvents: 'auto',
                    zIndex: '10',
                  },
                  on: {
                    click: lambda { |e|
                      %x{
                        if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();
                      }
                      close_overlay
                    },
                  },
                }, '✕'),
            ]),

            h(:div, { style: { padding: '0.85rem 1rem', display: 'flex', flexDirection: 'column', gap: '0.75rem' } }, [
              h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.25rem' } }, [
                h(:input, {
                    attrs: {
                      id: 'hist_slider_input',
                      type: 'range',
                      min: 1,
                      max: [total, 1].max,
                      value: curr,
                    },
                    style: { width: '100%', cursor: 'pointer', accentColor: '#2563eb' },
                    on: {
                      input: lambda { |e|
                        val = `#{e} && #{e}.target ? #{e}.target.value : null`
                        schedule_scrub(val) if val
                      },
                      change: lambda { |e|
                        %x{
                          if (window.__hist_scrub_timer) {
                            clearTimeout(window.__hist_scrub_timer);
                            window.__hist_scrub_timer = null;
                          }
                        }
                        val = `#{e} && #{e}.target ? #{e}.target.value : null`
                        set_action(val) if val
                      },
                    },
                  }),
                h(:div, { style: { display: 'flex', justifyContent: 'space-between', fontSize: '0.78rem', color: '#64748b' } }, [
                  h(:span, 'Action 1 (Start)'),
                  h(:span, { attrs: { id: 'hist_viewing_text' }, style: { fontWeight: 'bold', color: '#0f172a' } },
                    "Viewing: Action ##{curr} of #{total}"),
                  h(:span, "Action #{total} (Live)"),
                ]),
              ]),

              h(:div, { style: { display: 'flex', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: '0.35rem', flexWrap: 'wrap' } }, [
                nav_btn('|<< Start', -> { set_action(1) }, disabled: curr <= 1),
                nav_btn('<< Start Round', -> { jump_prev_round }, disabled: curr <= 1),
                nav_btn('◀ Prev', -> { step_action(-1) }, disabled: curr <= 1),
                nav_btn('Next ▶', -> { step_action(1) }, disabled: curr >= total),
                nav_btn('Next Round >>', -> { jump_next_round }, disabled: curr >= total),
                nav_btn('Live >>|', -> { set_action(total) }, disabled: !is_hist),
              ]),

              h(:div, {
                  style: {
                    display: 'flex',
                    flexDirection: 'row',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    borderTop: '1px solid #e2e8f0',
                    paddingTop: '0.65rem',
                    marginTop: '0.2rem',
                  },
                }, [
                h(:div, { style: { fontSize: '0.8rem', color: '#64748b', fontStyle: 'italic' } },
                  is_hist ? 'Reviewing historical game board state.' : 'Ready. Game is at latest live state.'),
                h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, [
                  (nav_btn('Return to Live', -> { set_action(total) }, primary: true) if is_hist),
                  nav_btn('⚡ Play From Here', -> { play_from_here }, disabled: !is_hist, danger: is_hist),
                ].compact),
              ]),
            ]),
          ])
        end
      end
    end
  end
end
