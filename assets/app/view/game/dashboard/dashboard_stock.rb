# frozen_string_literal: true

require 'view/game/actionable'
require 'view/game/bank'
require 'view/game/buy_sell_shares'
require 'view/game/company'
require 'view/game/corporation'
require 'view/game/par'
require 'view/game/par_chart'
require 'view/game/sell_shares'
require 'view/game/bid'
require 'view/game/ipo_rows'

module View
  module Game
    class DashboardStock < Snabberb::Component
      include Lib::Settings
      include Actionable
      needs :selected_corporation, default: nil, store: true
      needs :selected_company, default: nil, store: true
      needs :last_player, default: nil, store: true
      needs :corporation_to_par, default: nil, store: true
      needs :show_other_players, default: nil, store: true
      needs :flexible_player, default: nil, store: true
      needs :show_sr_hand, default: false, store: true

      def render
        round = @game.round
        @step = round.active_step
        entity = @step.current_entity
        @current_actions = round.actions_for(entity)

        @selected_corporation ||= @step.selected_corporation if @step.respond_to?(:selected_corporation)
        @auctioning_corporation = @step.auctioning_corporation if @step.respond_to?(:auctioning_corporation)
        @selected_corporation ||= @auctioning_corporation
        @auctioning_company = @step.auctioning_company if @step.respond_to?(:auctioning_company)
        @selected_company ||= @auctioning_company
        @mergeable_entity = @step.mergeable_entity if @step.respond_to?(:mergeable_entity)
        @price_protection = @step.price_protection if @step.respond_to?(:price_protection)
        @selected_corporation ||= @price_protection&.corporation

        @bank_first = @step.respond_to?(:bank_first?) && @step.bank_first?
        @hide_corporations = @step.respond_to?(:hide_corporations?) && @step.hide_corporations?

        @current_entity = @step.current_entity
        if @last_player != @current_entity && !@auctioning_corporation
          store(:selected_corporation, nil, skip: true)
          store(:last_player, @current_entity, skip: true)
          store(:corporation_to_par, nil, skip: true)
          store(:show_sr_hand, false, skip: true)
        end

        # Render bankruptcy at the absolute foreground level to prevent early returns from hiding it
        return h(:div, render_bankruptcy) if @current_actions.include?('bankrupt')

        if @current_actions.include?('par') && @step.respond_to?(:companies_pending_par) && !@step.companies_pending_par.empty?
          return h(:div, render_company_pending_par)
        end
        return render_select_par_slot if @corporation_to_par && @current_actions.include?('par')

        children = []

        children.concat(render_bankruptcy) if @current_actions.include?('bankrupt')
        children << h(::View::Game::Choose) if @current_actions.include?('choose') && @step.choice_available?(@current_entity)
        children << h(::View::Game::FlexibleBuy) if @current_actions.include?('buy_shares') && @flexible_player

        if @step.respond_to?(:must_sell?) && @step.must_sell?(@current_entity)
          children << if @game.num_certs(@current_entity) > @game.cert_limit(@current_entity)
                        h('div.margined', 'Must sell stock: above certificate limit')
                      elsif @step.respond_to?(:must_sell_corporations)
                        corps_over_limit = @step.must_sell_corporations(@current_entity).map(&:name).join(', ')
                        h('div.margined', "Must sell stock: above 60% limit in #{corps_over_limit}")
                      else
                        h('div.margined', 'Must sell stock: above 60% limit in corporation(s)')
                      end
        end

        if @price_protection
          num_presentation = @game.share_pool.num_presentation(@price_protection)
          children << h('div.margined',
                        "You can price protect #{num_presentation} of #{@price_protection.corporation.name} "\
                        "for #{@game.format_currency(@price_protection.price)}")
        end

        children.concat(render_buttons)
        children << render_bid if should_render_bid?
        children << h(::View::Game::SpecialBuy) if @current_actions.include?('special_buy')
        children.concat(render_failed_merge) if @current_actions.include?('failed_merge')
        children.concat(render_bank_companies) if @bank_first
        children.concat(render_corporations) unless @hide_corporations
        children.concat(render_mergeable_entities) if @current_actions.include?('merge')
        children.concat(render_player_companies) if @current_actions.include?('sell_company')
        children.concat(render_ipo_rows) if @game.show_ipo_rows?
        children.concat(render_bank_companies) unless @bank_first
        children << render_show_hand_button unless @game.hand_companies_for_stock_round.empty?
        children.concat(render_hand_companies) if show_sr_hand?

        if @step.respond_to?(:purchasable_companies) && !@step.purchasable_companies(@current_entity).empty?
          children << h(::View::Game::BuyCompanyFromOtherPlayer, game: @game)
        end

        children.compact!

        # Safely strip out any empty strings or empty arrays using inline JS
        # to avoid Opal "method missing" errors on native VNodes
        children.reject! do |c|
          `#{c} === ""` || `Array.isArray(#{c}) && #{c}.length === 0`
        end

        # If no active actions produced layout elements, return an invisible node to satisfy Snabberb
        return h(:div, { style: { display: 'none' } }) if children.empty?

        h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.4rem', width: '100%' } }, children)
      end

      def render_company_pending_par
        children = []
        company = @step.companies_pending_par.first
        @game.abilities(company, :shares).shares&.each do |share|
          next unless share.president

          children << h(::View::Game::Corporation, corporation: share.corporation)
          children << if @game.respond_to?(:par_chart) && @game.par_chart
                        h(::View::Game::ParChart, corporation_to_par: share.corporation)
                      else
                        h(::View::Game::Par, corporation: share.corporation)
                      end
        end
        children
      end

      def render_buttons
        buttons = []
        buttons.concat(render_merge_button) if @current_actions.include?('merge')
        buttons.concat(render_payoff_player_debt_button) if @current_actions.include?('payoff_player_debt')
        buttons.concat(render_payoff_player_debt_partial_button) if @current_actions.include?('payoff_player_debt_partial')
        buttons.concat(render_take_loan) if @current_actions.include?('take_loan')
        buttons.concat(render_payoff_loan) if @current_actions.include?('payoff_loan')
        buttons.any? ? [h(:div, buttons)] : []
      end

      def render_merge_button
        selected_corporation = @selected_corporation
        merge = lambda do
          if selected_corporation
            do_merge = lambda do
              to_merge = selected_corporation.corporation? ? { corporation: selected_corporation } : { minor: selected_corporation }
              process_action(Engine::Action::Merge.new(@mergeable_entity, **to_merge))
            end
            if @mergeable_entity.owner == selected_corporation.owner
              do_merge.call
            else
              check_consent(@mergeable_entity,
                            selected_corporation.owner, do_merge)
            end
          else
            store(:flash_opts, 'Select a corporation to merge with')
          end
        end
        [h(:button, { on: { click: merge } }, @step.merge_action)]
      end

      def render_bankruptcy
        resign = -> { process_action(Engine::Action::Bankrupt.new(@current_entity)) }
        [h(:div, [
          h(:button, { style: { width: 'max-content' }, on: { click: resign } }, 'Declare Bankruptcy'),
          h(:div, @step.bankruptcy_description(@current_entity)),
        ])]
      end

      def render_payoff_player_debt_button
        payoffdebt = -> { process_action(Engine::Action::PayoffPlayerDebt.new(@current_entity)) }
        partial = @current_entity.cash < @current_entity.debt
        amount = [@current_entity.cash, @current_entity.debt].min
        [h(:button, { on: { click: payoffdebt } },
           "Pay off debt#{partial ? ' (Partial)' : ''} - #{@game.format_currency(amount)}")]
      end

      def render_payoff_player_debt_partial_button
        max_payoff = [@current_entity.cash, @current_entity.debt].min
        input = h('input.no_margin', style: { height: '1.2rem', width: '4rem', padding: '0 0 0 0.2rem' },
                                     attrs: { type: 'number', min: 1, max: max_payoff, value: max_payoff })
        payoff_debt_partial = lambda do
          amount = input.JS['elm'].JS['value'].to_i
          process_action(Engine::Action::PayoffPlayerDebtPartial.new(@current_entity, amount: amount))
          Native(input)&.elm&.value = @current_entity.cash if amount > @current_entity.cash
        end
        [h(:div, [input, h(:button, { on: { click: payoff_debt_partial } }, 'Partially pay off debt')])]
      end

      def render_failed_merge
        return [] unless @step.merge_failed?

        failed_merge = lambda do
          process_action(Engine::Action::Undo.new(@game.current_entity, action_id: @step.action_id_before_merge))
          process_action(Engine::Action::FailedMerge.new(@game.current_entity, corporations: @step.merging_corporations))
        end
        text = 'The merger has failed. The President did not have a share to donate to the system. Press the Merge Failed button to continue.'
        [h(:div, text), h(:button, { on: { click: failed_merge } }, 'Merge Failed')]
      end

      def render_corporations
        merging = @step.respond_to?(:merge_in_progress?) && @step.merge_in_progress?
        corporations = @step.respond_to?(:visible_corporations) ? @step.visible_corporations : @game.sorted_corporations.reject(&:closed?)

        corporations.map do |corporation|
          next if @auctioning_corporation && @auctioning_corporation != corporation
          next if @mergeable_entity && @mergeable_entity != corporation
          next if @price_protection && @price_protection.corporation != corporation

          children = []
          children.concat(render_subsidiaries)
          input = render_input(corporation) if @game.corporation_available?(corporation)

          # Hide the corporation completely if it has no actionable inputs
          next unless input

          logo_src = begin
            setting_for(:simple_logos, @game) ? corporation.simple_logo : corporation.logo
          rescue StandardError
            nil
          end

          style = {
            width: '24px',
            height: '24px',
            borderRadius: '4px',
            boxSizing: 'border-box',
            display: 'inline-block',
            border: '1px solid #333',
            marginRight: '6px',
            verticalAlign: 'middle',
          }

          icon_el = if logo_src
                      style[:backgroundColor] = corporation.color || '#fff'
                      h(:img, { attrs: { src: logo_src }, style: style })
                    else
                      style[:lineHeight] = '22px'
                      style[:textAlign] = 'center'
                      style[:backgroundColor] = corporation.color || '#4169e1'
                      style[:color] = corporation.text_color || '#fff'
                      style[:fontSize] = '0.65rem'
                      style[:fontWeight] = 'bold'
                      h(:div, { style: style }, corporation.id.to_s[0..2])
                    end

          header_props = {
            style: {
              display: 'flex',
              alignItems: 'center',
              padding: '0.3rem 0.5rem',
              backgroundColor: @selected_corporation == corporation ? '#d1ecf1' : '#f8f9fa',
              border: @selected_corporation == corporation ? '2px solid #17a2b8' : '1px solid #cccccc',
              borderRadius: '4px',
              cursor: 'pointer',
              marginBottom: '0.2rem',
            },
            on: {
              click: lambda {
                if @selected_corporation == corporation
                  store(:selected_corporation, nil)
                else
                  store(:selected_corporation, corporation)
                end
              },
            },
          }

          # Hide the one-line logo header if it is a stock round
          unless @game.round.stock?
            children << h(:div, header_props,
                          [icon_el, h(:span, { style: { fontSize: '0.85rem', fontWeight: 'bold', color: '#000' } }, corporation.name)])
          end

          children << input if input && @selected_corporation == corporation

          # Only render the wrapper if there are actual children to show
          children.empty? ? nil : h(:div, { style: { display: 'block', width: '100%' } }, children)
        end.compact
      end

    def render_input(corporation)
        pre_ipo = corporation.ipoed ? h(::View::Game::BuySellShares, corporation: corporation) : render_pre_ipo(corporation)
        inputs = [
          pre_ipo,
          render_loan(corporation),
        ]
        inputs << h(::View::Game::IssueShares, entity: corporation) unless (@step.actions(corporation) & %w[buy_shares sell_shares]).empty?
        inputs << h(::View::Game::BuyTrains, corporation: corporation) if @step.actions(corporation).include?('buy_train')
        inputs << h(::View::Game::ScrapTrains, corporation: corporation) if @step.actions(corporation).include?('scrap_train')
        if @current_actions.include?('choose') && @step.choice_available?(corporation)
          inputs << h(::View::Game::Choose, entity: corporation)
        end

        inputs = inputs.compact
        h('div.margined_bottom', { style: { width: '100%' } }, inputs) if inputs.any?
      end

      def render_pre_ipo(corporation)
        children = []
        ipo_kind = if @step.respond_to?(:ipo_type)
                     @step.ipo_type(corporation)
                   elsif @game.respond_to?(:ipo_type)
                     @game.ipo_type(corporation)
                   elsif corporation.respond_to?(:ipo_type)
                     corporation.ipo_type
                   else
                     :par
                   end

        case ipo_kind
        when :par
          children << h(::View::Game::Par, corporation: corporation) if @current_actions.include?('par')
        when :bid
          children << h(::View::Game::Round::Bid, entity: @current_entity, biddable: corporation) if should_render_bid?
        when :form
          children << h(::View::Game::FormCorporation, corporation: corporation) if @current_actions.include?('par')
        when String
          children << h(:div, ipo_kind)
        end
        children << h(::View::Game::BuySellShares, corporation: corporation)
        children.compact!
        children.empty? ? nil : h(:div, children)
      end
      
      def render_subsidiaries
        return [] unless @current_actions.include?('assign')

        @step.available_subsidiaries.map { |company| h(Company, company: company) }
      end

      def render_loan(corporation)
        return unless @step.actions(corporation).include?('take_loan')

        take_loan = -> { process_action(Engine::Action::TakeLoan.new(corporation, loan: @game.loans[0])) }
        h(:button, { on: { click: take_loan } }, 'Take Loan')
      end

      def render_mergeable_entities
        return unless @step.current_actions.include?('merge') || @step.mergeable_entities

        children = [h(:div, { style: { margin: '0.5rem 1rem 0 0' } }, @step.mergeable_type(@mergeable_entity))]
        hidden_corps = false
        @show_other_players = true if @step.show_other_players
        @step.mergeable_entities.each do |target|
          if @show_other_players || target.owner == @mergeable_entity.owner || !target.owner
            children << h(::View::Game::Corporation, corporation: target, selected_corporation: @selected_corporation)
          else
            hidden_corps = true
          end
        end
        if hidden_corps
          children << h('button', {
                          on: {
                            click: lambda {
                              store(:show_other_players, true)
                            },
                          },
                          style: { display: 'grid', gridColumn: '1/4', width: 'max-content' },
                        }, 'Show corporations from other players')
        elsif @show_other_players
          children << h('button', {
                          on: {
                            click: lambda {
                              store(:show_other_players, false)
                            },
                          },
                          style: { display: 'grid', gridColumn: '1/4', width: 'max-content' },
                        }, 'Hide corporations from other players')
        end
        children
      end

      def render_player_companies
        @step.sellable_companies(@current_entity).map do |company|
          children = [h(::View::Game::Company, company: company)]
          if @selected_company == company
            children << h('div.margined_bottom', { style: { width: '100%' } },
                          render_sell_input(company))
          end
          h(:div, { style: { display: 'inline-block', verticalAlign: 'top' } }, children)
        end
      end

      def render_sell_input(company)
        price = @step.sell_price(company)
        buy = lambda do
          process_action(Engine::Action::SellCompany.new(@current_entity, company: company, price: price))
          store(:selected_company, nil, skip: true)
        end
        [h(:button, { on: { click: buy } }, "Sell #{@selected_company.sym} to Bank for #{@game.format_currency(price)}")]
      end

      def render_bank_companies
        @game.buyable_bank_owned_companies.map do |company|
          inputs = []
          inputs.concat(render_buy_input(company)) if @current_actions.include?('buy_company')
          inputs.concat(render_company_bid_input(company)) if should_render_bid?
          children = [h(::View::Game::Company, company: company, bids: (should_render_bid? ? @step.bids[company] : nil),
                                               interactive: !inputs.empty?)]
          if !inputs.empty? && @selected_company == company
            children << h('div.margined_bottom', { style: { width: '100%' } },
                          inputs)
          end
          h(:div, { style: { display: 'inline-block', verticalAlign: 'top' } }, children)
        end
      end

      def render_buy_input(company)
        return [] unless @step.can_buy_company?(@current_entity, company)
        return render_buy_input_interval(company) if company.interval

        buy = lambda do
          process_action(Engine::Action::BuyCompany.new(@current_entity, company: company, price: company.value))
          store(:selected_company, nil, skip: true)
        end
        [h(:button, { on: { click: buy } }, "Buy #{company.sym} from Bank for #{@game.format_currency(company.value)}")]
      end

      def render_buy_input_interval(company)
        prices = company.interval.sort
        buy_buttons = prices.map do |price|
          buy = -> { process_action(Engine::Action::BuyCompany.new(@current_entity, company: company, price: price)) }
          h('button.small.buy_company', { style: { width: 'calc(17.5rem/6)', padding: '0.2rem' }, on: { click: buy } },
            @game.format_currency(price).to_s)
        end
        [h(:div,
           [h("div#{buy_buttons.size < 5 ? '.inline' : ''}", { style: { marginTop: '0.5rem' } }, "Buy #{company.sym}: "),
            *buy_buttons])]
      end

      def render_company_bid_input(company)
        return [] if !@step.respond_to?(:can_bid_company?) || !@step.can_bid_company?(@current_entity, company)

        [h(::View::Game::Round::Bid, entity: @current_entity, biddable: company)]
      end

      def render_hand_companies
        @game.hand_companies_for_stock_round.map do |company|
          inputs = @current_actions.include?('buy_company') ? render_buy_input(company) : []
          children = [h(::View::Game::Company, company: company, interactive: !inputs.empty?)]
          if !inputs.empty? && @selected_company == company
            children << h('div.margined_bottom', { style: { width: '100%' } },
                          inputs)
          end
          h(:div, { style: { display: 'inline-block', verticalAlign: 'top' } }, children)
        end
      end

      def render_show_hand_button
        return nil unless @current_entity.player?

        user_name = @user&.dig('name')
        can_show_hand = hotseat? || (@user&.dig('name') == @current_entity.name) || (!hotseat? && user_name && @game.players.map(&:name).include?(user_name) && Lib::Storage[@game.id]&.dig('master_mode'))
        toggle = lambda do
          if can_show_hand
            store(:show_sr_hand,
                  !@show_sr_hand)
          else
            store(:flash_opts, 'Enter master mode to reveal hand. Use this feature fairly.')
          end
        end
        h(:button, { style: { display: 'block', width: '8.5rem', padding: '0.2rem', margin: '0.4rem' }, on: { click: toggle } },
          "#{show_sr_hand? ? 'Hide' : 'Show'} Player Hand")
      end

      def show_sr_hand?
        @show_sr_hand
      end

      def render_ipo_rows
        [h(:div, { style: { display: 'inline-block' } }, h(::View::Game::IpoRows, game: @game, show_first: true))]
      end

      def render_take_loan
        take_loan = -> { process_action(Engine::Action::TakeLoan.new(@current_entity, loan: nil)) }
        [h(:button, { on: { click: take_loan } }, "Take Loan (#{@game.format_currency(@game.loan_amount)})")]
      end

      def render_payoff_loan
        payoff_loan = -> { process_action(Engine::Action::PayoffLoan.new(@current_entity, loan: nil)) }
        [h(:button, { on: { click: payoff_loan } }, "Payoff Loan (#{@game.format_currency(@game.loan_amount)})")]
      end

      def render_bid
        children = if @step.respond_to?(:can_bid?) && @step.can_bid?(@current_entity)
                     [h(::View::Game::Round::Bid, entity: @current_entity,
                                                  biddable: @step.bid_entity)]
                   else
                     []
                   end
        h(:div, children)
      end

      def should_render_bid?
        @current_actions.include?('bid') || @step.auctioneer?
      end
    end
  end
end
