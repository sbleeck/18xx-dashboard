# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/storage'

module View
  module Game
    module Dashboard
      class MoveHistoryOverlay < Snabberb::Component
        needs :game, store: true
        needs :game_data, store: true, default: nil
        needs :show_move_history, store: true, default: true
        needs :on_close, default: nil

        def close_overlay
          Lib::Storage['cmd_move_history_overlay'] = nil
          begin
            store(:show_move_history, false)
          rescue StandardError
            nil
          end
          @on_close&.call
          %x{
            var hud = document.getElementById('move_history_floating_hud');
            if (hud) hud.style.display = 'none';
          }
        end

        def start_drag(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;

            var target = ev.target || ev.srcElement;
            if (target && (target.tagName === 'BUTTON' || (target.closest && target.closest('button')))) {
              return;
            }
            if (ev.preventDefault) ev.preventDefault();

            var hud = document.getElementById('move_history_floating_hud');
            if (!hud) return;

            var rect = hud.getBoundingClientRect();
            var startX = ev.clientX;
            var startY = ev.clientY;
            var origLeft = rect.left;
            var origTop = rect.top;

            hud.style.transform = 'none';
            hud.style.left = origLeft + 'px';
            hud.style.top = origTop + 'px';
            hud.style.right = 'auto';
            hud.style.bottom = 'auto';
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
                localStorage.setItem('move_hist_overlay_pos', JSON.stringify({ left: hud.style.left, top: hud.style.top }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
          }
        end

        def start_resize(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;
            if (ev.preventDefault) ev.preventDefault();
            if (ev.stopPropagation) ev.stopPropagation();

            var hud = document.getElementById('move_history_floating_hud');
            if (!hud) return;

            var startX = ev.clientX;
            var startY = ev.clientY;
            var startW = hud.offsetWidth;
            var startH = hud.offsetHeight;
            document.body.style.userSelect = 'none';

            var onMove = function(me) {
              var maxW = window.innerWidth - 20;
              var maxH = window.innerHeight - 20;
              var newW = Math.max(260, Math.min(maxW, startW + (me.clientX - startX)));
              var newH = Math.max(160, Math.min(maxH, startH + (me.clientY - startY)));
              hud.style.width = newW + 'px';
              hud.style.height = newH + 'px';
            };

            var onUp = function() {
              window.removeEventListener('mousemove', onMove);
              window.removeEventListener('mouseup', onUp);
              document.body.style.userSelect = '';
              try {
                localStorage.setItem('move_hist_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
          }
        end

        def scroll_to_latest
          %x{
            var container = document.getElementById('move_history_scroll_body');
            if (container) {
              var isUserScrolledUp = container.scrollTop < (container.scrollHeight - container.offsetHeight - 35);
              if (!window.__user_scrolled_move_hist || !isUserScrolledUp) {
                container.scrollTop = container.scrollHeight;
              }
            }
          }
        end

        def action_time_map
          @action_time_map ||= begin
            actions = (@game_data && @game_data['actions']) ||
                      (@game.respond_to?(:raw_actions) ? @game.raw_actions : nil) ||
                      []
            map = {}
            actions.each do |a|
              aid = if a.is_a?(Hash)
                      a['id'] || a[:id]
                    else
                      (a.respond_to?(:id) ? a.id : nil)
                    end
              ts = if a.is_a?(Hash)
                     a['created_at'] || a[:created_at]
                   else
                     (a.respond_to?(:created_at) ? a.created_at : nil)
                   end
              map[aid.to_i] = ts if aid && ts
            end
            map
          end
        end

        def format_timestamp(ts)
          return nil unless ts

          %x{
            var t = #{ts};
            var d = null;
            if (typeof t === 'number') {
              d = new Date(t > 1e11 ? t : t * 1000);
            } else if (typeof t === 'string' && !isNaN(Date.parse(t))) {
              d = new Date(t);
            }
            if (d && !isNaN(d.getTime())) {
              var hh = String(d.getHours()).padStart(2, '0');
              var mm = String(d.getMinutes()).padStart(2, '0');
              return hh + ':' + mm;
            }
            return null;
          }
        end

        def render_log_lines
          log = @game&.log || []
          if log.empty?
            return [
              h(:div, {
                  style: {
                    padding: '2rem 1rem',
                    color: '#64748b',
                    textAlign: 'center',
                    fontStyle: 'italic',
                    fontSize: '0.85rem',
                  },
                }, 'No moves recorded yet.'),
            ]
          end

          time_map = action_time_map

          log.each_with_index.map do |entry, idx|
            msg = if entry.respond_to?(:message)
                    entry.message
                  elsif entry.is_a?(String)
                    entry
                  else
                    `#{entry}.message || #{entry}.text || String(#{entry})`
                  end.to_s

            aid = entry.respond_to?(:action_id) ? entry.action_id : nil
            ts = time_map[aid.to_i] if aid
            time_str = format_timestamp(ts)

            line_text = if time_str && !msg.start_with?('[')
                          "[#{time_str}] #{msg}"
                        else
                          msg
                        end

            is_round = msg.include?('--') || line_text.include?('--')

            h(:div, {
                key: "log_line_#{idx}",
                style: {
                  padding: '3px 10px',
                  fontSize: '0.84rem',
                  lineHeight: '1.4',
                  color: '#111827',
                  fontWeight: is_round ? 'bold' : 'normal',
                  backgroundColor: if is_round
                                     '#f1f5f9'
                                   else
                                     (idx.even? ? '#ffffff' : '#f8fafc')
                                   end,
                  borderBottom: '1px solid #e2e8f0',
                  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
                  wordBreak: 'break-word',
                  userSelect: 'text',
                },
              }, line_text)
          end
        end

        def render
          saved_pos = %x{
            (function() {
              try {
                var p = JSON.parse(localStorage.getItem('move_hist_overlay_pos'));
                if (p && typeof p.left === 'string' && typeof p.top === 'string' && p.left.indexOf('px') !== -1 && p.top.indexOf('px') !== -1) {
                  return p;
                }
              } catch(e) {}
              return null;
            })()
          }
          pos_native = Native(saved_pos) if saved_pos
          has_pos = pos_native && pos_native['left'] && pos_native['top']

          saved_size = %x{
            (function() {
              try {
                var s = JSON.parse(localStorage.getItem('move_hist_overlay_size'));
                if (s && typeof s.width === 'string' && typeof s.height === 'string' && s.width.indexOf('px') !== -1 && s.height.indexOf('px') !== -1) {
                  return s;
                }
              } catch(e) {}
              return null;
            })()
          }
          size_native = Native(saved_size) if saved_size
          has_size = size_native && size_native['width'] && size_native['height']

          moves_count = @game&.log&.size || 0

          hud_style = {
            position: 'fixed',
            top: has_pos ? pos_native['top'] : '70px',
            left: has_pos ? pos_native['left'] : 'calc(100vw - 440px)',
            width: has_size ? size_native['width'] : '420px',
            height: has_size ? size_native['height'] : '520px',
            maxWidth: '96vw',
            maxHeight: '92vh',
            minWidth: '280px',
            minHeight: '180px',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 12px 28px -5px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            border: '1px solid #94a3b8',
            zIndex: '999999',
            pointerEvents: 'auto',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            resize: 'both',
            userSelect: 'none',
          }

          h('div#move_history_floating_hud', {
              style: hud_style,
              hook: {
                insert: -> { scroll_to_latest },
                postpatch: -> { scroll_to_latest },
              },
              on: {
                mouseup: lambda {
                  %x{
                    var hud = document.getElementById('move_history_floating_hud');
                    if (hud && hud.style.width && hud.style.height) {
                      try {
                        localStorage.setItem('move_hist_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
                      } catch(e) {}
                    }
                  }
                },
              },
            }, [
            # Header
            h('div#move_history_hud_handle', {
                style: {
                  padding: '0.5rem 0.8rem',
                  backgroundColor: '#f1f5f9',
                  borderBottom: '1px solid #cbd5e1',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  cursor: 'grab',
                  flexShrink: '0',
                },
                on: {
                  mousedown: ->(e) { start_drag(e) },
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.45rem', pointerEvents: 'none' } }, [
                h(:span, { style: { fontSize: '0.95rem', color: '#64748b' } }, '⠿'),
                h(:h3, { style: { margin: '0', fontSize: '0.9rem', color: '#0f172a', fontWeight: 'bold' } }, 'Move History'),
                h(:span, {
                    style: {
                      fontSize: '0.72rem',
                      padding: '1px 5px',
                      borderRadius: '4px',
                      backgroundColor: '#e2e8f0',
                      color: '#334155',
                      fontWeight: 'bold',
                    },
                  }, "#{moves_count} moves"),
              ]),
              h(:button, {
                  attrs: { id: 'btn_close_move_history_overlay', type: 'button', title: 'Close Move History' },
                  style: {
                    background: 'none',
                    border: 'none',
                    fontSize: '1.2rem',
                    color: '#64748b',
                    cursor: 'pointer',
                    padding: '2px 6px',
                    borderRadius: '4px',
                    lineHeight: '1',
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

            # Scrollable Transcript Body
            h('div#move_history_scroll_body', {
                style: {
                  flex: '1',
                  overflowY: 'auto',
                  backgroundColor: '#ffffff',
                  userSelect: 'text',
                  display: 'flex',
                  flexDirection: 'column',
                  paddingBottom: '10px',
                },
                on: {
                  scroll: lambda { |e|
                    %x{
                      var target = #{e}.target;
                      if (target) {
                        window.__user_scrolled_move_hist = target.scrollTop < (target.scrollHeight - target.offsetHeight - 35);
                      }
                    }
                  },
                },
              }, render_log_lines),

            # Bottom-Right Corner Resize Grip
            h('div#move_history_resize_grip', {
                style: {
                  position: 'absolute',
                  right: '2px',
                  bottom: '2px',
                  width: '14px',
                  height: '14px',
                  cursor: 'nwse-resize',
                  display: 'flex',
                  alignItems: 'flex-end',
                  justifyContent: 'flex-end',
                  opacity: '0.5',
                  pointerEvents: 'auto',
                  zIndex: '20',
                },
                on: {
                  mousedown: ->(e) { start_resize(e) },
                },
              }, [
              h(:svg, {
                  attrs: {
                    width: '10',
                    height: '10',
                    viewBox: '0 0 10 10',
                  },
                  style: { display: 'block', pointerEvents: 'none' },
                }, [
                h(:line,
                  attrs: {
                    x1: '9',
                    y1: '1',
                    x2: '1',
                    y2: '9',
                    stroke: '#475569',
                    'stroke-width': '1.5',
                    'stroke-linecap': 'round',
                  }),
                h(:line,
                  attrs: {
                    x1: '9',
                    y1: '5',
                    x2: '5',
                    y2: '9',
                    stroke: '#475569',
                    'stroke-width': '1.5',
                    'stroke-linecap': 'round',
                  }),
              ]),
            ]),
          ])
        end
      end
    end
  end
end
