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
        end

        def normalize_round_action_ids(raw)
          values = []
          Array(raw).each do |entry|
            value = if entry.is_a?(Array)
                      entry.first
                    elsif entry.is_a?(Hash)
                      entry['action_id'] || entry[:action_id] || entry['id'] || entry[:id]
                    elsif entry.respond_to?(:action_id)
                      entry.action_id
                    elsif entry.respond_to?(:id) && !entry.is_a?(Numeric)
                      entry.id
                    else
                      entry
                    end
            text = value.to_s.strip
            values << text.to_i if text.match?(/\A\d+\z/)
          end
          maximum = total_actions.to_i
          values.select { |id| id.positive? && id <= maximum }.uniq.sort
        rescue StandardError
          []
        end

        def round_cache_key
          game_id = if @game_data && @game_data['id']
                      @game_data['id']
                    elsif @game.respond_to?(:id)
                      @game.id
                    else
                      'current'
                    end
          "history_round_ids_#{game_id}"
        end

        def round_action_ids
          game_raw = @game.respond_to?(:round_history) ? @game.round_history : nil
          game_ids = normalize_round_action_ids(game_raw)

          window_raw = `window._round_history || []`
          window_ids = normalize_round_action_ids(Native(window_raw))

          stored_ids = normalize_round_action_ids(Lib::Storage[round_cache_key])
          ids = (stored_ids + game_ids + window_ids).uniq.sort

          Lib::Storage[round_cache_key] = ids if ids.any?
          `window._round_history = #{ids.to_n};`
          ids
        rescue StandardError
          []
        end

        def prev_round_action
          curr = current_cursor.to_i
          round_action_ids.select { |id| id < curr }.last
        end

        def next_round_action
          curr = current_cursor.to_i
          maximum = total_actions.to_i
          round_action_ids.find { |id| id > curr && id <= maximum }
        end

        def jump_prev_round
          target = prev_round_action
          set_action(target) if target
        end

        def jump_next_round
          target = next_round_action
          set_action(target) if target
        end

        def history_minimized?
          value = Lib::Storage['history_overlay_minimized']
          [true, 'true'].include?(value)
        end

        def toggle_history_minimized
          Lib::Storage['history_overlay_minimized'] = !history_minimized?
          update
        end

        def current_move_text
          curr = current_cursor.to_i
          log = @game.respond_to?(:log) ? @game.log : nil
          entry = log && log.any? ? log.last : nil
          text = if entry.respond_to?(:message)
                   entry.message.to_s
                 elsif entry.respond_to?(:text)
                   entry.text.to_s
                 else
                   entry.to_s
                 end
          text = 'No move description available' if text.empty?
          "Action ##{curr}: #{text}"
        rescue StandardError
          "Action ##{curr}"
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
                padding: '0 7px',
                height: '1.6rem',
                minWidth: '2.2rem',
                fontSize: '0.74rem',
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
          is_minimized = history_minimized?

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('history_overlay_left');
              return (l && l !== 'undefined' && l !== 'null' && !isNaN(parseFloat(l))) ? parseFloat(l) : null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('history_overlay_top');
              return (t && t !== 'undefined' && t !== 'null' && !isNaN(parseFloat(t))) ? parseFloat(t) : null;
            } catch(e) { return null; }
          })())

          on_header_mousedown = lambda do |event|
            %x{
              var ev = #{event} || window.event;
              if (!ev) return;

              var target = ev.target || ev.srcElement;
              if (target) {
                var tag = (target.tagName || '').toUpperCase();
                if (tag === 'BUTTON' || tag === 'INPUT' ||
                    (target.closest && target.closest('button'))) {
                  return;
                }
              }

              var header = ev.currentTarget;
              var modal = header && header.parentElement;
              if (!header || !modal) return;

              if (ev.preventDefault) ev.preventDefault();

              header.style.cursor = 'grabbing';

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

                header.style.cursor = 'grab';

                var finalRect = modal.getBoundingClientRect();
                if (finalRect &&
                    !isNaN(finalRect.left) && !isNaN(finalRect.top)) {
                  try {
                    sessionStorage.setItem('history_overlay_left', finalRect.left);
                    sessionStorage.setItem('history_overlay_top', finalRect.top);
                  } catch (err) {}
                }
              }

              document.addEventListener('mousemove', onMouseMove, true);
              document.addEventListener('mouseup', onMouseUp, true);
              window.addEventListener('mousemove', onMouseMove, true);
              window.addEventListener('mouseup', onMouseUp, true);
            }
          end

          reset_pos = lambda do
            %x(
            try {
              sessionStorage.removeItem('history_overlay_left');
              sessionStorage.removeItem('history_overlay_top');
            } catch(e) {}
            var modal = document.getElementById('history_floating_hud');
            if (modal) {
              modal.style.left = '50%';
              modal.style.top = '80px';
              modal.style.transform = 'translateX(-50%)';
              modal.style.margin = '0';
            }
            )
            update
          end

          hud_style = {
            position: 'fixed',
            width: '560px',
            maxWidth: '92vw',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 12px 28px -5px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            border: '1px solid #94a3b8',
            zIndex: '100001',
            pointerEvents: 'auto',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            margin: '0',
          }

          if saved_left && saved_top
            hud_style[:left] = "#{saved_left}px"
            hud_style[:top] = "#{saved_top}px"
            hud_style[:transform] = 'none'
          else
            hud_style[:left] = '50%'
            hud_style[:top] = '80px'
            hud_style[:transform] = 'translateX(-50%)'
          end

          dialog_box = h(:div, {
                           attrs: { id: 'history_floating_hud' },
                           style: hud_style,
                         }, [
h(:div, {
    attrs: { id: 'history_hud_handle' },
    style: {
      padding: '0.55rem 0.9rem',
      borderBottom: is_minimized ? 'none' : '1px solid #e2e8f0',
      backgroundColor: '#f1f5f9',
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
                        h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', pointerEvents: 'none' } }, [
                          h(:span, { style: { fontSize: '1rem', color: '#64748b' } }, '⠿'),
                          h(:h3, { style: { margin: '0', fontSize: '1rem', color: '#0f172a', fontWeight: 'bold' } },
                            'Game History Navigation'),
                        ]),
                        h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.2rem' } }, [
                          h(:button, {
                              attrs: { type: 'button', title: is_minimized ? 'Expand' : 'Minimize' },
                              style: {
                                background: 'none',
                                border: 'none',
                                fontSize: '1.1rem',
                                color: '#64748b',
                                cursor: 'pointer',
                                padding: '2px 7px',
                                lineHeight: '1',
                              },
                              on: { click: -> { toggle_history_minimized } },
                            }, is_minimized ? '□' : '−'),
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
                      ]),

h(:div, { style: { padding: '0.85rem 1rem', display: is_minimized ? 'none' : 'flex', flexDirection: 'column', gap: '0.65rem' } }, [
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

  h(:div, { style: { display: 'flex', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: '0.3rem', flexWrap: 'nowrap' } }, [
    nav_btn('|◀', -> { set_action(1) }, disabled: curr <= 1),
    nav_btn('◀|', -> { jump_prev_round }, disabled: prev_round_action.nil?),
    nav_btn('◀', -> { step_action(-1) }, disabled: curr <= 1),
    nav_btn('▶', -> { step_action(1) }, disabled: curr >= total),
    nav_btn('|▶', -> { jump_next_round }, disabled: next_round_action.nil?),
    nav_btn('▶|', -> { set_action(total) }, disabled: !is_hist),
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
    h(:div, { style: { fontSize: '0.76rem', color: '#334155', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } },
      current_move_text),
    h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, [
      (nav_btn('Return to Live', -> { set_action(total) }, primary: true) if is_hist),
      nav_btn('⚡ Play From Here', -> { play_from_here }, disabled: !is_hist, danger: is_hist),
    ].compact),
  ]),
]),
                    ])

          h(:div, {
              attrs: { id: 'history-overlay-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'auto',
                zIndex: '100000',
              },
            }, [dialog_box])
        end
      end
    end
  end
end
