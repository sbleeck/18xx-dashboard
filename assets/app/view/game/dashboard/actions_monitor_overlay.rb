# frozen_string_literal: true

# backtick_javascript: true

require 'view/game/actionable'
require 'lib/settings'
require 'lib/storage'

module View
  module Game
    module Dashboard
      class ActionsMonitorOverlay < Snabberb::Component
        include Actionable
        include Lib::Settings

        FONT_MONEY = '"Courier New", Courier, monospace'

        needs :game, store: true
        needs :show_actions_monitor, store: true, default: false

        def current_entity
          @game.round.active_step&.current_entity ||
            (@game.round.respond_to?(:current_entity) ? @game.round.current_entity : nil) ||
            @game.current_entity
        rescue StandardError
          nil
        end

        def active_player
          ent = current_entity
          return nil unless ent

          if ent.respond_to?(:player?) && ent.player?
            ent
          elsif ent.respond_to?(:player) && ent.player
            ent.player
          elsif ent.respond_to?(:owner) && ent.owner.respond_to?(:player?) && ent.owner.player?
            ent.owner
          end
        end

        def actions_for(entity)
          return [] unless entity && @game.round.respond_to?(:actions_for)

          @game.round.actions_for(entity) || []
        rescue StandardError
          []
        end

        def safe_process_action(action_instance)
          process_action(action_instance)
        rescue StandardError => e
          store(:flash_opts, { message: "Action failed: #{e.message}" }, skip: false)
        end

        def build_action_row(label, bg_color, ent_name, act_type, details, idx, &callback)
          h(:tr, {
              style: {
                borderBottom: '1px solid #e2e8f0',
                backgroundColor: idx.even? ? '#ffffff' : '#f8fafc',
              },
            }, [
            h(:td, { style: { padding: '5px 8px', whiteSpace: 'nowrap', width: '1%' } }, [
              h(:button, {
                  style: {
                    padding: '4px 10px',
                    fontSize: '0.8rem',
                    fontWeight: 'bold',
                    fontFamily: FONT_MONEY,
                    backgroundColor: bg_color,
                    color: '#ffffff',
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '4px',
                    lineHeight: '1.2',
                  },
                  on: { click: callback },
                }, "#{label} ⚡"),
            ]),
            h(:td,
              { style: { padding: '5px 8px', whiteSpace: 'nowrap', width: '1%', fontWeight: 'bold', fontSize: '0.82rem', color: '#0f172a' } }, ent_name.to_s),
            h(:td,
              { style: { padding: '5px 8px', whiteSpace: 'nowrap', width: '1%', fontSize: '0.78rem', color: '#64748b', fontFamily: 'monospace' } }, act_type.to_s),
            h(:td, { style: { padding: '5px 8px', fontSize: '0.82rem', color: '#334155' } }, details.to_s),
          ])
        end

        def collect_action_rows(step, entity, player)
          rows = []
          entities = [entity, player, *(@game.respond_to?(:corporations) ? @game.corporations : [])].compact.uniq

          entities.each do |ent|
            legal_acts = actions_for(ent)
            next if legal_acts.empty?

            legal_acts.each do |act|
              # Suppress system and meta bot hooks
              next if /^program_/.match?(act)
              next if %w[end_game log message].include?(act)

              case act
              when 'pass'
                is_active = (step&.current_entity == ent) ||
                            (step.respond_to?(:active_entities) && step.active_entities&.include?(ent)) ||
                            (ent == player)
                next unless is_active

                rows << {
                  label: "Pass Turn (#{ent.name})",
                  color: '#ea580c',
                  ent: ent,
                  act: 'pass',
                  info: "Pass turn / skip current phase for #{ent.name}",
                  callback: -> { safe_process_action(Engine::Action::Pass.new(ent)) },
                }
              when 'undo'
                rows << {
                  label: 'Undo Action',
                  color: '#475569',
                  ent: ent,
                  act: 'undo',
                  info: 'Revert last action in game log',
                  callback: lambda {
                    Native(`document.getElementById('undo')`)&.click() || safe_process_action(Engine::Action::Undo.new(ent))
                  },
                }
              when 'redo'
                rows << {
                  label: 'Redo Action',
                  color: '#475569',
                  ent: ent,
                  act: 'redo',
                  info: 'Redo next action in game history',
                  callback: lambda {
                    Native(`document.getElementById('redo')`)&.click() || safe_process_action(Engine::Action::Redo.new(ent))
                  },
                }
              when 'run_routes'
                routes = store['routes'] || []
                storage_key = "rev_override_#{ent.id}"
                rev = Lib::Storage[storage_key] ? Lib::Storage[storage_key].to_i : 0
                if rev.zero?
                  routes.each do |r|
                    rev += r.revenue if r.respond_to?(:chains) && r.chains&.any?
                  rescue StandardError
                  end
                end
                formatted_rev = @game.format_currency(rev)
                extra_rev = @game.respond_to?(:extra_revenue) ? @game.extra_revenue(ent, routes) : 0

                rows << {
                  label: "Submit Routes (#{formatted_rev})",
                  color: '#16a34a',
                  ent: ent,
                  act: 'run_routes',
                  info: "Submit active routes (Revenue: #{formatted_rev}, Assigned: #{routes.size})",
                  callback: lambda {
                              safe_process_action(Engine::Action::RunRoutes.new(ent, routes: routes, extra_revenue: extra_rev))
                            },
                }
                rows << {
                  label: 'Run 0 Routes ($0)',
                  color: '#ea580c',
                  ent: ent,
                  act: 'run_routes',
                  info: 'Force-submit 0 network routes with $0 revenue',
                  callback: -> { safe_process_action(Engine::Action::RunRoutes.new(ent, routes: [])) },
                }
              when 'dividend', 'payout', 'withhold', 'half', 'split'
                rev = 0
                if ent.respond_to?(:operating_history) && ent.operating_history
                  hist = ent.operating_history
                  rev = hist[hist.keys.max]&.revenue.to_i if hist.keys.any?
                end
                storage_key = "rev_override_#{ent.id}"
                rev = Lib::Storage[storage_key].to_i if Lib::Storage[storage_key]
                formatted_rev = @game.format_currency(rev)

                rows << {
                  label: "Pay Out (#{formatted_rev})",
                  color: '#16a34a',
                  ent: ent,
                  act: 'dividend',
                  info: "Pay out full dividend of #{formatted_rev} to shareholders",
                  callback: -> { safe_process_action(Engine::Action::Dividend.new(ent, kind: 'payout')) },
                }
                rows << {
                  label: "Withhold (#{formatted_rev})",
                  color: '#0284c7',
                  ent: ent,
                  act: 'dividend',
                  info: "Withhold #{formatted_rev} into #{ent.name} corporate treasury",
                  callback: -> { safe_process_action(Engine::Action::Dividend.new(ent, kind: 'withhold')) },
                }
                half_kind = step.respond_to?(:dividend_types) && step.dividend_types.include?(:split) ? 'split' : 'half'
                rows << {
                  label: "Split / Half (#{formatted_rev})",
                  color: '#7c3aed',
                  ent: ent,
                  act: 'dividend',
                  info: "Split #{formatted_rev} between treasury and shareholders",
                  callback: -> { safe_process_action(Engine::Action::Dividend.new(ent, kind: half_kind)) },
                }
              when 'issue_shares', 'reissue_shares', 'reissue', 'corporate_sell_shares'
                bundles = []
                if step.respond_to?(:issuable_shares)
                  begin; bundles = step.issuable_shares(ent); rescue StandardError; end
                elsif step.respond_to?(:issuable_bundles)
                  begin; bundles = step.issuable_bundles(ent); rescue StandardError; end
                end
                bundles ||= []

                if step.respond_to?(:can_sell?)
                  bundles = bundles.select do |b|
                    step.can_sell?(ent, b); rescue StandardError; false
                  end
                end

                bundles.each do |raw_b|
                  b = raw_b.respond_to?(:to_bundle) && !raw_b.respond_to?(:num_shares) ? raw_b.to_bundle : raw_b
                  num = b.respond_to?(:num_shares) ? b.num_shares : 1
                  pct = b.respond_to?(:percent) ? b.percent : num * 10
                  price = b.respond_to?(:price) ? b.price : (ent.share_price&.price.to_i * num)
                  act_class = legal_acts.include?('reissue_shares') ? Engine::Action::ReissueShares : Engine::Action::IssueShares

                  rows << {
                    label: "Issue #{pct}% (#{@game.format_currency(price)})",
                    color: '#0284c7',
                    ent: ent,
                    act: 'issue_shares',
                    info: "Issue #{num} share(s) (#{pct}%) of #{ent.name} to market pool for #{@game.format_currency(price)}",
                    callback: -> { safe_process_action(act_class.new(ent, bundle: b)) },
                  }
                end
              when 'redeem', 'redeem_shares'
                bundles = []
                if step.respond_to?(:redeemable_shares)
                  begin; bundles = step.redeemable_shares(ent); rescue StandardError; end
                elsif step.respond_to?(:redeemable_bundles)
                  begin; bundles = step.redeemable_bundles(ent); rescue StandardError; end
                end
                bundles ||= []
                if bundles.empty? && @game.respond_to?(:share_pool)
                  pool_shares = @game.share_pool.shares_by_corporation[ent] || []
                  bundles = pool_shares.map(&:to_bundle).select do |b|
                    (ent.cash >= b.price) && (step.respond_to?(:can_buy?) ? step.can_buy?(ent, b) : true)
                  end
                end

                bundles.each do |raw_b|
                  b = raw_b.respond_to?(:to_bundle) && !raw_b.respond_to?(:num_shares) ? raw_b.to_bundle : raw_b
                  num = b.respond_to?(:num_shares) ? b.num_shares : 1
                  pct = b.respond_to?(:percent) ? b.percent : num * 10
                  price = b.respond_to?(:price) ? b.price : (ent.share_price&.price.to_i * num)
                  src = b.respond_to?(:owner) && b.owner ? b.owner.name : 'Pool'
                  next if ent.cash < price

                  act_class = if legal_acts.include?('redeem_shares') && defined?(Engine::Action::RedeemShares)
                                Engine::Action::RedeemShares
                              else
                                (defined?(Engine::Action::Redeem) ? Engine::Action::Redeem : Engine::Action::BuyShares)
                              end

                  rows << {
                    label: "Redeem #{pct}% (#{@game.format_currency(price)})",
                    color: '#16a34a',
                    ent: ent,
                    act: 'redeem_shares',
                    info: "Redeem #{num} share(s) (#{pct}%) from #{src} into #{ent.name} treasury for #{@game.format_currency(price)}",
                    callback: -> { safe_process_action(act_class.new(ent, bundle: b)) },
                  }
                end
              when 'buy_shares', 'corporate_buy_shares'
                if ent.respond_to?(:corporation?) && ent.corporation?
                  # Corporation redeeming shares into its own treasury
                  redeemable = []
                  if step.respond_to?(:redeemable_shares)
                    begin; redeemable = step.redeemable_shares(ent) || []; rescue StandardError; end
                  end
                  if redeemable.empty? && step.respond_to?(:buyable_shares)
                    begin
                      redeemable = (step.buyable_shares(ent) || []).select do |s|
                        (s.respond_to?(:corporation) ? s.corporation : s.first&.corporation) == ent
                      end
                    rescue StandardError
                    end
                  end
                  if redeemable.empty? && @game.respond_to?(:share_pool)
                    pool_shares = @game.share_pool.shares_by_corporation[ent] || []
                    redeemable = pool_shares.map(&:to_bundle)
                  end

                  redeemable.each do |raw_b|
                    b = raw_b.respond_to?(:to_bundle) && !raw_b.respond_to?(:num_shares) ? raw_b.to_bundle : raw_b
                    num = b.respond_to?(:num_shares) ? b.num_shares : 1
                    pct = b.respond_to?(:percent) ? b.percent : num * 10
                    price = b.respond_to?(:price) ? b.price : (ent.share_price&.price.to_i * num)
                    next if (ent.respond_to?(:cash) ? ent.cash : 0) < price

                    next if step.respond_to?(:can_buy?) && !(begin; step.can_buy?(ent, b); rescue StandardError; true; end)

                    act_class = legal_acts.include?('corporate_buy_shares') ? Engine::Action::CorporateBuyShares : Engine::Action::BuyShares
                    share_arg = b.respond_to?(:shares) ? b.shares : [b]

                    rows << {
                      label: "Redeem #{pct}% #{ent.name} (#{@game.format_currency(price)})",
                      color: '#16a34a',
                      ent: ent,
                      act: 'buy_shares',
                      info: "Redeem #{num} share(s) (#{pct}%) of #{ent.name} into corporate treasury for #{@game.format_currency(price)} (Cash: #{@game.format_currency(ent.cash)})",
                      callback: lambda {
                        if act_class == Engine::Action::CorporateBuyShares
                          safe_process_action(act_class.new(ent, shares: share_arg, share_price: b.share_price, percent: pct))
                        else
                          safe_process_action(act_class.new(ent, shares: share_arg.first || b))
                        end
                      },
                    }
                  end
                else
                  # Player buying shares
                  corps = @game.respond_to?(:corporations) ? @game.corporations : []
                  corps.each do |c|
                    ipo_share = c.shares.find { |s| !s.president }
                    if ipo_share && (price = c.par_price&.price || c.share_price&.price)
                      bundle = ipo_share.to_bundle
                      can_buy = (ent.cash >= price)
                      if can_buy && step.respond_to?(:can_buy?)
                        can_buy = (begin; step.can_buy?(ent, bundle); rescue StandardError; false; end)
                      end

                      if can_buy
                        rows << {
                          label: "Buy 10% #{c.name} IPO (#{@game.format_currency(price)})",
                          color: '#16a34a',
                          ent: ent,
                          act: 'buy_shares',
                          info: "Buy 10% IPO share of #{c.name} at par price #{@game.format_currency(price)}",
                          callback: -> { safe_process_action(Engine::Action::BuyShares.new(ent, shares: ipo_share)) },
                        }
                      end
                    end

                    next unless @game.respond_to?(:share_pool)

                    pool_share = @game.share_pool.shares_by_corporation[c]&.first
                    next unless pool_share && (price = c.share_price&.price)

                    bundle = pool_share.to_bundle
                    can_buy = (ent.cash >= price)
                    if can_buy && step.respond_to?(:can_buy?)
                      can_buy = (begin; step.can_buy?(ent, bundle); rescue StandardError; false; end)
                    end

                    next unless can_buy

                    rows << {
                      label: "Buy 10% #{c.name} Pool (#{@game.format_currency(price)})",
                      color: '#16a34a',
                      ent: ent,
                      act: 'buy_shares',
                      info: "Buy 10% market pool share of #{c.name} at #{@game.format_currency(price)}",
                      callback: -> { safe_process_action(Engine::Action::BuyShares.new(ent, shares: pool_share)) },
                    }
                  end
                end

              when 'sell_shares'
                corporations =
                  @game.respond_to?(:corporations) ? @game.corporations : []

                corporations.each do |corporation|
                  sellable_bundles =
                    if step.respond_to?(:sellable_bundles)
                      begin
                        step.sellable_bundles(ent, corporation) || []
                      rescue StandardError
                        []
                      end
                    elsif @game.respond_to?(:sellable_bundles)
                      begin
                        @game.sellable_bundles(ent, corporation) || []
                      rescue StandardError
                        []
                      end
                    elsif step.respond_to?(:bundles_for_corporation)
                      begin
                        step.bundles_for_corporation(ent, corporation) || []
                      rescue StandardError
                        []
                      end
                    else
                      []
                    end

                  sellable_bundles.each do |bundle|
                    next if step.respond_to?(:can_sell?) &&
                            !(begin
                              step.can_sell?(ent, bundle)
                            rescue StandardError
                              false
                            end)

                    percent = bundle.respond_to?(:percent) ? bundle.percent : 0
                    price = bundle.respond_to?(:price) ? bundle.price : 0
                    price_str = @game.format_currency(price)

                    rows << {
                      label: "Sell #{percent}% #{corporation.name} (#{price_str})",
                      color: '#dc2626',
                      ent: ent,
                      act: 'sell_shares',
                      info: "Sell #{percent}% of #{corporation.name} to the market pool for #{price_str}",
                      callback: lambda {
                        safe_process_action(
                          Engine::Action::SellShares.new(
                            ent,
                            shares: bundle.shares,
                            share_price: bundle.share_price,
                            percent: bundle.percent,
                          )
                        )
                      },
                    }
                  end
                end

              when 'buy_company'
                buyable_companies = []
                if step.respond_to?(:buyable_companies)
                  begin; buyable_companies = step.buyable_companies(ent) || []; rescue StandardError; end
                elsif @game.respond_to?(:purchasable_companies)
                  begin; buyable_companies = @game.purchasable_companies(ent) || []; rescue StandardError; end
                end

                buyable_companies.each do |comp|
                  min_p = step.respond_to?(:min_price) ? step.min_price(comp) : (comp.min_price || 1)
                  max_p = step.respond_to?(:max_price) ? step.max_price(ent, comp) : (comp.max_price || ent.cash)
                  can_afford = ent.cash >= min_p
                  next unless can_afford

                  price = [comp.value, max_p].min
                  price = [price, min_p].max

                  rows << {
                    label: "Buy #{comp.sym || comp.name} (#{@game.format_currency(price)})",
                    color: '#0284c7',
                    ent: ent,
                    act: 'buy_company',
                    info: "Buy #{comp.name} from #{comp.owner&.name || 'Bank'} for #{@game.format_currency(price)}",
                    callback: -> { safe_process_action(Engine::Action::BuyCompany.new(ent, company: comp, price: price)) },
                  }
                end
              when 'buy_train'
                trains = []
                begin; trains = step.buyable_trains(ent); rescue StandardError; end if step.respond_to?(:buyable_trains)
                trains ||= []
                trains = @game.depot.upcoming if trains.empty? && @game.respond_to?(:depot)

                trains.uniq { |t| [t.owner&.name, t.name] }.each do |train|
                  src_name = train.owner == @game.depot ? 'Depot' : (train.owner&.name || 'Bank')
                  price = train.price
                  rows << {
                    label: "Buy #{train.name} from #{src_name} (#{@game.format_currency(price)})",
                    color: '#2563eb',
                    ent: ent,
                    act: 'buy_train',
                    info: "Buy #{train.name} from #{src_name} for #{@game.format_currency(price)} (Cash: #{@game.format_currency(ent.cash)})",
                    callback: -> { safe_process_action(Engine::Action::BuyTrain.new(ent, train: train, price: price)) },
                  }
                end
              when 'par'
                pending_corp = nil
                if step.respond_to?(:corporation_pending_par) && step.corporation_pending_par
                  pending_corp = step.corporation_pending_par
                elsif step.respond_to?(:corporation) && step.corporation
                  pending_corp = step.corporation
                end

                target_corps = if pending_corp
                                 [pending_corp]
                               else
                                 (@game.respond_to?(:corporations) ? @game.corporations.reject(&:ipoed) : [])
                               end

                target_corps.each do |c|
                  prices = if step.respond_to?(:get_par_prices)
                             begin; step.get_par_prices(ent, c); rescue StandardError; nil; end
                           elsif step.respond_to?(:par_prices)
                             begin; step.par_prices(ent, c); rescue StandardError; nil; end
                           end
                  prices ||= (@game.respond_to?(:par_prices) ? @game.par_prices(c) : @game.stock_market.par_prices)
                  prices ||= []

                  prices.each do |p_node|
                    p_obj = p_node.is_a?(Array) ? p_node.first : p_node
                    price_val = p_obj.respond_to?(:price) ? p_obj.price : p_obj
                    multiplier = c.respond_to?(:shares) && c.shares.first&.president ? (c.shares.first.num_shares || 2) : 2
                    cost = price_val * multiplier
                    can_afford = (ent.respond_to?(:cash) ? ent.cash : 0) >= cost

                    can_par = if step.respond_to?(:can_par?)
                                begin; step.can_par?(c, ent); rescue StandardError; can_afford; end
                              else
                                can_afford
                              end

                    next unless can_par && can_afford

                    rows << {
                      label: "Par #{c.name} @ #{@game.format_currency(price_val)}",
                      color: '#0d9488',
                      ent: ent,
                      act: 'par',
                      info: "Par #{c.name} at #{@game.format_currency(price_val)} (Presidency cost: #{@game.format_currency(cost)})",
                      callback: lambda {
                        safe_process_action(Engine::Action::Par.new(ent, corporation: c, share_price: p_obj))
                      },
                    }
                  end
                end
              when 'choose'
                choices = nil
                if step.respond_to?(:choices_for)
                  begin; choices = step.choices_for(ent); rescue StandardError; end
                elsif step.respond_to?(:choices)
                  begin; choices = step.choices(ent); rescue StandardError; end
                end
                if choices.is_a?(Hash)
                  choices.each do |k, v|
                    rows << {
                      label: "Choose: #{v}",
                      color: '#4f46e5',
                      ent: ent,
                      act: 'choose',
                      info: "Submit choice selection '#{v}' (key: #{k})",
                      callback: -> { safe_process_action(Engine::Action::Choose.new(ent, choice: k)) },
                    }
                  end
                elsif choices.is_a?(Array)
                  choices.each do |v|
                    rows << {
                      label: "Choose: #{v}",
                      color: '#4f46e5',
                      ent: ent,
                      act: 'choose',
                      info: "Submit choice value '#{v}'",
                      callback: -> { safe_process_action(Engine::Action::Choose.new(ent, choice: v)) },
                    }
                  end
                end
              when 'discard_train', 'scrap_train'
                if ent.respond_to?(:trains) && ent.trains.any?
                  ent.trains.each do |train|
                    rows << {
                      label: "Discard #{train.name}",
                      color: '#dc2626',
                      ent: ent,
                      act: act,
                      info: "Remove train #{train.name} from #{ent.name}",
                      callback: -> { safe_process_action(Engine::Action::DiscardTrain.new(ent, train: train)) },
                    }
                  end
                end
              when 'assign'
                assignable = []
                if step.respond_to?(:companies)
                  begin; assignable = step.companies(ent) || []; rescue StandardError; end
                elsif step.respond_to?(:assignable_companies)
                  begin; assignable = step.assignable_companies(ent) || []; rescue StandardError; end
                end
                if assignable.empty? && ent.respond_to?(:companies)
                  assignable = ent.companies.reject { |c| c.respond_to?(:closed?) && c.closed? }
                end

                assignable.each do |comp|
                  val_str = comp.respond_to?(:value) ? @game.format_currency(comp.value) : ''
                  rows << {
                    label: "Assign #{comp.sym || comp.name} (#{val_str})",
                    color: '#0d9488',
                    ent: ent,
                    act: 'assign',
                    info: "Assign #{comp.name} (Value: #{val_str}) towards company formation",
                    callback: -> { safe_process_action(Engine::Action::Assign.new(ent, target: comp)) },
                  }
                end
              when 'bid'
                target = nil
                %i[target auctioning corporation target_corporation acquired_corp offered_corporation].each do |m|
                  next unless step.respond_to?(m)

                  val = begin; step.send(m); rescue StandardError; nil; end
                  if val && (val.is_a?(Engine::Corporation) || (val.respond_to?(:corporation?) && val.corporation?))
                    target = val
                    break
                  end
                end

                if target
                  min_b = if step.respond_to?(:min_bid)
                            begin; step.min_bid(target); rescue ArgumentError; step.min_bid; rescue StandardError; 10; end
                          else
                            10
                          end
                  price_str = @game.format_currency(min_b)

                  is_corp_ent = ent.respond_to?(:corporation?) && ent.corporation? && ent != target

                  callback = if is_corp_ent
                               lambda {
                                 safe_process_action(Engine::Action::Bid.new(active_player || ent.owner, corporation: ent,
                                                                                                         price: min_b))
                               }
                             else
                               -> { safe_process_action(Engine::Action::Bid.new(ent, corporation: target, price: min_b)) }
                             end

                  rows << {
                    label: "Bid #{price_str} for #{target.name}",
                    color: '#16a34a',
                    ent: ent,
                    act: 'bid',
                    info: "Place minimum bid of #{price_str} to acquire #{target.name}",
                    callback: callback,
                  }
                end
                has_row = rows.any? { |r| r[:act] == act && r[:ent] == ent }
                unless has_row
                  class_name = act.split('_').map(&:capitalize).join
                  rows << {
                    label: "Execute #{act}",
                    color: '#2563eb',
                    ent: ent,
                    act: act,
                    info: "Hardcore engine invocation: Engine::Action::#{class_name}",
                    callback: lambda {
                      if Engine::Action.const_defined?(class_name)
                        klass = Engine::Action.const_get(class_name)
                        safe_process_action(klass.new(ent))
                      else
                        store(:flash_opts, { message: "Unknown action class: Engine::Action::#{class_name}" }, skip: false)
                      end
                    },
                  }
                end
              end
            end
          end
          rows
        end

        def render
          step = @game.round.active_step
          entity = current_entity
          player = active_player

          is_minimized = Lib::Storage['actions_monitor_overlay_minimized'] == true || Lib::Storage['actions_monitor_overlay_minimized'] == 'true'

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('actions_monitor_overlay_left');
              var parsed = parseFloat(l);
              if (l && l !== 'undefined' && l !== 'null' && !isNaN(parsed) && parsed >= 10 && parsed < (window.innerWidth - 100)) return parsed;
              return null;
            } catch(e) { return null; }
          })())
          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('actions_monitor_overlay_top');
              var parsed = parseFloat(t);
              if (t && t !== 'undefined' && t !== 'null' && !isNaN(parsed) && parsed >= 0 && parsed < (window.innerHeight - 80)) return parsed;
              return null;
            } catch(e) { return null; }
          })())

          on_header_mousedown = lambda do |event|
            %x(
            var ev = #{event} || window.event;
            if (!ev) return;
            var target = ev.target || ev.srcElement;
            if (target && (target.tagName === 'BUTTON' || (target.closest && target.closest('button')))) return;
            if (ev.preventDefault) ev.preventDefault();

            var modal = document.getElementById('actions-monitor-dialog');
            if (!modal) return;
            var rect = modal.getBoundingClientRect();
            var shiftX = ev.clientX - rect.left;
            var shiftY = ev.clientY - rect.top;

            modal.style.position = 'fixed';
            modal.style.left = rect.left + 'px';
            modal.style.top = rect.top + 'px';
            modal.style.margin = '0';
            modal.style.transform = 'none';

            function onMouseMove(mEv) {
              if (mEv.preventDefault) mEv.preventDefault();
              var newLeft = Math.max(10, Math.min(mEv.clientX - shiftX, window.innerWidth - 80));
              var newTop = Math.max(0, Math.min(mEv.clientY - shiftY, window.innerHeight - 50));
              modal.style.left = newLeft + 'px';
              modal.style.top = newTop + 'px';
            }

            function onMouseUp() {
              document.removeEventListener('mousemove', onMouseMove, true);
              document.removeEventListener('mouseup', onMouseUp, true);
              var finalRect = modal.getBoundingClientRect();
              if (finalRect && !isNaN(finalRect.left) && !isNaN(finalRect.top)) {
                try {
                  sessionStorage.setItem('actions_monitor_overlay_left', finalRect.left);
                  sessionStorage.setItem('actions_monitor_overlay_top', finalRect.top);
                } catch(err) {}
              }
            }
            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('mouseup', onMouseUp, true);
            )
          end

          reset_pos = lambda do
            %x(
            try {
              sessionStorage.removeItem('actions_monitor_overlay_left');
              sessionStorage.removeItem('actions_monitor_overlay_top');
            } catch(e) {}
            var modal = document.getElementById('actions-monitor-dialog');
            if (modal) {
              modal.style.left = '50%';
              modal.style.top = '45%';
              modal.style.transform = 'translate(-50%, -50%)';
              modal.style.margin = '0';
            }
            )
            update
          end

          dialog_style = {
            width: '840px',
            maxWidth: '96vw',
            backgroundColor: '#ffffff',
            borderRadius: '8px',
            boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            border: '2px solid #0f172a',
            pointerEvents: 'auto',
            zIndex: '2000001',
            position: 'fixed',
            margin: '0',
          }

          if saved_left && saved_top
            dialog_style[:left] = "#{saved_left}px"
            dialog_style[:top] = "#{saved_top}px"
            dialog_style[:transform] = 'none'
          else
            dialog_style[:left] = '50%'
            dialog_style[:top] = '45%'
            dialog_style[:transform] = 'translate(-50%, -50%)'
          end

          dialog_style[:maxHeight] = is_minimized ? 'auto' : '85vh'

          close_overlay = lambda {
            store(:show_actions_monitor, false)
            Lib::Storage['cmd_actions_monitor'] = false
            update
          }

          toggle_min = lambda {
            new_min = !is_minimized
            Lib::Storage['actions_monitor_overlay_minimized'] = new_min
            update
          }

          header_controls = [
            h(:button, {
                style: {
                  height: '1.4rem',
                  padding: '0 6px',
                  fontSize: '0.75rem',
                  fontWeight: 'bold',
                  backgroundColor: '#334155',
                  color: '#fff',
                  border: '1px solid #475569',
                  borderRadius: '4px',
                  cursor: 'pointer',
                },
                on: { click: toggle_min },
              }, is_minimized ? 'Expand' : 'Minimize'),
            h(:button, {
                style: {
                  background: 'transparent',
                  border: 'none',
                  color: '#cbd5e1',
                  fontSize: '1.1rem',
                  fontWeight: 'bold',
                  cursor: 'pointer',
                  padding: '0 6px',
                },
                on: { click: close_overlay },
              }, '✕'),
          ]

          step_name = (step.respond_to?(:description) && step.description) || step&.class&.name&.split('::')&.last || 'None'
          round_name = @game.round.class.name.split('::').last

          header = h(:div, {
                       attrs: { id: 'actions-monitor-header' },
                       style: {
                         padding: '0.6rem 0.9rem',
                         backgroundColor: '#0f172a',
                         color: '#fff',
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
            h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem' } }, [
              h(:span, { style: { fontWeight: 'bold', fontSize: '0.95rem' } }, 'Engine Actions Monitor (Debug)'),
              h(:span, { style: { fontSize: '0.75rem', color: '#94a3b8' } }, "(Round: #{round_name} | Step: #{step_name})"),
            ]),
            h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.4rem' } }, header_controls),
          ])

          body = if is_minimized
                   nil
                 else
                   action_data = collect_action_rows(step, entity, player)

                   table_rows = action_data.map.with_index do |data, idx|
                     build_action_row(data[:label], data[:color], data[:ent].name, data[:act], data[:info], idx, &data[:callback])
                   end

                   content_child = if table_rows.empty?
                                     h(:div, { style: { padding: '1rem', color: '#94a3b8', fontStyle: 'italic', fontSize: '0.88rem' } },
                                       'No actions currently reported by Engine::Round#actions_for')
                                   else
                                     h(:table, { style: { width: '100%', borderCollapse: 'collapse', fontSize: '0.82rem' } }, [
                                       h(:thead, [
                                         h(:tr, { style: { backgroundColor: '#f1f5f9', borderBottom: '2px solid #cbd5e1' } }, [
                                           h(:th,
                                             { style: { padding: '6px 8px', textAlign: 'left', width: '1%', whiteSpace: 'nowrap' } }, 'Action'),
                                           h(:th,
                                             { style: { padding: '6px 8px', textAlign: 'left', width: '1%', whiteSpace: 'nowrap' } }, 'Entity'),
                                           h(:th,
                                             { style: { padding: '6px 8px', textAlign: 'left', width: '1%', whiteSpace: 'nowrap' } }, 'Type'),
                                           h(:th, { style: { padding: '6px 8px', textAlign: 'left' } },
                                             'Helpful Information / Details'),
                                         ]),
                                       ]),
                                       h(:tbody, {}, table_rows),
                                     ])
                                   end

                   h(:div, { style: { padding: '0.75rem', maxHeight: '75vh', overflowY: 'auto' } }, [
                     h(:div, { style: { fontSize: '0.8rem', color: '#64748b', marginBottom: '0.5rem', display: 'flex', justifyContent: 'space-between' } }, [
                       h(:span, "Active Step: #{step_name}"),
                       h(:span, "Showing #{action_data.size} actionable button(s)"),
                     ]),
                     content_child,
                   ])
                 end

          h(:div, {
              attrs: { id: 'actions-monitor-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'none',
                zIndex: '2000000',
              },
            }, [
            h(:div, { attrs: { id: 'actions-monitor-dialog' }, style: dialog_style }, [header, body].compact),
          ])
        end
      end
    end
  end
end
