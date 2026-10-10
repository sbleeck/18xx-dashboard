# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/storage'

module View
  module Game
    module Dashboard
      class PhasesOverlay < Snabberb::Component
        needs :game, store: true
        needs :on_close, default: nil
        needs :minimized, default: false

        def close_overlay
          Lib::Storage['dashboard_show_phases'] = 'false'
          %x{
            try {
              localStorage.setItem('dashboard_show_phases', 'false');
            } catch (e) {}
          }
          @on_close&.call
        end

        def minimized?
          val = Lib::Storage['phases_overlay_minimized']
          val == true || val == 'true' || @minimized == true
        end

        def toggle_minimize
          new_val = !minimized?
          Lib::Storage['phases_overlay_minimized'] = new_val ? 'true' : 'false'
          @minimized = new_val
          update
        end

        def start_drag(e)
          %x{
            var ev = #{e} || window.event;
            if (!ev) return;

            var target = ev.target || ev.srcElement;
            if (target) {
              var tag = (target.tagName || '').toUpperCase();
              if (tag === 'BUTTON' || tag === 'INPUT' || (target.closest && target.closest('button'))) {
                return;
              }
            }

            var header = ev.currentTarget;
            var hud = document.getElementById('phases_floating_hud') || (header && header.parentElement);
            if (!hud) return;

            if (ev.preventDefault) ev.preventDefault();
            header.style.cursor = 'grabbing';

            var rect = hud.getBoundingClientRect();
            var shiftX = ev.clientX - rect.left;
            var shiftY = ev.clientY - rect.top;

            hud.style.position = 'fixed';
            hud.style.left = rect.left + 'px';
            hud.style.top = rect.top + 'px';
            hud.style.margin = '0';
            hud.style.transform = 'none';

            function onMouseMove(moveEv) {
              var mEv = moveEv || window.event;
              if (mEv.preventDefault) mEv.preventDefault();

              var newLeft = mEv.clientX - shiftX;
              var newTop = mEv.clientY - shiftY;
              var maxLeft = window.innerWidth - 80;
              var maxTop = window.innerHeight - 30;

              if (newLeft < 10) newLeft = 10;
              if (newLeft > maxLeft) newLeft = maxLeft;
              if (newTop < 0) newTop = 0;
              if (newTop > maxTop) newTop = maxTop;

              hud.style.left = newLeft + 'px';
              hud.style.top = newTop + 'px';
            }

            function onMouseUp() {
              document.removeEventListener('mousemove', onMouseMove, true);
              document.removeEventListener('mouseup', onMouseUp, true);
              window.removeEventListener('mousemove', onMouseMove, true);
              window.removeEventListener('mouseup', onMouseUp, true);

              header.style.cursor = 'grab';

              try {
                localStorage.setItem(
                  'phases_overlay_pos',
                  JSON.stringify({
                    left: hud.style.left,
                    top: hud.style.top
                  })
                );
              } catch (err) {}
            }

            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('mouseup', onMouseUp, true);
            window.addEventListener('mousemove', onMouseMove, true);
            window.addEventListener('mouseup', onMouseUp, true);
          }
        end

        def start_resize(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;
            if (ev.preventDefault) ev.preventDefault();
            if (ev.stopPropagation) ev.stopPropagation();

            var hud = document.getElementById('phases_floating_hud');
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
              var newH = Math.max(140, Math.min(maxH, startH + (me.clientY - startY)));
              hud.style.width = newW + 'px';
              hud.style.height = newH + 'px';
            };

            var onUp = function() {
              window.removeEventListener('mousemove', onMove);
              window.removeEventListener('mouseup', onUp);
              document.body.style.userSelect = '';
              try {
                localStorage.setItem('phases_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
          }
        end

        def render
          saved_pos = %x{
            (function() {
              try {
                var p = JSON.parse(localStorage.getItem('phases_overlay_pos'));
                if (p && typeof p.left === 'string' && typeof p.top === 'string') {
                  var leftNum = parseFloat(p.left);
                  var topNum = parseFloat(p.top);
                  if (!isNaN(leftNum) && !isNaN(topNum) &&
                      leftNum >= 10 && leftNum <= (window.innerWidth - 80) &&
                      topNum >= 0 && topNum <= (window.innerHeight - 40)) {
                    return p;
                  }
                  localStorage.removeItem('phases_overlay_pos');
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
                var s = JSON.parse(localStorage.getItem('phases_overlay_size'));
                if (s && typeof s.width === 'string' && typeof s.height === 'string' && s.width.indexOf('px') !== -1 && s.height.indexOf('px') !== -1) {
                  return s;
                }
              } catch(e) {}
              return null;
            })()
          }
          size_native = Native(saved_size) if saved_size
          has_size = size_native && size_native['width'] && size_native['height']

          default_left = `Math.max(10, (window.innerWidth || 1200) - 440) + 'px'`
          left_pos = has_pos ? pos_native['left'] : default_left
          top_pos = has_pos ? pos_native['top'] : '80px'

          is_min = minimized?
          hud_width = has_size ? size_native['width'] : '360px'
          hud_height = if is_min
                         'auto'
                       else
                         (has_size ? size_native['height'] : '260px')
                       end

          hud_style = {
            position: 'fixed',
            top: top_pos,
            left: left_pos,
            width: hud_width,
            height: hud_height,
            maxWidth: '96vw',
            maxHeight: is_min ? 'auto' : '92vh',
            minWidth: '260px',
            minHeight: is_min ? '0' : '140px',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 45px rgba(0, 0, 0, 0.45), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            border: '1.5px solid #64748b',
            zIndex: '9999999',
            pointerEvents: 'auto',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            resize: is_min ? 'none' : 'both',
            userSelect: 'none',
          }

          btn_style = {
            background: 'none',
            border: 'none',
            fontSize: '1.1rem',
            color: '#475569',
            cursor: 'pointer',
            padding: '0 4px',
            borderRadius: '3px',
            lineHeight: '1',
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
          }

          h('div#phases_floating_hud', {
              style: hud_style,
              on: {
                mouseup: lambda {
                  %x{
                    var hud = document.getElementById('phases_floating_hud');
                    if (hud && hud.style.width && hud.style.height && !#{is_min}) {
                      try {
                        localStorage.setItem('phases_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
                      } catch(e) {}
                    }
                  }
                },
              },
            }, [
            h('div#phases_hud_handle', {
                style: {
                  padding: '0.45rem 0.75rem',
                  backgroundColor: '#e2e8f0',
                  borderBottom: is_min ? 'none' : '1px solid #cbd5e1',
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
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem', pointerEvents: 'none' } }, [
                h(:span, { style: { fontSize: '0.95rem', color: '#64748b' } }, '⠿'),
                h(:h3, { style: { margin: '0', fontSize: '0.9rem', color: '#0f172a', fontWeight: '800' } }, 'Phases'),
              ]),
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '4px' } }, [
                h(:button, {
                    attrs: { id: 'btn_minimize_phases_overlay', type: 'button', title: is_min ? 'Restore' : 'Minimize' },
                    style: btn_style,
                    on: {
                      click: lambda { |e|
                        `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
                        toggle_minimize
                      },
                    },
                  }, is_min ? '▢' : '—'),
                h(:button, {
                    attrs: { id: 'btn_close_phases_overlay', type: 'button', title: 'Close' },
                    style: btn_style,
                    on: {
                      click: lambda { |e|
                        `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
                        close_overlay
                      },
                    },
                  }, '✕'),
              ]),
            ]),

            h('div#phases_overlay_scroll_body', {
                style: {
                  flex: '1',
                  overflowY: 'auto',
                  backgroundColor: '#ffffff',
                  userSelect: 'text',
                  display: is_min ? 'none' : 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  justifyContent: 'center',
                  padding: '1.5rem',
                  textAlign: 'center',
                  gap: '0.4rem',
                },
              }, [
              h(:span, { style: { fontSize: '1.8rem', lineHeight: '1' } }, '⏱️'),
              h(:strong, { style: { color: '#0f172a', fontSize: '0.95rem' } }, 'Phases Overview'),
              h(:span, { style: { color: '#64748b', fontSize: '0.8rem' } }, 'Phase details and status will be displayed here.'),
            ]),

            (unless is_min
               h('div#phases_overlay_resize_grip', {
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
               ])
             end),
          ])
        end
      end
    end
  end
end
