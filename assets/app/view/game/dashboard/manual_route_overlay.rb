# frozen_string_literal: true

# backtick_javascript: true

require 'view/game/actionable'
require 'lib/settings'
require 'lib/storage'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    module Dashboard
      class ManualRouteOverlay < Snabberb::Component
        include Actionable
        include Lib::Settings
        include View::Game::Dashboard::RailcardHelper

        FONT_MONEY = '"Courier New", Courier, monospace'
        COLOR_MONEY = '#4c1d95'
        SCREAMING_PALETTE = ['#ff1493', '#00ffff', '#7fff00', '#ff00ff'].freeze

        needs :game, store: true
        needs :routes, store: true, default: []
        needs :selected_route, store: true, default: nil
        needs :cmd_router_running, store: true, default: false
        needs :show_manual_routes, store: true, default: false
        needs :entity, default: nil

        def current_entity
          @entity ||
            @game.round.active_step&.current_entity ||
            (@game.round.respond_to?(:current_entity) ? @game.round.current_entity : nil) ||
            @game.current_entity
        rescue NotImplementedError, StandardError
          nil
        end

        def active_routes
          @routes.select { |r| r.chains.any? }
        end

        def render
          entity = current_entity
          return h(:div) unless entity

          trains = begin
            if @game.respond_to?(:route_trains)
              @game.route_trains(entity)
            elsif entity.respond_to?(:trains)
              entity.trains
            else
              []
            end
          rescue StandardError
            entity.respond_to?(:trains) ? entity.trains : []
          end || []

          trains = entity.trains || [] if trains.empty? && entity.respond_to?(:trains)

          if @routes.empty? && trains.any?
            trains.each do |t|
              @routes << Engine::Route.new(@game, @game.phase, t, routes: @routes)
            end
            store(:routes, @routes, skip: true)
          end

          current_route = @selected_route || @routes.first
          if current_route != @selected_route && current_route
            @selected_route = current_route
            store(:selected_route, @selected_route, skip: true)
          end

          logo_src = begin
            setting_for(:simple_logos, @game) ? entity&.simple_logo : entity&.logo
          rescue StandardError
            nil
          end

          bg_color = entity.respond_to?(:color) ? (entity.color || '#4169e1') : '#333333'
          text_color = entity.respond_to?(:text_color) ? (entity.text_color || 'white') : 'white'

          logo_element = if logo_src
                           h(:img, {
                               attrs: { src: logo_src, alt: entity&.name || 'Logo' },
                               style: {
                                 width: '85px',
                                 height: '85px',
                                 objectFit: 'contain',
                                 flexShrink: '0',
                               },
                             })
                         else
                           h(:div, {
                               style: {
                                 width: '85px',
                                 height: '85px',
                                 fontSize: '1.8rem',
                                 fontWeight: 'bold',
                                 display: 'flex',
                                 alignItems: 'center',
                                 justifyContent: 'center',
                                 backgroundColor: bg_color,
                                 color: text_color,
                                 borderRadius: '8px',
                                 flexShrink: '0',
                               },
                             }, entity&.id || entity&.name || 'N/A')
                         end

          train_cards = trains.map.with_index do |train, idx|
            route = @routes.find { |r| r.train == train }
            selected = @selected_route&.train == train
            track_color = SCREAMING_PALETTE[idx % SCREAMING_PALETTE.size]

            rev_val = begin
              if route && route.chains.any?
                @game.respond_to?(:format_revenue_currency) ? @game.format_revenue_currency(route.revenue) : @game.format_currency(route.revenue)
              else
                @game.format_currency(0)
              end
            rescue StandardError
              'Err'
            end

            stops_str = begin
              if route && route.chains.any?
                dist = if route.respond_to?(:distance_str)
                         route.distance_str
                       else
                         (route.respond_to?(:distance) ? route.distance : nil)
                       end
                dist ? "#{dist} stops" : 'Routed'
              else
                'not assigned'
              end
            rescue StandardError
              'not assigned'
            end

            card_click = lambda {
              target_route = @routes.find { |r| r.train == train }
              unless target_route
                target_route = Engine::Route.new(@game, @game.phase, train, routes: @routes)
                @routes << target_route
                store(:routes, @routes)
              end
              store(:selected_route, target_route)
              update
            }

            card_classes = %w[game-card action-buy]
            card_classes << 'clickable' if selected
            train_badge = render_railcard(train.name, card_classes, card_click)

            h(:div, {
                style: {
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  justifyContent: 'center',
                  padding: '0.4rem 0.6rem',
                  minWidth: '6.2rem',
                  backgroundColor: selected ? '#ffffff' : '#f8fafc',
                  border: "2px solid #{selected ? track_color : '#cbd5e1'}",
                  borderRadius: '6px',
                  cursor: 'pointer',
                  boxShadow: selected ? "0 0 8px #{track_color}88" : '0 1px 2px rgba(0,0,0,0.05)',
                  opacity: selected ? '1.0' : '0.75',
                },
                on: { click: card_click },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, [
                h(:span, {
                    style: {
                      width: '0.75rem',
                      height: '0.75rem',
                      borderRadius: '50%',
                      backgroundColor: track_color,
                      display: 'inline-block',
                      flexShrink: '0',
                    },
                  }),
                train_badge,
              ]),
              h(:span, { style: { fontSize: '0.75rem', color: '#64748b', marginTop: '0.2rem' } }, stops_str),
              h(:span, {
                  style: {
                    fontWeight: 'bold',
                    fontSize: '0.95rem',
                    fontFamily: FONT_MONEY,
                    color: COLOR_MONEY,
                    marginTop: '0.15rem',
                  },
                }, rev_val),
            ])
          end

          curr_idx = @routes.index(@selected_route) || 0
          active_color = SCREAMING_PALETTE[curr_idx % SCREAMING_PALETTE.size]
          err_msg = nil
          begin
            @selected_route&.revenue if @selected_route&.chains&.any?
          rescue Engine::GameError, StandardError => e
            err_msg = e.to_s
          end

          clear_selected = lambda {
            @selected_route&.reset!
            store(:selected_route, @selected_route)
            store(:routes, @routes)
            update
          }

          clear_all_routes = lambda {
            @routes.each(&:reset!)
            @game.reset_adjustable_trains!(entity, @routes) if @game.respond_to?(:reset_adjustable_trains!)
            store(:routes, @routes)
            store(:selected_route, @routes.first)
            update
          }

          trigger_auto = lambda {
            store(:cmd_router_running, true)
            update
            lambda {
              `setTimeout(function() {`
              begin
                flash_cb = lambda do |msg|
                  store(:flash_opts, { message: msg }, skip: false)
                end
                router = Engine::AutoRouter.new(@game, flash_cb)
                router_entity = @game.current_entity || entity
                p_timeout = setting_for(:path_timeout).to_i
                p_timeout = 10_000 if p_timeout.zero?
                r_timeout = setting_for(:route_timeout).to_i
                r_timeout = 10_000 if r_timeout.zero?

                @routes.each(&:reset!) if @routes&.any?
                @game.reset_adjustable_trains!(entity, @routes) if @game.respond_to?(:reset_adjustable_trains!)

                router.compute(
                  router_entity,
                  routes: [],
                  path_timeout: p_timeout,
                  route_timeout: r_timeout,
                  callback: lambda do |computed_routes|
                    routes_list = computed_routes || []
                    store(:routes, routes_list, skip: true)
                    store(:selected_route, routes_list.first, skip: true)

                    auto_rev = 0
                    routes_list.each do |r|
                      auto_rev += r.revenue if r.chains.any?
                    rescue Engine::GameError, StandardError
                    end

                    storage_key = "rev_override_#{entity&.id}"
                    last_base_key = "last_base_rev_#{entity&.id}"
                    Lib::Storage[storage_key] = auto_rev
                    Lib::Storage[last_base_key] = auto_rev

                    store(:cmd_router_running, false)
                    update
                  end
                )
              rescue Exception
                store(:cmd_router_running, false)
                update
              end
              `}, 50);`
            }.call
          }

          base_revenue = 0
          active_routes.each do |r|
            base_revenue += r.revenue if r.chains.any?
          rescue Engine::GameError, StandardError
          end
          storage_key = "rev_override_#{entity&.id}"
          current_revenue = Lib::Storage[storage_key] ? Lib::Storage[storage_key].to_i : base_revenue
          formatted_rev = @game.respond_to?(:format_revenue_currency) ? @game.format_revenue_currency(current_revenue) : @game.format_currency(current_revenue)

          submit_and_close = lambda {
            routes_to_submit = active_routes
            process_action(Engine::Action::RunRoutes.new(
              entity,
              routes: routes_to_submit,
              extra_revenue: @game.extra_revenue(entity, routes_to_submit) + (current_revenue - base_revenue)
            ))
            store(:selected_route, nil, skip: true)
            store(:show_manual_routes, false)
            Lib::Storage['cmd_manual_routes'] = false
            update
          }

          close_manual = lambda {
            store(:selected_route, nil, skip: true)
            store(:show_manual_routes, false)
            Lib::Storage['cmd_manual_routes'] = false
            update
          }

          is_minimized = Lib::Storage['manual_route_overlay_minimized'] || false

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('manual_route_overlay_left');
              var parsed = parseFloat(l);
              if (l && l !== 'undefined' && l !== 'null' && !isNaN(parsed) && parsed >= 10 && parsed < (window.innerWidth - 100)) {
                return parsed;
              }
              return null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('manual_route_overlay_top');
              var parsed = parseFloat(t);
              if (t && t !== 'undefined' && t !== 'null' && !isNaN(parsed) && parsed >= 10 && parsed < (window.innerHeight - 80)) {
                return parsed;
              }
              return null;
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

            if (ev.preventDefault) ev.preventDefault();

            var modal = document.getElementById('manual-route-overlay-dialog');
            if (!modal) return;

            var header = document.getElementById('manual-route-overlay-header');
            if (header) header.style.cursor = 'grabbing';

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

              var maxLeft = window.innerWidth - 80;
              var maxTop = window.innerHeight - 50;

              if (newLeft < 10) newLeft = 10;
              if (newLeft > maxLeft) newLeft = maxLeft;
              if (newTop < 0) newTop = 0;
              if (newTop > maxTop) newTop = maxTop;

              modal.style.left = newLeft + 'px';
              modal.style.top = newTop + 'px';
            }

            function onMouseUp() {
              document.removeEventListener('mousemove', onMouseMove, true);
              document.removeEventListener('mouseup', onMouseUp, true);
              window.removeEventListener('mousemove', onMouseMove, true);
              window.removeEventListener('mouseup', onMouseUp, true);

              if (header) header.style.cursor = 'grab';

              var finalRect = modal.getBoundingClientRect();
              if (finalRect && !isNaN(finalRect.left) && !isNaN(finalRect.top)) {
                try {
                  sessionStorage.setItem('manual_route_overlay_left', finalRect.left);
                  sessionStorage.setItem('manual_route_overlay_top', finalRect.top);
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
              sessionStorage.removeItem('manual_route_overlay_left');
              sessionStorage.removeItem('manual_route_overlay_top');
            } catch(e) {}
            var modal = document.getElementById('manual-route-overlay-dialog');
            if (modal) {
              modal.style.left = '50%';
              modal.style.top = '45%';
              modal.style.transform = 'translate(-50%, -50%)';
              modal.style.margin = '0';
            }
            )
            update
          end

          toggle_minimize = lambda do
            Lib::Storage['manual_route_overlay_minimized'] = !is_minimized
            update
          end

          dialog_style = {
            width: '650px',
            maxWidth: '94vw',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            border: '2px solid #0f172a',
            pointerEvents: 'auto',
            margin: '0',
            zIndex: '100060',
          }
          if saved_left && saved_top
            dialog_style[:position] = 'fixed'
            dialog_style[:left] = "#{saved_left}px"
            dialog_style[:top] = "#{saved_top}px"
            dialog_style[:transform] = 'none'
          else
            dialog_style[:position] = 'relative'
          end

          header_controls = [
            h(:button, {
                attrs: { title: is_minimized ? 'Expand overlay' : 'Minimize overlay' },
                style: {
                  padding: '0 8px',
                  height: '1.5rem',
                  fontSize: '0.78rem',
                  fontWeight: '600',
                  backgroundColor: '#334155',
                  color: '#ffffff',
                  border: '1px solid #475569',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                },
                on: { click: toggle_minimize },
              }, is_minimized ? 'Expand' : 'Minimize'),
            h(:button, {
                attrs: { title: 'Close manual routing' },
                style: {
                  background: 'transparent',
                  border: 'none',
                  color: '#cbd5e1',
                  fontSize: '1.2rem',
                  fontWeight: 'bold',
                  cursor: 'pointer',
                  padding: '0 6px',
                  lineHeight: '1',
                },
                on: { click: close_manual },
              }, '✕'),
          ]

          body_content = if is_minimized
                           nil
                         else
                           h(:div, {
                               style: {
                                 padding: '0.9rem',
                                 display: 'flex',
                                 flexDirection: 'row',
                                 alignItems: 'center',
                                 gap: '1rem',
                               },
                             }, [
                             logo_element,
                             h(:div, {
                                 style: {
                                   display: 'flex',
                                   flexDirection: 'column',
                                   gap: '0.7rem',
                                   flex: '1 1 auto',
                                   minWidth: '0',
                                 },
                               }, [
                               (if train_cards.any?
                                  h(:div,
                                    { style: { display: 'flex', flexDirection: 'row', gap: '0.5rem', alignItems: 'center', overflowX: 'auto', paddingBottom: '0.2rem' } }, train_cards)
                                else
                                  h(:div, { style: { color: '#64748b', fontStyle: 'italic', fontSize: '0.85rem' } },
                                    "No trains available for #{entity.name}")
                                end),
                               h(:div, { style: { fontSize: '0.82rem', minHeight: '1.3rem', display: 'flex', alignItems: 'center' } }, [
                                 if err_msg
                                   h(:span, { style: { color: '#dc2626', fontWeight: 'bold' } }, "⚠️ #{err_msg}")
                                 else
                                   track_info = begin
                                     if @selected_route&.chains&.any? && @selected_route.respond_to?(:stops)
                                       stops = @selected_route.stops.map do |stop|
                                         rev = begin
                                           if @selected_route.respond_to?(:stop_revenue)
                                             @selected_route.stop_revenue(stop)
                                           elsif stop.respond_to?(:route_revenue)
                                             stop.route_revenue(@game.phase, @selected_route.train)
                                           elsif stop.respond_to?(:revenue)
                                             stop.revenue(@selected_route.train, @game.phase)
                                           end
                                         rescue StandardError
                                           nil
                                         end
                                         hex_name = stop.respond_to?(:hex) && stop.hex ? stop.hex.name : stop.to_s
                                         rev ? "#{hex_name} (#{@game.format_currency(rev)})" : hex_name
                                       end.join(' ➔ ')
                                       stops.empty? ? 'No stops connected' : "Track: #{stops}"
                                     else
                                       'Click revenue centers on the map to route or cycle paths.'
                                     end
                                   rescue StandardError
                                     'Click revenue centers on the map to route or cycle paths.'
                                   end

                                   h(:span, { style: { color: '#334155' } }, [
                                     h(:strong, { style: { color: active_color } },
                                       "Train #{@selected_route&.train&.name || '-'}: "),
                                     h(:span, track_info),
                                   ])
                                 end,
                               ]),
                               h(:div, { style: { display: 'flex', flexDirection: 'row', gap: '0.5rem', alignItems: 'center', marginTop: '0.2rem' } }, [
                                 h(:button, {
                                     style: {
                                       height: '1.85rem',
                                       padding: '0 10px',
                                       fontSize: '0.82rem',
                                       fontWeight: 'bold',
                                       backgroundColor: '#f1f5f9',
                                       border: '1px solid #cbd5e1',
                                       borderRadius: '4px',
                                       cursor: 'pointer',
                                     },
                                     on: { click: clear_selected },
                                   }, 'Clear Train'),
                                 h(:button, {
                                     style: {
                                       height: '1.85rem',
                                       padding: '0 10px',
                                       fontSize: '0.82rem',
                                       fontWeight: 'bold',
                                       backgroundColor: '#f1f5f9',
                                       border: '1px solid #cbd5e1',
                                       borderRadius: '4px',
                                       cursor: 'pointer',
                                     },
                                     on: { click: clear_all_routes },
                                   }, 'Clear All'),
                                 h(:button, {
                                     style: {
                                       height: '1.85rem',
                                       padding: '0 12px',
                                       fontSize: '0.82rem',
                                       fontWeight: 'bold',
                                       backgroundColor: '#2563eb',
                                       color: '#fff',
                                       border: 'none',
                                       borderRadius: '4px',
                                       cursor: 'pointer',
                                     },
                                     on: { click: trigger_auto },
                                   }, 'Auto'),
                                 h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.25rem', marginLeft: 'auto' } }, [
                                   h(:button, {
                                       attrs: { title: 'Decrease revenue override by 10' },
                                       style: {
                                         width: '1.85rem',
                                         height: '1.85rem',
                                         fontSize: '1rem',
                                         fontWeight: 'bold',
                                         cursor: 'pointer',
                                         backgroundColor: '#f1f5f9',
                                         border: '1px solid #cbd5e1',
                                         borderRadius: '4px',
                                         display: 'inline-flex',
                                         alignItems: 'center',
                                         justifyContent: 'center',
                                         padding: '0',
                                         lineHeight: '1',
                                       },
                                       on: {
                                         click: lambda {
                                           Lib::Storage[storage_key] = [current_revenue - 10, 0].max
                                           update
                                         },
                                       },
                                     }, '-'),
                                   h(:button, {
                                       attrs: { title: 'Increase revenue override by 10' },
                                       style: {
                                         width: '1.85rem',
                                         height: '1.85rem',
                                         fontSize: '1rem',
                                         fontWeight: 'bold',
                                         cursor: 'pointer',
                                         backgroundColor: '#f1f5f9',
                                         border: '1px solid #cbd5e1',
                                         borderRadius: '4px',
                                         display: 'inline-flex',
                                         alignItems: 'center',
                                         justifyContent: 'center',
                                         padding: '0',
                                         lineHeight: '1',
                                       },
                                       on: {
                                         click: lambda {
                                           Lib::Storage[storage_key] = current_revenue + 10
                                           update
                                         },
                                       },
                                     }, '+'),
                                   h(:button, {
                                       style: {
                                         height: '1.85rem',
                                         padding: '0 14px',
                                         fontSize: '0.9rem',
                                         fontWeight: 'bold',
                                         backgroundColor: '#16a34a',
                                         color: '#fff',
                                         border: 'none',
                                         borderRadius: '4px',
                                         cursor: 'pointer',
                                         boxShadow: '0 1px 3px rgba(0,0,0,0.15)',
                                       },
                                       on: { click: submit_and_close },
                                     }, "Submit #{formatted_rev}"),
                                 ]),
                               ]),
                             ]),
                           ])
                         end

          dialog_children = [
            h(:div, {
                attrs: { id: 'manual-route-overlay-header' },
                style: {
                  padding: '0.7rem 1.1rem',
                  backgroundColor: '#0f172a',
                  color: '#ffffff',
                  borderBottom: is_minimized ? 'none' : '1px solid #e2e8f0',
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
              h(:div, [
                h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem' } }, [
                  h(:span, { style: { fontWeight: 'bold', fontSize: '1rem' } }, "Manual Route Selection — #{entity.name}"),
                  h(:span, { style: { fontSize: '0.75rem', color: '#94a3b8', fontStyle: 'italic' } },
                    '(drag to move, dbl-click center)'),
                ]),
              ]),
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, header_controls),
            ]),
          ]
          dialog_children << body_content if body_content

          h(:div, {
              attrs: { id: 'manual-route-overlay-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'none',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                zIndex: '1000000',
              },
            }, [
            h(:div, { attrs: { id: 'manual-route-overlay-dialog' }, style: dialog_style }, dialog_children),
          ])
        end
      end
    end

    ManualRouteOverlay = Dashboard::ManualRouteOverlay
  end
end
