# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/storage'
require 'lib/settings'

module View
  module Game
    module Dashboard
      class PhasesOverlay < Snabberb::Component
        needs :game, store: true
        needs :on_close, default: nil
        needs :minimized, default: false

        include Lib::Settings

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

        def phase_color_hex(color_sym)
          return '#94a3b8' unless color_sym

          begin
            c = color_for(color_sym, @game) || color_for(color_sym)
            return c if c
          rescue StandardError
          end

          case color_sym.to_s.downcase
          when 'yellow' then '#eab308'
          when 'green' then '#22c55e'
          when 'brown' then '#a16207'
          when 'gray', 'grey' then '#64748b'
          else '#cbd5e1'
          end
        end

        def phase_contrast(bg_hex)
          begin
            c = contrast_on(bg_hex)
            return c if c
          rescue StandardError
          end
          '#ffffff'
        end

        def format_train_limit(limit)
          return '—' if limit.nil?

          if limit.is_a?(Hash)
            limit.map { |k, v| "#{k.to_s.capitalize}: #{v}" }.join(' | ')
          else
            limit.to_s
          end
        end

        def rust_obsolete_schedule
          rust_schedule = Hash.new { |h, k| h[k] = [] }
          obsolete_schedule = Hash.new { |h, k| h[k] = [] }
          depot = @game.respond_to?(:depot) ? @game.depot : nil
          return [rust_schedule, obsolete_schedule] unless depot&.trains

          depot.trains.group_by(&:name).each do |_name, trains|
            first = trains.first
            next unless first.respond_to?(:variants) && first&.variants

            base_variant = first.variants.values.find { |v| !v[:ignore_rust_obsolete_schedule] }
            base_rust = base_variant ? base_variant[:rusts_on] : nil
            base_obsolete = base_variant ? base_variant[:obsolete_on] : nil

            first.variants.each do |name, train_variant|
              next if train_variant[:ignore_rust_obsolete_schedule]

              train_variant[:rusts_on] ||= base_rust
              train_variant[:obsolete_on] ||= base_obsolete

              Array(train_variant[:rusts_on]).each do |rusts_on|
                rust_schedule[rusts_on.to_s].append(name.to_s) unless rust_schedule[rusts_on.to_s].include?(name.to_s)
              end
              Array(train_variant[:obsolete_on]).each do |obsolete_on|
                unless obsolete_schedule[obsolete_on.to_s].include?(name.to_s)
                  obsolete_schedule[obsolete_on.to_s].append(name.to_s)
                end
              end
            end
          end
          [rust_schedule, obsolete_schedule]
        end

        def render_current_status_hero(current_phase, rust_schedule)
          return nil unless current_phase

          curr_name = (current_phase.is_a?(Hash) ? current_phase[:name] : current_phase&.name).to_s
          tile_color = Array(current_phase.is_a?(Hash) ? current_phase[:tiles] : current_phase&.tiles).last
          bg = phase_color_hex(tile_color)
          fg = phase_contrast(bg)
          train_limit = format_train_limit(current_phase.is_a?(Hash) ? current_phase[:train_limit] : current_phase&.train_limit)
          ors = (current_phase.is_a?(Hash) ? current_phase[:operating_rounds] : current_phase&.operating_rounds) || 1

          rust_warning = nil
          if @game.respond_to?(:depot) && @game.depot&.upcoming&.any?
            first_train = @game.depot.upcoming.first
            t_name = first_train.name.to_s
            t_sym = first_train.sym.to_s
            rusted_list = rust_schedule[t_name]&.any? ? rust_schedule[t_name] : rust_schedule[t_sym]
            if rusted_list&.any?
              rem_count = @game.depot.upcoming.count { |t| t.sym == first_train.sym }
              rust_warning = "⚠️ Next Rust: Purchasing next #{t_name}-Train rusts all #{rusted_list.join(', ')}-Trains (#{rem_count} left in depot)."
            end
          end

          h(:div, {
              style: {
                backgroundColor: '#f8fafc',
                border: '1px solid #cbd5e1',
                borderRadius: '6px',
                padding: '0.65rem 0.85rem',
                display: 'flex',
                flexDirection: 'column',
                gap: '0.45rem',
              },
            }, [
            h(:div, { style: { display: 'flex', justifyContent: 'space-between', alignItems: 'center' } }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem' } }, [
                h(:span, { style: { fontSize: '0.75rem', fontWeight: 'bold', color: '#64748b', textTransform: 'uppercase' } },
                  'Active Phase'),
                h(:span, {
                    style: {
                      backgroundColor: bg,
                      color: fg,
                      fontWeight: '800',
                      fontSize: '0.85rem',
                      padding: '2px 8px',
                      borderRadius: '4px',
                    },
                  }, curr_name),
              ]),
              h(:span, { style: { fontSize: '0.78rem', fontWeight: 'bold', color: '#334155' } },
                "Operating Cadence: #{ors} OR#{'s' if ors.to_i > 1} / SR"),
            ]),
            h(:div, { style: { display: 'flex', gap: '1rem', fontSize: '0.8rem', color: '#1e293b' } }, [
              h(:div, [h(:strong, 'Train Limit: '), train_limit]),
              h(:div, [
                h(:strong, 'Tiles: '),
                h(:span, { style: { fontWeight: 'bold', color: bg } }, tile_color ? tile_color.to_s.capitalize : 'Standard'),
              ]),
            ]),
            (if rust_warning
               h(:div, {
                   style: {
                     marginTop: '2px',
                     padding: '4px 8px',
                     backgroundColor: '#fef2f2',
                     border: '1px solid #fecaca',
                     borderRadius: '4px',
                     fontSize: '0.75rem',
                     fontWeight: '700',
                     color: '#991b1b',
                     lineHeight: '1.3',
                   },
                 }, rust_warning)
             end),
          ].compact)
        end

        def render_phases_table(current_phase)
          return nil unless @game.respond_to?(:phase) && @game.phase&.phases

          phases_list = @game.phase.phases
          curr_name = (current_phase.is_a?(Hash) ? current_phase[:name] : current_phase&.name).to_s
          curr_idx = phases_list.index { |p| p == current_phase || p[:name].to_s == curr_name } || 0
          status_map = @game.class.const_defined?(:STATUS_TEXT) ? @game.class::STATUS_TEXT : {}

          header = h(:tr, { style: { backgroundColor: '#f1f5f9', borderBottom: '2px solid #cbd5e1' } }, [
            h(:th, { style: { padding: '5px 8px', textAlign: 'left', fontSize: '0.75rem' } }, 'Phase'),
            h(:th, { style: { padding: '5px 8px', textAlign: 'left', fontSize: '0.75rem' } },
              @game.respond_to?(:on_train_header) ? @game.on_train_header : 'On Train'),
            h(:th, { style: { padding: '5px 8px', textAlign: 'center', fontSize: '0.75rem' } }, 'ORs'),
            h(:th, { style: { padding: '5px 8px', textAlign: 'left', fontSize: '0.75rem' } }, 'Limit'),
            h(:th, { style: { padding: '5px 8px', textAlign: 'center', fontSize: '0.75rem' } }, 'Tiles'),
            h(:th, { style: { padding: '5px 8px', textAlign: 'left', fontSize: '0.75rem' } }, 'Status / Triggers'),
          ])

          rows = phases_list.each_with_index.map do |phase, idx|
            p_name = phase[:name].to_s
            is_active = (idx == curr_idx)
            is_past = (idx < curr_idx)

            tile_sym = Array(phase[:tiles]).last
            bg = phase_color_hex(tile_sym)
            fg = phase_contrast(bg)

            status_badges = []
            phase[:status]&.each do |st|
              title = status_map[st]&.first || st.to_s.tr('_', ' ').capitalize
              status_badges << h(:span, {
                                   style: {
                                     display: 'inline-block',
                                     padding: '1px 5px',
                                     margin: '1px 2px',
                                     backgroundColor: '#e2e8f0',
                                     borderRadius: '3px',
                                     fontSize: '0.7rem',
                                     fontWeight: '600',
                                     color: '#334155',
                                   },
                                 }, title)
            end

            phase[:events]&.each do |ev, val|
              next unless val

              status_badges << h(:span, {
                                   style: {
                                     display: 'inline-block',
                                     padding: '1px 5px',
                                     margin: '1px 2px',
                                     backgroundColor: '#fee2e2',
                                     borderRadius: '3px',
                                     fontSize: '0.7rem',
                                     fontWeight: '700',
                                     color: '#991b1b',
                                   },
                                 }, ev.to_s.tr('_', ' ').capitalize)
            end

            tr_bg = if is_active
                      '#ecfdf5'
                    else
                      (is_past ? '#f8fafc' : '#ffffff')
                    end
            row_opacity = is_past ? '0.55' : '1.0'
            indicator = if is_active
                          '▶ '
                        else
                          (is_past ? '✓ ' : '')
                        end

            h(:tr, {
                style: {
                  backgroundColor: tr_bg,
                  borderBottom: '1px solid #e2e8f0',
                  opacity: row_opacity,
                  fontWeight: is_active ? 'bold' : 'normal',
                },
              }, [
              h(:td, { style: { padding: '5px 8px', color: is_active ? '#15803d' : '#0f172a' } }, "#{indicator}#{p_name}"),
              h(:td, { style: { padding: '5px 8px', color: '#334155' } },
                @game.respond_to?(:info_on_trains) ? @game.info_on_trains(phase) : (phase[:train] || '—')),
              h(:td, { style: { padding: '5px 8px', textAlign: 'center', color: '#334155' } }, phase[:operating_rounds].to_s),
              h(:td, { style: { padding: '5px 8px', color: '#334155' } }, format_train_limit(phase[:train_limit])),
              h(:td, { style: { padding: '5px 8px', textAlign: 'center' } }, [
                h(:span, {
                    style: {
                      display: 'inline-block',
                      backgroundColor: bg,
                      color: fg,
                      padding: '1px 6px',
                      borderRadius: '3px',
                      fontSize: '0.7rem',
                      fontWeight: 'bold',
                    },
                  }, tile_sym ? tile_sym.to_s.capitalize : '—'),
              ]),
              h(:td, { style: { padding: '5px 8px' } }, status_badges.any? ? status_badges : '—'),
            ])
          end

          h(:div, {
              style: {
                overflowX: 'auto',
                border: '1px solid #cbd5e1',
                borderRadius: '6px',
              },
            }, [
            h(:table, {
                style: {
                  width: '100%',
                  borderCollapse: 'collapse',
                  fontSize: '0.78rem',
                  fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
                },
              }, [
              h(:thead, [header]),
              h(:tbody, rows),
            ]),
          ])
        end

        def render_rust_schedule(rust_schedule, obsolete_schedule)
          depot = @game.respond_to?(:depot) ? @game.depot : nil
          all_trains = depot&.trains || []
          return nil if all_trains.empty?

          rows = all_trains.reject(&:reserved).group_by(&:name).map do |name, group|
            train = group.first
            remaining = depot ? depot.upcoming.count { |t| t.name == name } : 0
            rem_str = train.unlimited ? '∞' : "#{remaining} / #{group.size}"

            rusts_others = rust_schedule[name] || []
            obsoletes_others = obsolete_schedule[name] || []

            rusted_by = Array(train.rusts_on).reject { |x| x.nil? || x.to_s.empty? }
            obsoleted_by = Array(train.obsolete_on).reject { |x| x.nil? || x.to_s.empty? }

            effects = []
            effects << "Rusts: #{rusts_others.join(', ')}" if rusts_others.any?
            effects << "Phases out: #{obsoletes_others.join(', ')}" if obsoletes_others.any?
            effects_str = effects.any? ? effects.join(' | ') : '—'

            durability = []
            durability << "Rusted by #{rusted_by.join(', ')}" if rusted_by.any?
            durability << "Phased out by #{obsoleted_by.join(', ')}" if obsoleted_by.any?
            durability_str = durability.any? ? durability.join(' | ') : 'Permanent'

            h(:tr, { style: { borderBottom: '1px solid #e2e8f0', fontSize: '0.75rem' } }, [
              h(:td, { style: { padding: '4px 8px', fontWeight: 'bold' } }, name),
              h(:td, { style: { padding: '4px 8px' } }, @game.format_currency(train.price)),
              h(:td, { style: { padding: '4px 8px', textAlign: 'center' } }, rem_str),
              h(:td, { style: { padding: '4px 8px', color: '#b91c1c', fontWeight: effects.any? ? 'bold' : 'normal' } },
                effects_str),
              h(:td,
                { style: { padding: '4px 8px', color: durability.any? ? '#475569' : '#15803d', fontWeight: durability.any? ? 'normal' : 'bold' } }, durability_str),
            ])
          end

          h(:div, {
              style: {
                display: 'flex',
                flexDirection: 'column',
                gap: '0.3rem',
              },
            }, [
            h(:strong, { style: { fontSize: '0.8rem', color: '#0f172a' } }, 'Train Obsolescence & Rust Rules'),
            h(:div, { style: { overflowX: 'auto', border: '1px solid #cbd5e1', borderRadius: '6px' } }, [
              h(:table, { style: { width: '100%', borderCollapse: 'collapse', fontSize: '0.75rem' } }, [
                h(:thead, [
                  h(:tr, { style: { backgroundColor: '#f1f5f9', borderBottom: '1px solid #cbd5e1' } }, [
                    h(:th, { style: { padding: '4px 8px', textAlign: 'left' } }, 'Train'),
                    h(:th, { style: { padding: '4px 8px', textAlign: 'left' } }, 'Price'),
                    h(:th, { style: { padding: '4px 8px', textAlign: 'center' } }, 'Remaining'),
                    h(:th, { style: { padding: '4px 8px', textAlign: 'left' } }, 'On Purchase Effect'),
                    h(:th, { style: { padding: '4px 8px', textAlign: 'left' } }, 'Durability'),
                  ]),
                ]),
                h(:tbody, rows),
              ]),
            ]),
          ])
        end

        def render_rules_glossary
          status_map = @game.class.const_defined?(:STATUS_TEXT) ? @game.class::STATUS_TEXT : {}
          events_map = @game.class.const_defined?(:EVENTS_TEXT) ? @game.class::EVENTS_TEXT : {}

          entries = []
          status_map.each { |_k, v| entries << [v[0], v[1]] if v&.size == 2 }
          events_map.each { |_k, v| entries << [v[0], v[1]] if v&.size == 2 }
          return nil if entries.empty?

          items = entries.uniq.map do |title, desc|
            h(:div, { style: { fontSize: '0.74rem', marginBottom: '4px', lineHeight: '1.3' } }, [
              h(:strong, { style: { color: '#1e293b' } }, "#{title}: "),
              h(:span, { style: { color: '#475569' } }, desc),
            ])
          end

          h(:div, {
              style: {
                backgroundColor: '#f8fafc',
                border: '1px solid #cbd5e1',
                borderRadius: '6px',
                padding: '0.65rem 0.85rem',
                display: 'flex',
                flexDirection: 'column',
                gap: '0.35rem',
              },
            }, [
            h(:strong, { style: { fontSize: '0.8rem', color: '#0f172a' } }, 'Phase Rules & Event Descriptions'),
            h(:div, { style: { display: 'flex', flexDirection: 'column' } }, items),
          ])
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

          default_left = `Math.max(10, (window.innerWidth || 1200) - 560) + 'px'`
          left_pos = has_pos ? pos_native['left'] : default_left
          top_pos = has_pos ? pos_native['top'] : '80px'

          is_min = minimized?
          hud_width = has_size ? size_native['width'] : '520px'
          hud_height = if is_min
                         'auto'
                       else
                         (has_size ? size_native['height'] : '420px')
                       end

          hud_style = {
            position: 'fixed',
            top: top_pos,
            left: left_pos,
            width: hud_width,
            height: hud_height,
            maxWidth: '96vw',
            maxHeight: is_min ? 'auto' : '92vh',
            minWidth: '320px',
            minHeight: is_min ? '0' : '180px',
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

          current_phase = @game.phase&.current
          rust_sched, obs_sched = rust_obsolete_schedule

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
                h(:h3, { style: { margin: '0', fontSize: '0.9rem', color: '#0f172a', fontWeight: '800' } },
                  'Game Phases & Rules'),
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
                  alignItems: 'stretch',
                  justifyContent: 'flex-start',
                  padding: '0.75rem',
                  gap: '0.75rem',
                  boxSizing: 'border-box',
                },
              }, [
              render_current_status_hero(current_phase, rust_sched),
              render_phases_table(current_phase),
              render_rust_schedule(rust_sched, obs_sched),
              render_rules_glossary,
            ].compact),

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
