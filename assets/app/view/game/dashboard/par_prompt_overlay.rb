# frozen_string_literal: true

# backtick_javascript: true

# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'lib/settings'
require 'lib/storage'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    module Dashboard
      class ParPromptOverlay < Snabberb::Component
        include Actionable
        include Lib::Settings
        include View::Game::Dashboard::RailcardHelper

        FONT_MONEY = '"Courier New", Courier, monospace'
        FONT_STD = '"Helvetica Neue", Helvetica, Arial, sans-serif'
        COLOR_INACTIVE = '#e2e8f0'

        needs :game, store: true
        needs :step, default: nil
        needs :entity, default: nil
        needs :corporation, default: nil
        needs :on_cancel, default: nil

        def resolve_step
          @step || @game.round.active_step
        end

        def resolve_actual_corporation(active_step)
          if @corporation && (!active_step.respond_to?(:corporation_pending_par) || !active_step.corporation_pending_par)
            return @corporation
          end

          corp = if active_step.respond_to?(:corporation_pending_par) && active_step.corporation_pending_par
                   active_step.corporation_pending_par
                 elsif active_step.respond_to?(:par_corporation) && active_step.par_corporation
                   active_step.par_corporation
                 elsif active_step.respond_to?(:corporation) && active_step.corporation
                   active_step.corporation
                 end
          return corp if corp

          transacted_company = nil
          %i[company last_company auctioning].each do |m|
            if active_step.respond_to?(m) && (c_val = active_step.send(m))
              transacted_company = c_val if c_val.is_a?(Engine::Company) || c_val.respond_to?(:abilities)
              break if transacted_company
            end
          end

          if !transacted_company && active_step.instance_variable_defined?(:@company)
            c_val = active_step.instance_variable_get(:@company)
            transacted_company = c_val if c_val
          end

          if !transacted_company && @game.respond_to?(:actions) && @game.actions&.any?
            last_act = @game.actions.last
            transacted_company = last_act.company if last_act.respond_to?(:company) && last_act.company
          end

          if transacted_company
            ability = if @game.respond_to?(:abilities)
                        @game.abilities(transacted_company, :shares) || @game.abilities(transacted_company, :close_to_float)
                      end

            if !ability && transacted_company.respond_to?(:all_abilities)
              ability = transacted_company.all_abilities.find { |a| a.type == :shares }
            end
            if !ability && transacted_company.respond_to?(:abilities)
              ability = Array(transacted_company.abilities).find { |a| a.type == :shares }
            end

            if ability&.respond_to?(:shares)
              sh = ability.shares.first
              corp = sh.corporation if sh&.respond_to?(:corporation)
              return corp if corp
            end

            c_sym = transacted_company.sym.to_s
            c_id = transacted_company.id.to_s
            corp = @game.corporations.find do |c|
              c.id.to_s == c_id || c.name.to_s == c_id || (c.respond_to?(:sym) && c.sym.to_s == c_sym)
            end
            return corp if corp
          end

          @corporation
        end

        def resolve_actor
          if @entity.respond_to?(:player?) && @entity.player?
            @entity
          elsif @entity.respond_to?(:owner) && @entity.owner.respond_to?(:player?) && @entity.owner.player?
            @entity.owner
          elsif @game.round.respond_to?(:current_entity) && @game.round.current_entity&.player?
            @game.round.current_entity
          elsif @game.respond_to?(:current_entity) && @game.current_entity&.player?
            @game.current_entity
          else
            @entity
          end
        end

        def render
          active_step = resolve_step
          actual_corp = resolve_actual_corporation(active_step)
          return h(:div) unless actual_corp

          par_actor = resolve_actor || @game.players.first
          return h(:div) unless par_actor

          par_nodes = if active_step.respond_to?(:get_par_prices_with_help)
                        active_step.get_par_prices_with_help(par_actor, actual_corp)
                      elsif active_step.respond_to?(:get_par_prices)
                        active_step.get_par_prices(par_actor, actual_corp)
                      elsif active_step.respond_to?(:par_prices)
                        begin
                          active_step.par_prices(par_actor, actual_corp)
                        rescue ArgumentError
                          active_step.par_prices(actual_corp)
                        end
                      elsif @game.respond_to?(:par_prices)
                        @game.par_prices(actual_corp)
                      else
                        @game.stock_market.par_prices
                      end

          par_nodes = par_nodes.sort_by do |node|
            price = node.is_a?(Array) ? node[0] : node
            price.respond_to?(:price) ? price.price : price
          end.reverse

          if @game.respond_to?(:par_chart)
            par_nodes = par_nodes.reject do |node|
              p_obj = node.is_a?(Array) ? node.first : node
              slots = @game.par_chart[p_obj]
              slots && slots.none?(&:nil?)
            end
          end

          corp_bg = actual_corp.color || '#0f172a'
          corp_fg = actual_corp.text_color || '#ffffff'
          full_corp_name = actual_corp.respond_to?(:full_name) && actual_corp.full_name ? actual_corp.full_name : actual_corp.name

          logo_src = begin
            setting_for(:simple_logos, @game) ? actual_corp.simple_logo : actual_corp.logo
          rescue StandardError
            nil
          end

          logo_element = if logo_src
                           h(:img, {
                               attrs: { src: logo_src, alt: actual_corp.name },
                               style: {
                                 width: '38px',
                                 height: '38px',
                                 objectFit: 'contain',
                                 borderRadius: '6px',
                                 backgroundColor: '#ffffff',
                                 padding: '2px',
                                 boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
                                 flexShrink: '0',
                               },
                             })
                         else
                           h(:div, {
                               style: {
                                 width: '38px',
                                 height: '38px',
                                 display: 'flex',
                                 alignItems: 'center',
                                 justifyContent: 'center',
                                 backgroundColor: '#ffffff',
                                 color: corp_bg,
                                 fontWeight: '800',
                                 fontSize: '1.15rem',
                                 borderRadius: '6px',
                                 boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
                                 flexShrink: '0',
                               },
                             }, actual_corp.name)
                         end

          shares_range = (2..10).to_a

          headers = [
            h(:th, {
                style: {
                  padding: '8px 10px',
                  border: '1px solid #cbd5e1',
                  backgroundColor: '#cbd5e1',
                  color: '#0f172a',
                  fontWeight: '800',
                  textAlign: 'center',
                  fontFamily: FONT_STD,
                  fontSize: '0.85rem',
                  minWidth: '5.6rem',
                },
              }, 'Par Price'),
          ]

          share_percent = actual_corp.respond_to?(:share_percent) && actual_corp.share_percent ? actual_corp.share_percent : 10

          shares_range.each do |n|
            headers << h(:th, {
                           style: {
                             padding: '8px 4px',
                             border: '1px solid #cbd5e1',
                             backgroundColor: COLOR_INACTIVE,
                             color: '#1e293b',
                             fontWeight: 'bold',
                             textAlign: 'center',
                             minWidth: '3.4rem',
                             fontFamily: FONT_STD,
                             fontSize: '0.85rem',
                           },
                         }, "#{n * share_percent}%")
          end

          actor_cash = par_actor.respond_to?(:cash) ? par_actor.cash : 0

          pres_multiplier = if actual_corp.respond_to?(:presidents_percent) && actual_corp.respond_to?(:share_percent)
                              (actual_corp.presidents_percent / actual_corp.share_percent).to_i
                            elsif actual_corp.respond_to?(:shares) && actual_corp.shares.first&.president
                              actual_corp.shares.first.num_shares || 2
                            else
                              2
                            end

          matrix_rows = par_nodes.map do |node|
            price_obj = node.is_a?(Array) ? node[0] : node
            help = node.is_a?(Array) ? node[1] : nil
            price_val = price_obj.respond_to?(:price) ? price_obj.price : price_obj

            float_shares = if @game.respond_to?(:total_shares_to_float)
                             @game.total_shares_to_float(actual_corp, price_val)
                           else
                             (actual_corp.float_percent || 60) / (actual_corp.share_percent || 10)
                           end

            price_label = @game.format_currency(price_val)
            price_label += " (#{help})" if help

            par_cost = price_val * pres_multiplier
            can_par = actor_cash >= par_cost

            par_click_handler = if can_par
                                  lambda {
                                    Lib::Storage['par_menu_corp'] = nil
                                    @on_cancel&.call
                                    slot = (@game.par_chart[price_obj].index(nil) if @game.respond_to?(:par_chart) && @game.par_chart[price_obj])
                                    args = { corporation: actual_corp, share_price: price_obj }
                                    args[:slot] = slot if slot
                                    process_action(Engine::Action::Par.new(par_actor, **args))
                                  }
                                end

            row_cells = [
              h(:td, {
                  style: {
                    padding: '3px 4px',
                    border: '1px solid #cbd5e1',
                    backgroundColor: '#f1f5f9',
                    textAlign: 'center',
                  },
                }, [
                h(:button, {
                    attrs: { disabled: !can_par },
                    style: {
                      width: '100%',
                      boxSizing: 'border-box',
                      padding: '5px 8px',
                      border: can_par ? '2px solid #16a34a' : '1px solid #cbd5e1',
                      borderRadius: '4px',
                      backgroundColor: can_par ? '#dcfce7' : '#e2e8f0',
                      color: can_par ? '#14532d' : '#94a3b8',
                      fontWeight: '800',
                      fontFamily: FONT_MONEY,
                      fontSize: '0.95rem',
                      textAlign: 'center',
                      whiteSpace: 'nowrap',
                      cursor: can_par ? 'pointer' : 'not-allowed',
                      boxShadow: can_par ? '0 1px 3px rgba(22, 163, 74, 0.25)' : 'none',
                    },
                    on: can_par ? { click: par_click_handler } : {},
                  }, price_label),
              ]),
            ]

            shares_range.each do |n|
              cost = n * price_val
              can_afford = actor_cash >= cost
              is_float = (n == float_shares)

              bg_color = can_afford ? '#86efac' : '#f8fafc'
              fg_color = can_afford ? '#000000' : '#94a3b8'
              border_style = is_float ? '2px solid #dc2626' : '1px solid #cbd5e1'

              cell_props = {
                style: {
                  padding: '6px 4px',
                  border: border_style,
                  backgroundColor: bg_color,
                  color: fg_color,
                  cursor: 'default',
                  textAlign: 'center',
                  fontWeight: 'bold',
                  fontFamily: FONT_MONEY,
                  fontSize: '0.88rem',
                },
              }

              row_cells << h(:td, cell_props, @game.format_currency(cost))
            end

            h(:tr, row_cells)
          end

          table_elem = h(:table, {
                           style: {
                             borderCollapse: 'collapse',
                             width: '100%',
                             boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                           },
                         }, [
            h(:thead, [h(:tr, headers)]),
            h(:tbody, matrix_rows),
          ])

          is_minimized = Lib::Storage['par_prompt_overlay_minimized'] || false

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('par_prompt_overlay_left');
              if (l && l !== 'undefined' && l !== 'null' && !isNaN(parseFloat(l))) {
                var val = parseFloat(l);
                var maxLeft = Math.max(10, window.innerWidth - 790);
                if (val >= 10 && val <= maxLeft) {
                  return val;
                }
              }
              sessionStorage.removeItem('par_prompt_overlay_left');
              return null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('par_prompt_overlay_top');
              if (t && t !== 'undefined' && t !== 'null' && !isNaN(parseFloat(t))) {
                var val = parseFloat(t);
                if (val >= 0 && val <= (window.innerHeight - 80)) {
                  return val;
                }
              }
              sessionStorage.removeItem('par_prompt_overlay_top');
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

            if (ev.preventDefault) {
              ev.preventDefault();
            }

            var modal = document.getElementById('par-prompt-overlay-dialog');
            if (!modal) return;

            var header = document.getElementById('par-prompt-overlay-header');
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
                  sessionStorage.setItem('par_prompt_overlay_left', finalRect.left);
                  sessionStorage.setItem('par_prompt_overlay_top', finalRect.top);
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
              sessionStorage.removeItem('par_prompt_overlay_left');
              sessionStorage.removeItem('par_prompt_overlay_top');
            } catch(e) {}
            var modal = document.getElementById('par-prompt-overlay-dialog');
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
            Lib::Storage['par_prompt_overlay_minimized'] = !is_minimized
            update
          end

          dialog_style = {
            width: '780px',
            maxWidth: '96vw',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.1)',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            border: "2px solid #{corp_bg}",
            pointerEvents: 'auto',
            position: 'fixed',
            margin: '0',
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

          dialog_style[:maxHeight] = is_minimized ? 'auto' : '88vh'

          cancel_action = lambda {
            Lib::Storage['par_menu_corp'] = nil
            @on_cancel&.call
            update
          }

          header_controls = [
            h(:button, {
                attrs: { title: 'Cancel par selection' },
                style: {
                  boxSizing: 'border-box',
                  height: '26px',
                  padding: '0 10px',
                  fontSize: '0.78rem',
                  fontWeight: 'bold',
                  backgroundColor: '#dc2626',
                  color: '#ffffff',
                  border: '1px solid rgba(0, 0, 0, 0.25)',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  lineHeight: '1',
                  margin: '0',
                  boxShadow: '0 1px 2px rgba(0,0,0,0.15)',
                },
                on: { click: cancel_action },
              }, 'Cancel'),
            h(:button, {
                attrs: { title: is_minimized ? 'Expand overlay' : 'Minimize overlay' },
                style: {
                  boxSizing: 'border-box',
                  height: '26px',
                  padding: '0 8px',
                  fontSize: '0.78rem',
                  fontWeight: '600',
                  backgroundColor: '#f8fafc',
                  color: '#1e293b',
                  border: '1px solid rgba(0, 0, 0, 0.2)',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  lineHeight: '1',
                  margin: '0',
                  boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                },
                on: { click: toggle_minimize },
              }, is_minimized ? 'Expand' : 'Minimize'),
          ]

          body_content = if is_minimized
                           nil
                         else
                           h(:div, { style: { overflowY: 'auto', overflowX: 'hidden', padding: '0.75rem', display: 'flex', flexDirection: 'column' } }, [
                             table_elem,
                           ])
                         end

          dialog_children = [
            h(:div, {
                attrs: { id: 'par-prompt-overlay-header' },
                style: {
                  padding: '0.6rem 1rem',
                  borderBottom: is_minimized ? 'none' : '2px solid rgba(0,0,0,0.15)',
                  backgroundColor: corp_bg,
                  color: corp_fg,
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
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.75rem', minWidth: '0' } }, [
                logo_element,
                h(:div, { style: { display: 'flex', flexDirection: 'column', minWidth: '0' } }, [
                  h(:h2, {
                      style: {
                        margin: '0',
                        fontSize: '1.25rem',
                        fontWeight: 'bold',
                        color: corp_fg,
                        lineHeight: '1.2',
                        whiteSpace: 'nowrap',
                      },
                    }, full_corp_name),
                  h(:span, {
                      style: {
                        fontSize: '0.78rem',
                        color: corp_fg,
                        opacity: '0.85',
                        fontWeight: '600',
                        lineHeight: '1',
                        marginTop: '2px',
                      },
                    }, "Establish Par Price (#{actual_corp.name})"),
                ]),
              ]),
              h(:div, {
                  style: {
                    display: 'flex',
                    flexDirection: 'row',
                    alignItems: 'center',
                    gap: '0.4rem',
                    flexShrink: '0',
                  },
                }, header_controls),
            ]),
          ]
          dialog_children << body_content if body_content

          h(:div, {
              attrs: { id: 'par-prompt-overlay-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'none',
                zIndex: '100060',
              },
            }, [
              h(:div, {
                  attrs: { id: 'par-prompt-overlay-dialog' },
                  style: dialog_style,
                }, dialog_children),
            ])
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
