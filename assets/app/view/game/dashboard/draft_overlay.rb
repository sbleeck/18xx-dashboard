# frozen_string_literal: true

# backtick_javascript: true

# rubocop:disable Layout/LineLength

require 'view/game/actionable'
require 'lib/settings'
require 'view/game/history_and_undo'
require 'view/game/dashboard/railcard_helper'
require 'view/game/dashboard/par_prompt_overlay'
require 'view/game/dashboard/bidding_overlay'

module View
  module Game
    module Dashboard
      class DraftOverlay < Snabberb::Component
        include Actionable
        include Lib::Settings
        include View::Game::Dashboard::RailcardHelper

        FONT_MONEY = '"Courier New", Courier, monospace'
        COLOR_MONEY = '#4c1d95'

        needs :game, store: true
        needs :actor, default: nil

        def resolve_pending_par(step, entity, actions)
          pending = nil
          %i[corporation_pending_par corporation par_corporation parring target_corporation].each do |m|
            next unless step.respond_to?(m)

            val = begin
              step.send(m)
            rescue StandardError
              nil
            end
            pending = val if val
            break if pending
          end

          if !pending && step.respond_to?(:corporations) && step.corporations&.one?
            pending = step.corporations.first
          elsif !pending && entity.respond_to?(:corporation?) && entity.corporation?
            pending = entity
          end

          unless pending
            transacted_company = nil
            %i[company last_company auctioning].each do |m|
              if step.respond_to?(m) && (c_val = step.send(m))
                transacted_company = c_val if c_val.is_a?(Engine::Company) || c_val.respond_to?(:abilities)
                break if transacted_company
              end
            end

            if !transacted_company && step.instance_variable_defined?(:@company)
              c_val = step.instance_variable_get(:@company)
              transacted_company = c_val if c_val
            end

            if !transacted_company && @game.respond_to?(:actions) && @game.actions&.any?
              last_act = @game.actions.last
              last_company = begin
                last_act.company if last_act.respond_to?(:company)
              rescue StandardError
                nil
              end
              transacted_company = last_company if last_company
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
                pending = sh.corporation if sh&.respond_to?(:corporation)
              end

              if !pending && @game.respond_to?(:corporations)
                c_sym = transacted_company.sym.to_s
                c_id = transacted_company.id.to_s
                pending = @game.corporations.find do |c|
                  c.id.to_s == c_id || c.name.to_s == c_id || (c.respond_to?(:sym) && c.sym.to_s == c_sym)
                end
              end
            end
          end

          if !pending && @game.respond_to?(:corporations)
            player_actor = entity.respond_to?(:player?) && entity.player? ? entity : entity&.owner
            if player_actor&.respond_to?(:companies)
              player_actor.companies.each do |c|
                ability = begin
                  c.abilities(:shares)
                rescue StandardError
                  nil
                end
                next unless ability&.respond_to?(:shares)

                share = begin
                  ability.shares.first
                rescue StandardError
                  nil
                end
                corp = share.corporation if share&.respond_to?(:corporation)
                if corp && !corp.ipoed
                  pending = corp
                  break
                end
              end
            end
          end

          has_par = actions.include?('par')
          if !has_par && pending && @game.round.respond_to?(:actions_for)
            corp_actions = begin
              @game.round.actions_for(pending)
            rescue StandardError
              []
            end || []
            has_par = corp_actions.include?('par')
          end

          has_par ? pending : nil
        rescue StandardError
          nil
        end

        def current_entity
          @game.round.active_step&.current_entity ||
            (@game.round.respond_to?(:current_entity) ? @game.round.current_entity : nil) ||
            @game.current_entity
        rescue NotImplementedError, StandardError
          nil
        end

        def render
          step = @game.round.active_step
          entity = @actor || current_entity
          return h(:div) unless step && entity
          return h(:div) if entity.is_a?(Engine::Bank)

          actions = begin
            @game.round.actions_for(entity)
          rescue StandardError
            step.current_actions || []
          end || []

          # Overlay selection belongs exclusively to DashboardVisualizer.
          # DraftOverlay renders only the multi-item draft/selection table.

          pending_corp = resolve_pending_par(step, entity, actions)

          last_action = @game.respond_to?(:raw_actions) && @game.raw_actions ? @game.raw_actions.last : nil
          last_action_id = if last_action.is_a?(Hash)
                             last_action['id'] || last_action[:id] || 0
                           elsif last_action.respond_to?(:id)
                             last_action.id
                           else
                             0
                           end

          find_entity = lambda do |token|
            return nil if token.nil?
            return nil if token.is_a?(Engine::Player) || (token.respond_to?(:player?) && token.player?) || token.to_s =~ /Player|Blank|Pass/i
            return token if token.is_a?(Engine::Company) || token.is_a?(Engine::Minor)

            if token.is_a?(String) || token.is_a?(Symbol)
              (@game.respond_to?(:companies) ? @game.companies.find { |c| c.id.to_s == token.to_s || (c.respond_to?(:sym) && c.sym.to_s == token.to_s) } : nil) ||
              (@game.respond_to?(:minors) ? @game.minors.find { |m| m.id.to_s == token.to_s || m.name.to_s == token.to_s } : nil)
            end
          end

          available_choices = if step.respond_to?(:choices_for)
                                begin
                                  step.choices_for(entity)
                                rescue ArgumentError
                                  step.choices_for
                                rescue StandardError
                                  nil
                                end
                              elsif step.respond_to?(:choices)
                                begin
                                  step.choices(entity)
                                rescue ArgumentError
                                  step.choices
                                rescue StandardError
                                  nil
                                end
                              end

          choice_list = if available_choices.is_a?(Hash)
                          available_choices.keys
                        elsif available_choices.is_a?(Array)
                          available_choices
                        else
                          []
                        end

          has_blank_card = choice_list.any? do |c|
            c.is_a?(Engine::Player) || (c.respond_to?(:player?) && c.player?) || c.to_s =~ /Player|Blank|Pass/i
          end

          valid_choice_tokens = choice_list.reject do |c|
            c.is_a?(Engine::Player) || (c.respond_to?(:player?) && c.player?) || c.to_s =~ /Player|Blank|Pass/i
          end

          draft_items = []

          if valid_choice_tokens.any?
            valid_choice_tokens.each do |token|
              ent = find_entity.call(token)
              draft_items << ent if ent
            end
          else
            candidates = []

            candidates << step.auctioning if step.respond_to?(:auctioning) && step.auctioning

            %i[available_companies biddable_companies buyable_companies available items cards companies minors].each do |m|
              next unless step.respond_to?(m)

              begin
                res = step.send(m, entity)
              rescue ArgumentError
                begin
                  res = step.send(m)
                rescue StandardError
                  res = nil
                end
              rescue StandardError
                res = nil
              end

              if res.is_a?(Array) || res.is_a?(Hash)
                items_res = res.is_a?(Hash) ? res.keys : res
                candidates.concat(items_res) if items_res&.any?
              end
              break if candidates.any? && m != :minors
            end

            if candidates.empty?
              candidates.concat(@game.companies || []) if @game.respond_to?(:companies)
              candidates.concat(@game.minors || []) if @game.respond_to?(:minors)
            end

            candidates.each do |c|
              ent = find_entity.call(c)
              draft_items << ent if ent
            end
          end

          acquired_items = []
          if @game.respond_to?(:companies) && @game.companies
            acquired_items.concat(@game.companies.select do |c|
              c.respond_to?(:owner) && c.owner && c.owner.respond_to?(:player?) && c.owner.player? && (!c.respond_to?(:closed?) || !c.closed?)
            end)
          end
          if @game.respond_to?(:minors) && @game.minors
            acquired_items.concat(@game.minors.select do |m|
              m.respond_to?(:owner) && m.owner && m.owner.respond_to?(:player?) && m.owner.player? && (!m.respond_to?(:closed?) || !m.closed?)
            end)
          end
          draft_items.concat(acquired_items)

          draft_items = draft_items.compact.uniq.reject do |item|
            item.respond_to?(:closed?) && item.closed?
          end

          all_game_items = (@game.respond_to?(:companies) ? @game.companies : []) +
                           (@game.respond_to?(:minors) ? @game.minors : [])
          items = draft_items.sort_by { |item| all_game_items.index(item) || 999 }

          players = @game.players || []

          can_pass = !pending_corp && (actions.include?('pass') || has_blank_card)

          exec_pass = lambda {
            if actions.include?('pass')
              process_action(Engine::Action::Pass.new(entity))
            elsif actions.include?('choose') && has_blank_card
              blank_item = choice_list.find do |c|
                c.is_a?(Engine::Player) || (c.respond_to?(:player?) && c.player?) || c.to_s =~ /Player|Blank|Pass/i
              end
              choice_val = if available_choices.is_a?(Hash)
                             available_choices.keys.find { |k| k == blank_item || (blank_item.respond_to?(:id) && k == blank_item.id) } || blank_item.id
                           else
                             blank_item.respond_to?(:id) ? blank_item.id : blank_item
                           end
              process_action(Engine::Action::Choose.new(entity, choice: choice_val))
            else
              process_action(Engine::Action::Pass.new(entity))
            end
          }

          rows = items.map do |item|
            is_owned = item.respond_to?(:owner) && item.owner && item.owner.respond_to?(:player?) && item.owner.player?
            item_price = if step.respond_to?(:min_bid)
                           begin
                             step.min_bid(item)
                           rescue ArgumentError
                             step.min_bid
                           rescue StandardError
                             nil
                           end
                         elsif step.respond_to?(:buy_price)
                           begin
                             step.buy_price(item)
                           rescue StandardError
                             nil
                           end
                         elsif step.respond_to?(:price)
                           begin
                             step.price(item)
                           rescue StandardError
                             nil
                           end
                         end

            item_price ||= if item.respond_to?(:min_bid) && item.min_bid&.positive?
                             item.min_bid
                           elsif item.respond_to?(:discount) && item.discount && !item.discount.zero?
                             (item.respond_to?(:value) ? item.value : 0) - item.discount
                           elsif item.respond_to?(:min_price) && item.min_price&.positive?
                             item.min_price
                           elsif item.respond_to?(:price) && item.price&.positive?
                             item.price
                           elsif item.respond_to?(:value) && item.value&.positive?
                             item.value
                           else
                             0
                           end

            can_afford = (entity.respond_to?(:cash) ? entity.cash : 0) >= item_price

            # Determine eligibility and appropriate verb (Bid, Buy, Choose)
            is_actionable = !pending_corp && !is_owned && can_afford
            action_mode = nil

            is_draft = step.class.name.to_s =~ /draft/i ||
                       begin
                         @game.round.class.name.to_s =~ /draft/i
                       rescue StandardError
                         false
                       end ||
                       (step.respond_to?(:draft?) && step.draft?)

            btn_verb = is_draft ? 'Choose' : 'Bid'

            if is_actionable
              if step.respond_to?(:auctioning) && step.auctioning
                # Active auction taking place (e.g. 1844 sequential auctions)
                if step.auctioning == item && actions.include?('bid')
                  action_mode = :bid
                  btn_verb = step.respond_to?(:bid_str) ? step.bid_str(item) : 'Bid'
                end
              elsif actions.include?('bid') && step.respond_to?(:may_bid?) && step.may_bid?(item)
                action_mode = :bid

                btn_verb = if is_draft
                             'Choose'
                           else
                             (step.respond_to?(:bid_str) ? step.bid_str(item) : 'Bid')
                           end
              elsif actions.include?('buy_company') || (actions.include?('bid') && step.respond_to?(:may_purchase?) && step.may_purchase?(item))
                action_mode = actions.include?('buy_company') ? :buy_company : :bid
                btn_verb = step.respond_to?(:buy_str) ? step.buy_str(item) : 'Buy'
              elsif actions.include?('choose') && (step.respond_to?(:may_choose?) ? step.may_choose?(item) : true)
                action_mode = :choose
                btn_verb = 'Choose'
              elsif actions.include?('bid')
                # Fallback auction bid
                action_mode = :bid

                btn_verb = is_draft ? 'Choose' : 'Bid'
              end
            end

            can_choose_item = !action_mode.nil?

            exec_action = lambda {
              case action_mode
              when :bid
                bid_args = { price: item_price }
                if item.respond_to?(:company?) && item.company?
                  bid_args[:company] = item
                elsif item.is_a?(Engine::Minor)
                  comp = @game.company_by_id(item.id) if @game.respond_to?(:company_by_id)
                  bid_args[:company] = comp || item
                elsif item.respond_to?(:corporation?) && item.corporation?
                  bid_args[:corporation] = item
                else
                  bid_args[:company] = item
                end
                process_action(Engine::Action::Bid.new(entity, **bid_args))
              when :buy_company
                process_action(Engine::Action::BuyCompany.new(entity, company: item, price: item_price))
              when :choose
                choice_val = if available_choices.is_a?(Hash)
                               available_choices.keys.find { |k| k == item || (item.respond_to?(:id) && k == item.id) } || item.id
                             else
                               item.respond_to?(:id) ? item.id : item
                             end
                process_action(Engine::Action::Choose.new(entity, choice: choice_val))
              end
            }

            card_sym = item.respond_to?(:sym) ? item.sym : item.name
            tooltip = build_entity_tooltip(item, price: (item_price if item_price&.positive?))
            display_cost = if item_price&.positive?
                             item_price
                           else
                             (item.respond_to?(:value) ? item.value : nil)
                           end
            subtext = display_cost ? @game.format_currency(display_cost) : nil
            card_classes = ['game-card']
            card_classes.concat(%w[action-buy clickable]) if can_choose_item
            card_label = subtext ? "#{card_sym} #{subtext}" : card_sym

            item_id = item.respond_to?(:id) ? item.id : item.to_s
            wrapper_id = "draft_company_wrapper_#{item_id}"
            wrapper_classes = ['status-company-wrapper']

            item_card = render_railcard(
              card_label,
              card_classes,
              (can_choose_item ? exec_action : nil),
              tooltip,
              nil,
              wrapper_id,
              wrapper_classes,
              entity: item
            )

            choose_btn = if can_choose_item

                           btn_text = if item_price&.positive?
                                        "#{btn_verb} #{@game.format_currency(item_price)}"
                                      else
                                        btn_verb
                                      end
                           h(:button, {
                               style: {
                                 padding: '0 10px',
                                 height: '1.6rem',
                                 fontSize: '0.82rem',
                                 fontWeight: 'bold',
                                 fontFamily: FONT_MONEY,
                                 backgroundColor: action_mode == :bid && !is_draft ? '#0284c7' : '#16a34a',
                                 color: '#fff',
                                 border: 'none',
                                 borderRadius: '4px',
                                 cursor: 'pointer',
                               },
                               on: { click: exec_action },
                             }, btn_text)

                         end

            btn_cell_children = choose_btn ? [choose_btn] : []

            row_cells = [
              h(:td, { style: { padding: '6px 8px', borderBottom: '1px solid #cbd5e1', borderRight: '1px solid #e2e8f0', width: '1%', whiteSpace: 'nowrap' } }, [item_card]),
              h(:td, { style: { padding: '6px 8px', borderBottom: '1px solid #cbd5e1', borderRight: '2px solid #cbd5e1', width: '8.5rem', whiteSpace: 'nowrap' } }, btn_cell_children),
            ]

            players.each_with_index do |p, idx|
              cell_content = if is_owned && item.owner == p
                               h(:span, {
                                   style: {
                                     backgroundColor: '#16a34a',
                                     color: '#fff',
                                     padding: '2px 6px',
                                     borderRadius: '3px',
                                     fontWeight: 'bold',
                                     fontSize: '0.75rem',
                                   },
                                 }, 'OWNED')
                             else
                               bid_text = nil
                               if !is_owned && step.respond_to?(:bids) && step.bids
                                 raw_bids = step.bids[item]
                                 bids_list = raw_bids.is_a?(Array) ? raw_bids : [raw_bids].compact
                                 p_bid = bids_list.find { |b| (b.respond_to?(:entity) && b.entity == p) || (b.respond_to?(:player) && b.player == p) }
                                 bid_text = @game.format_currency(p_bid.price) if p_bid && p_bid.respond_to?(:price)
                               end

                               if bid_text
                                 h(:span, {
                                     style: {
                                       backgroundColor: '#0284c7',
                                       color: '#fff',
                                       padding: '2px 6px',
                                       borderRadius: '3px',
                                       fontWeight: 'bold',
                                       fontSize: '0.75rem',
                                       fontFamily: FONT_MONEY,
                                     },
                                   }, bid_text)
                               else
                                 h(:span, { style: { color: '#cbd5e1' } }, '-')
                               end
                             end

              player_border = idx == players.length - 1 ? 'none' : '1px solid #e2e8f0'
              row_cells << h(:td, {
                               style: {
                                 padding: '6px 8px',
                                 textAlign: 'center',
                                 borderBottom: '1px solid #cbd5e1',
                                 borderRight: player_border,
                               },
                             }, [cell_content])
            end

            row_bg = if can_choose_item
                       '#f0fdf4'
                     elsif is_owned
                       '#f8fafc'
                     else
                       'transparent'
                     end

            h(:tr, { style: { backgroundColor: row_bg, opacity: is_owned ? '0.88' : '1' } }, row_cells)
          end
          is_minimized = Lib::Storage['draft_overlay_minimized'] || false

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('draft_overlay_left');
              return (l && l !== 'undefined' && l !== 'null' && !isNaN(parseFloat(l))) ? parseFloat(l) : null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('draft_overlay_top');
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

            var modal = document.getElementById('draft-overlay-dialog');
            if (!modal) return;

            var header = document.getElementById('draft-overlay-header');
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
                  sessionStorage.setItem('draft_overlay_left', finalRect.left);
                  sessionStorage.setItem('draft_overlay_top', finalRect.top);
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
              sessionStorage.removeItem('draft_overlay_left');
              sessionStorage.removeItem('draft_overlay_top');
            } catch(e) {}
            var modal = document.getElementById('draft-overlay-dialog');
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
            Lib::Storage['draft_overlay_minimized'] = !is_minimized
            update
          end

          dialog_style = {
            width: '90%',
            maxWidth: '920px',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.1)',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            border: '1px solid #cbd5e1',
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

          header_controls = [
            (if can_pass
               h(:button, {
                   attrs: { id: 'draft-overlay-pass-btn', title: 'Pass your turn' },
                   style: {
                     padding: '0 12px',
                     height: '1.5rem',
                     fontSize: '0.78rem',
                     fontWeight: 'bold',
                     backgroundColor: '#fd7e14',
                     color: '#ffffff',
                     border: 'none',
                     borderRadius: '4px',
                     cursor: 'pointer',
                     display: 'inline-flex',
                     alignItems: 'center',
                     justifyContent: 'center',
                     boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                   },
                   on: { click: exec_pass },
                 }, 'Pass')
             end),
            h(:div, { attrs: { class: 'draft-undo-redo-wrapper' } }, [
              h(:style, {}, '
                .draft-undo-redo-wrapper #history,
                .draft-undo-redo-wrapper .history,
                .draft-undo-redo-wrapper input,
                .draft-undo-redo-wrapper button:not(#undo):not(#redo) {
                  display: none !important;
                }
                .draft-undo-redo-wrapper,
                .draft-undo-redo-wrapper * {
                  box-sizing: border-box !important;
                }
                .draft-undo-redo-wrapper,
                .draft-undo-redo-wrapper div,
                .draft-undo-redo-wrapper #history_and_undo,
                .draft-undo-redo-wrapper .history_and_undo {
                  display: inline-flex !important;
                  flex-direction: row !important;
                  flex-wrap: nowrap !important;
                  align-items: center !important;
                  justify-content: center !important;
                  gap: 0.3rem !important;
                  margin: 0 !important;
                  padding: 0 !important;
                  border: none !important;
                  background: transparent !important;
                  box-shadow: none !important;
                }
                .draft-undo-redo-wrapper button#undo,
                .draft-undo-redo-wrapper button#redo {
                  display: inline-flex !important;
                  height: 1.5rem !important;
                  min-height: 1.5rem !important;
                  max-height: 1.5rem !important;
                  padding: 0 8px !important;
                  font-size: 0.78rem !important;
                  font-weight: 600 !important;
                  background-color: #f1f5f9 !important;
                  color: #475569 !important;
                  border: 1px solid #cbd5e1 !important;
                  border-radius: 4px !important;
                  cursor: pointer !important;
                  margin: 0 !important;
                  line-height: 1 !important;
                  box-shadow: 0 1px 2px rgba(0,0,0,0.05) !important;
                }
                .draft-undo-redo-wrapper button#undo:hover:not(:disabled),
                .draft-undo-redo-wrapper button#redo:hover:not(:disabled) {
                  background-color: #e2e8f0 !important;
                  color: #1e293b !important;
                  border-color: #94a3b8 !important;
                }
                .draft-undo-redo-wrapper button#undo:disabled,
                .draft-undo-redo-wrapper button#redo:disabled {
                  background-color: #f8fafc !important;
                  color: #cbd5e1 !important;
                  border-color: #e2e8f0 !important;
                  cursor: not-allowed !important;
                  opacity: 0.6 !important;
                  box-shadow: none !important;
                }
              '),
              h(HistoryAndUndo, last_action_id: last_action_id),
            ]),
            h(:button, {
                attrs: { title: is_minimized ? 'Expand overlay' : 'Minimize overlay' },
                style: {
                  padding: '0 8px',
                  height: '1.5rem',
                  fontSize: '0.78rem',
                  fontWeight: '600',
                  backgroundColor: '#f1f5f9',
                  color: '#475569',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                },
                on: { click: toggle_minimize },
              }, is_minimized ? 'Expand' : 'Minimize'),
          ].compact

          body_content = if is_minimized
                           nil
                         else
                           h(:div, { style: { overflowY: 'auto', padding: '1rem' } }, [
                             h(:table, { style: { width: '100%', borderCollapse: 'collapse', fontSize: '0.85rem', border: '1px solid #cbd5e1' } }, [
                               h(:thead, [
                                 h(:tr, [
                                   h(:th, { attrs: { colspan: '2' }, style: { padding: '6px 8px', textAlign: 'left', borderBottom: '2px solid #cbd5e1', borderRight: '2px solid #cbd5e1', color: '#475569' } }, 'Available Cards'),
                                   *players.map.with_index do |p, idx|
                                     is_current = (p == entity)
                                     player_border = idx == players.length - 1 ? 'none' : '1px solid #cbd5e1'
                                     h(:th, {
                                         style: {
                                           padding: '6px 8px',
                                           textAlign: 'center',
                                           borderBottom: '2px solid #cbd5e1',
                                           borderRight: player_border,
                                           backgroundColor: is_current ? '#e0f2fe' : 'transparent',
                                           color: is_current ? '#0369a1' : '#475569',
                                           fontWeight: is_current ? 'bold' : '600',
                                         },
                                       }, p.name)
                                   end,
                                 ]),
                               ]),
                               h(:tbody, rows),
                               h(:tfoot, [
                                 h(:tr, [
                                   h(:td, { attrs: { colspan: '2' }, style: { padding: '8px', fontWeight: 'bold', borderTop: '2px solid #cbd5e1', borderRight: '2px solid #cbd5e1', color: '#334155' } }, 'Cash on Hand:'),
                                   *players.map.with_index do |p, idx|
                                     player_border = idx == players.length - 1 ? 'none' : '1px solid #cbd5e1'
                                     h(:td, {
                                         style: {
                                           padding: '8px',
                                           textAlign: 'center',
                                           borderTop: '2px solid #cbd5e1',
                                           borderRight: player_border,
                                           fontWeight: 'bold',
                                           fontFamily: FONT_MONEY,
                                           color: COLOR_MONEY,
                                         },
                                       }, @game.format_currency(p.cash))
                                   end,
                                 ]),
                               ]),
                             ]),
                           ])
                         end

          dialog_children = [
            h(:div, {
                attrs: { id: 'draft-overlay-header' },
                style: {
                  padding: '0.7rem 1.2rem',
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
              h(:div, [
                h(:h2, { style: { margin: '0', fontSize: '1.25rem', color: '#0f172a' } }, 'Private Distribution Draft'),
                h(:span, { style: { fontSize: '0.85rem', color: '#64748b' } }, "Active Player: #{entity.name}"),
              ]),
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, header_controls),
            ]),
          ]
          dialog_children << body_content if body_content

          container_children = [
            h(:div, {
                attrs: { id: 'draft-overlay-dialog' },
                style: dialog_style,
              }, dialog_children),
          ]
          if pending_corp
            cancel_handler = lambda {
              process_action(Engine::Action::Undo.new(entity)) if actions.include?('undo')
            }
            container_children << h(ParPromptOverlay,
                                    game: @game,
                                    step: step,
                                    entity: entity,
                                    corporation: pending_corp,
                                    on_cancel: cancel_handler)
          end

          h(:div, {
              attrs: { id: 'draft-overlay-container' },
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
            }, container_children)
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
