# frozen_string_literal: true

module Lib
  module CardAnimation
    def self.check_and_animate(game, has_treasury = false)
      return unless game

      action =
        if game.respond_to?(:last_action) && game.last_action
          game.last_action
        elsif game.respond_to?(:actions) && game.actions&.last
          game.actions.last
        end

      current_id =
        if action&.respond_to?(:id) && action&.id
          action.id
        elsif game.respond_to?(:actions) && game.actions&.any?
          game.actions.size
        elsif action
          action.object_id
        else
          0
        end

      info = action ? resolve_action(game, action, has_treasury) : nil

      info_source = info && info[:source_sel]
      info_target = info && info[:target_sel]
      info_text = info && info[:card_text]
      info_share = info ? info[:is_share] : false
      info_train = info ? info[:is_train] : false
      info_delta = info ? info[:delta] : 10

      %x{
    if (typeof window === 'undefined') return;

    var dashboardRoot = document.getElementById('viz-master-frame');
    if (!dashboardRoot) return;

    var actId = #{current_id};
    var gameId = #{(game.respond_to?(:id) && game.id ? game.id : 'default')};

    var trackerKey = '_card_anim_last_act_' + gameId;
    var cacheKey = '_card_anim_cache_' + gameId;

    if (!window[cacheKey]) {
      window[cacheKey] = {};
    }

    var cache = window[cacheKey];
    var prevActId = window[trackerKey];
    var newData = null;

    if (#{!info.nil?}) {
      newData = {
        source_sel: #{info_source},
        target_sel: #{info_target},
        card_text: #{info_text},
        is_share: #{info_share},
        is_train: #{info_train},
        delta: #{info_delta}
      };

      if (!cache[actId]) {
        cache[actId] = newData;
      }
    }

    if (prevActId === undefined) {
      window[trackerKey] = actId;
      return;
    }

    if (prevActId === actId) return;

    var isForward = actId > prevActId;

    var activeData = isForward
      ? (cache[actId] || newData)
      : cache[prevActId];

    window[trackerKey] = actId;

    if (!activeData) return;

    var fromSel = isForward
      ? activeData.source_sel
      : activeData.target_sel;

    var toSel = isForward
      ? activeData.target_sel
      : activeData.source_sel;

    var text = activeData.card_text || 'Card';
    var isShare = activeData.is_share;
    var isTrain = activeData.is_train;
    var delta = activeData.delta || 10;

    window.requestAnimationFrame(function() {
      setTimeout(function() {

        // --- START FIX ---
        var findElement = function(selector) {
          if (!selector) return null;
          var s = String(selector).trim();
          if (s.charAt(0) === '#') {
            var spaceIdx = s.indexOf(' ');
            var rawId = spaceIdx === -1 ? s.substring(1) : s.substring(1, spaceIdx);
            var rest = spaceIdx === -1 ? '' : s.substring(spaceIdx + 1).trim();
            var baseEl = document.getElementById(rawId);
            if (!baseEl) {
              var safeId = rawId.replace(/["\\]/g, '\\$&');
              try {
                baseEl = dashboardRoot.querySelector('[id="' + safeId + '"]');
              } catch (e0) {
                baseEl = null;
              }
            }
            if (baseEl && dashboardRoot.contains(baseEl)) {
              if (!rest) return baseEl;
              try {
                return baseEl.querySelector(rest) || baseEl;
              } catch (err) {
                return baseEl;
              }
            }
          }
          var safeSel = s.replace(/#([^\s.,>+~:#\[\]]+)/g, function(_, idPart) {
            return '[id="' + idPart.replace(/["\\]/g, '\\$&') + '"]';
          });
          try {
            return dashboardRoot.querySelector(safeSel);
          } catch (e1) {
            return null;
          }
        };
        // --- END FIX ---

        var fromEl = findElement(fromSel);
        var toEl = findElement(toSel);

        if (isTrain) {
          var exactTrainCard = function(el) {
            if (!el) return null;
            if (el.matches && el.matches('.game-card')) return el;
            return el.querySelector ? el.querySelector('.game-card') : null;
          };
          fromEl = exactTrainCard(fromEl);
          toEl = exactTrainCard(toEl);
        }

        var savedSourceRect = null;
        if (isTrain) {
          if (isForward && window._railcard_pending_source_rect) {
            savedSourceRect = window._railcard_pending_source_rect;
          } else if (!isForward && activeData.train_target_rect) {
            savedSourceRect = activeData.train_target_rect;
          }
        }

        window._railcard_pending_transfer = null;
        window._railcard_pending_source = null;
        window._railcard_pending_target = null;
        window._railcard_pending_source_rect = null;

        if (!toEl) return;
        if (!fromEl && !savedSourceRect) return;

        var fromCard = null;
        if (fromEl) {
          if (fromEl.matches && (fromEl.matches('.game-card') || fromEl.matches('.major-railcard'))) {
            fromCard = fromEl;
          } else {
            fromCard = fromEl.querySelector('.game-card') || fromEl.querySelector('.major-railcard');
          }
        }

        var toCardInner = null;
        if (toEl.matches && (toEl.matches('.game-card') || toEl.matches('.major-railcard'))) {
          toCardInner = toEl;
        } else {
          toCardInner = toEl.querySelector('.game-card') || toEl.querySelector('.major-railcard');
        }

        var hiddenArrival = null;
        if (!isTrain && !isShare && toCardInner) {
          hiddenArrival = toCardInner;
          hiddenArrival.style.visibility = 'hidden';
        }

        var fromRect = savedSourceRect || (fromCard ? fromCard.getBoundingClientRect() : null);
        var destinationCard = toCardInner || toEl;
        var toRect = destinationCard.getBoundingClientRect();

        if (
          !fromRect ||
          fromRect.width === 0 ||
          fromRect.height === 0 ||
          toRect.width === 0 ||
          toRect.height === 0
        ) {
          if (hiddenArrival) hiddenArrival.style.visibility = 'visible';
          return;
        }

        if (isTrain && isForward) {
          activeData.train_target_rect = {
            left: toRect.left,
            top: toRect.top,
            width: toRect.width,
            height: toRect.height
          };
        }

        if (isTrain) {
          var trainWidth = 54;
          var trainHeight = 26;
          var trainStartX = fromRect.left + (fromRect.width / 2) - (trainWidth / 2);
          var trainStartY = fromRect.top + (fromRect.height / 2) - (trainHeight / 2);
          var trainEndX = toRect.left + (toRect.width / 2) - (trainWidth / 2);
          var trainEndY = toRect.top + (toRect.height / 2) - (trainHeight / 2);

          var flyingTrain = document.createElement('div');
          flyingTrain.className = 'game-card flying-train-card';
          flyingTrain.textContent = text;
          flyingTrain.style.position = 'fixed';
          flyingTrain.style.left = trainStartX + 'px';
          flyingTrain.style.top = trainStartY + 'px';
          flyingTrain.style.width = trainWidth + 'px';
          flyingTrain.style.minWidth = trainWidth + 'px';
          flyingTrain.style.height = trainHeight + 'px';
          flyingTrain.style.margin = '0';
          flyingTrain.style.padding = '0';
          flyingTrain.style.display = 'flex';
          flyingTrain.style.alignItems = 'center';
          flyingTrain.style.justifyContent = 'center';
          flyingTrain.style.boxSizing = 'border-box';
          flyingTrain.style.border = '3px solid #2563eb';
          flyingTrain.style.borderRadius = '13px';
          flyingTrain.style.background = '#fdfbf7';
          flyingTrain.style.color = '#111827';
          flyingTrain.style.fontFamily = '"Helvetica Neue", Helvetica, Arial, sans-serif';
          flyingTrain.style.fontSize = '0.85rem';
          flyingTrain.style.fontWeight = '800';
          flyingTrain.style.lineHeight = '1';
          flyingTrain.style.zIndex = '2147483647';
          flyingTrain.style.pointerEvents = 'none';
          flyingTrain.style.transformOrigin = 'center center';
          flyingTrain.style.boxShadow = '0 12px 24px rgba(0,0,0,0.35), 0 0 12px rgba(37,99,235,0.65)';
          dashboardRoot.appendChild(flyingTrain);

          var dxTrain = trainEndX - trainStartX;
          var dyTrain = trainEndY - trainStartY;
          var trainAnimation = flyingTrain.animate([
            { transform: 'translate(0px, 0px) scale(1.15)', opacity: 1, offset: 0 },
            { transform: 'translate(' + (dxTrain * 0.5) + 'px, ' + ((dyTrain * 0.5) - 70) + 'px) scale(1.35)', opacity: 1, offset: 0.5 },
            { transform: 'translate(' + dxTrain + 'px, ' + dyTrain + 'px) scale(1)', opacity: 1, offset: 0.88 },
            { transform: 'translate(' + dxTrain + 'px, ' + dyTrain + 'px) scale(0.92)', opacity: 0, offset: 1 }
          ], {
            duration: 720,
            easing: 'cubic-bezier(0.22, 0.8, 0.25, 1)',
            fill: 'forwards'
          });

          var removeFlyingTrain = function() {
            if (flyingTrain && flyingTrain.parentNode) flyingTrain.parentNode.removeChild(flyingTrain);
          };
          trainAnimation.onfinish = removeFlyingTrain;
          trainAnimation.oncancel = removeFlyingTrain;
          setTimeout(removeFlyingTrain, 1200);
          return;
        }

        var originalTargetText = null;
        if (isShare && toCardInner && isForward) {
          originalTargetText = toCardInner.innerText;
          var currentVal = parseInt(originalTargetText.replace(/[^0-9]/g, ''), 10);
          if (!isNaN(currentVal)) {
            var previousVal = currentVal - delta;
            toCardInner.innerText = previousVal > 0 ? previousVal + '%' : '';
            if (previousVal <= 0) toCardInner.style.visibility = 'hidden';
          }
        }

        var cardWidth = 56;
        var cardHeight = 23;
        var startX = fromRect.left + (fromRect.width / 2) - (cardWidth / 2);
        var startY = fromRect.top + (fromRect.height / 2) - (cardHeight / 2);
        var endX = toRect.left + (toRect.width / 2) - (cardWidth / 2);
        var endY = toRect.top + (toRect.height / 2) - (cardHeight / 2);

        var flying = document.createElement('div');
        flying.className = 'game-card flying-railcard-token';
        flying.innerText = text;
        flying.style.position = 'fixed';
        flying.style.left = startX + 'px';
        flying.style.top = startY + 'px';
        flying.style.width = cardWidth + 'px';
        flying.style.minWidth = cardWidth + 'px';
        flying.style.height = cardHeight + 'px';
        flying.style.margin = '0';
        flying.style.boxSizing = 'border-box';
        flying.style.display = 'inline-flex';
        flying.style.alignItems = 'center';
        flying.style.justifyContent = 'center';
        flying.style.backgroundColor = '#fdfbf7';
        flying.style.color = '#000000';
        flying.style.border = '2px solid #2563eb';
        flying.style.borderRadius = '4px';
        flying.style.fontSize = '0.85rem';
        flying.style.fontWeight = 'bold';
        flying.style.fontFamily = '"Helvetica Neue", Helvetica, Arial, sans-serif';
        flying.style.zIndex = '2147483647';
        flying.style.pointerEvents = 'none';
        flying.style.boxShadow = '0 14px 28px rgba(0,0,0,0.35), 0 4px 10px rgba(0,0,0,0.2)';
        flying.style.opacity = '1';
        flying.style.visibility = 'visible';
        flying.style.transform = 'scale(1.12)';
        flying.style.transition = 'transform 0.55s cubic-bezier(0.2,0.9,0.3,1), opacity 0.15s ease-out';

        dashboardRoot.appendChild(flying);
        flying.getBoundingClientRect();

        window.requestAnimationFrame(function() {
          window.requestAnimationFrame(function() {
            var deltaX = endX - startX;
            var deltaY = endY - startY;

            flying.style.transform = 'translate(' + deltaX + 'px,' + deltaY + 'px) scale(1)';

            setTimeout(function() {
              if (toCardInner) {
                if (originalTargetText !== null) toCardInner.innerText = originalTargetText;
                toCardInner.style.visibility = 'visible';
                toCardInner.style.transition = 'transform 0.18s ease-out, filter 0.18s ease-out';
                toCardInner.style.transform = 'scale(1.18)';
                toCardInner.style.filter = 'brightness(1.3)';

                setTimeout(function() {
                  toCardInner.style.transform = 'scale(1)';
                  toCardInner.style.filter = 'none';
                }, 180);
              }

              flying.style.opacity = '0';

              setTimeout(function() {
                if (flying.parentNode) flying.parentNode.removeChild(flying);
              }, 160);
            }, 560);
          });
        });

      }, 35);
    });
  }
    end

    def self.transfer_val(transfer, key)
      return nil if transfer.nil?

      if transfer.respond_to?(:[])
        begin
          val = transfer[key.to_s] || transfer[key.to_sym]
          return val unless val.nil?
        rescue StandardError
        end
      end

      res = nil
      %x{
        var t = #{transfer};
        if (t) {
          if (typeof t.get === 'function') {
            var v = t.get(#{key});
            if (v === undefined || v === null) {
              v = t.get(#{key.to_sym});
            }
            if (v !== undefined && v !== null) {
              #{res = `v`};
            }
          } else if (t[#{key}] !== undefined && t[#{key}] !== null) {
            #{res = `t[#{key}]`};
          }
        }
      }
      res
    end

    def self.resolve_action(game, action, has_treasury)
      action_name = action.class.name.split('::').last
      entity = action.respond_to?(:entity) ? action.entity : nil
      bundle = action.respond_to?(:bundle) ? action.bundle : nil
      shares = if action.respond_to?(:shares)
                 action.shares
               else
                 (bundle&.respond_to?(:shares) ? bundle.shares : [])
               end

      corp = if bundle&.respond_to?(:corporation) && bundle&.corporation
               bundle.corporation
             elsif action.respond_to?(:corporation) && action.corporation
               action.corporation
             elsif shares.any? && shares.first.respond_to?(:corporation) && shares.first.corporation
               shares.first.corporation
             elsif entity&.respond_to?(:corporation?) && entity&.corporation?
               entity
             end
      corp_id = corp&.id

      source_sel = nil
      target_sel = nil
      card_text = nil
      is_share = false
      is_train = false
      delta = 10

      pending_transfer = nil
      pending_source = nil
      pending_target = nil

      %x{
        if (typeof window !== 'undefined') {
          if (window._railcard_pending_transfer) {
            #{pending_transfer = `window._railcard_pending_transfer`};
          }
          if (window._railcard_pending_source) {
            #{pending_source = `window._railcard_pending_source`};
          }
          if (window._railcard_pending_target) {
            #{pending_target = `window._railcard_pending_target`};
          }
        }
      }

      case action_name
      when 'BuyShares'
        if entity && corp_id
          if entity.respond_to?(:corporation?) && entity.corporation?
            is_share = true
            pct = if bundle&.respond_to?(:percent)
                    bundle.percent
                  elsif shares.any?
                    shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                  else
                    corp&.respond_to?(:share_percent) && corp&.share_percent ? corp.share_percent : 10
                  end
            pct = 10 if pct.to_i <= 0
            delta = pct
            card_text = "#{delta}%"

            target_sel = if pending_target && (!pending_target.to_s.include?('treasury') || has_treasury)
                           pending_target.to_s.sub(/ \.game-card\z/, '')
                         else
                           has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
                         end

            source_sel = if pending_source
                           pending_source.to_s.sub(/ \.game-card\z/, '')
                         elsif bundle&.owner&.player?
                           "#player_shares_#{bundle.owner.id}_#{corp_id}"
                         elsif shares.any? && shares.first.owner&.player?
                           "#player_shares_#{shares.first.owner.id}_#{corp_id}"
                         else
                           "#pool_shares_#{corp_id}"
                         end
          else
            is_share = true
            pct = if bundle&.respond_to?(:percent)
                    bundle.percent
                  else
                    shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                  end
            pct = 10 if pct.to_i <= 0
            delta = pct
            card_text = "#{delta}%"

            target_sel = "#player_shares_#{entity.id}_#{corp_id}"

            if pending_source
              source_sel = pending_source.to_s.sub(/ \.game-card\z/, '')
            else
              from_pool = false

              if action.respond_to?(:source) && action.source == 'pool'
                from_pool = true
              elsif bundle && bundle.owner == game.share_pool
                from_pool = true
              elsif shares.any? && game.share_pool.shares_by_corporation[corp]&.include?(shares.first)
                from_pool = true
              end

              source_sel = if from_pool
                             "#pool_shares_#{corp_id}"
                           elsif bundle&.owner == corp || (shares.any? && shares.first.owner == corp)
                             has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
                           elsif bundle&.owner&.player? && bundle.owner != entity
                             "#player_shares_#{bundle.owner.id}_#{corp_id}"
                           elsif shares.any? && shares.first.owner&.player? && shares.first.owner != entity
                             "#player_shares_#{shares.first.owner.id}_#{corp_id}"
                           else
                             "#ipo_shares_#{corp_id}"
                           end
            end
          end
        end
      when 'SellShares'
        if entity && corp_id
          if entity.respond_to?(:corporation?) && entity.corporation?
            is_share = true
            pct = if bundle&.respond_to?(:percent)
                    bundle.percent
                  elsif shares.any?
                    shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                  else
                    corp&.respond_to?(:share_percent) && corp&.share_percent ? corp.share_percent : 10
                  end
            pct = 10 if pct.to_i <= 0
            delta = pct
            card_text = "#{delta}%"

            source_sel = if pending_source
                           pending_source.to_s.sub(/ \.game-card\z/, '')
                         else
                           has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
                         end

            target_sel = if pending_target
                           pending_target.to_s.sub(/ \.game-card\z/, '')
                         else
                           "#pool_shares_#{corp_id}"
                         end
          else
            is_share = true
            pct = if bundle&.respond_to?(:percent)
                    bundle.percent
                  else
                    shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                  end
            pct = 10 if pct.to_i <= 0
            delta = pct
            card_text = "#{delta}%"

            source_sel = if pending_source
                           pending_source.to_s.sub(/ \.game-card\z/, '')
                         else
                           "#player_shares_#{entity.id}_#{corp_id}"
                         end
            target_sel = "#pool_shares_#{corp_id}"
          end
        end
      when 'Short'
        if entity && corp_id
          is_share = true
          card_text = '-10%'
          delta = 10
          source_sel = "#pool_shares_#{corp_id}"
          target_sel = "#player_shares_#{entity.id}_#{corp_id}"
        end
      when 'BuyTrain'
        if entity
          is_train = true

          train = action.respond_to?(:train) ? action.train : nil
          other = action.respond_to?(:other_entity) ? action.other_entity : nil

          card_text = train ? train.name.to_s : 'Train'

          target_sel =
            ("#train_wrapper_#{entity.id}_#{train.id}" if train)

          if pending_transfer
            source_type = transfer_val(pending_transfer, :source_type)&.to_s
            source_id = transfer_val(pending_transfer, :source_id)&.to_s
            item_id = transfer_val(pending_transfer, :item_id)&.to_s
            variant = transfer_val(pending_transfer, :variant)&.to_s
            safe_variant = variant ? variant.tr('/', '_') : ''

            source_sel =
              if item_id && source_type == 'train_pool'
                "#bank_train_pool_#{item_id}_#{safe_variant}"
              elsif item_id && source_type == 'train_fresh'
                "#bank_train_fresh_#{item_id}_#{safe_variant}"
              elsif item_id && source_id && source_type == 'corporation'
                "#train_wrapper_#{source_id}_#{item_id}"
              end
          end

          if source_sel.nil? && pending_source
            source_sel = pending_source.to_s.sub(/ \.game-card\z/, '')
          elsif source_sel.nil? && other && train
            source_sel = "#train_wrapper_#{other.id}_#{train.id}"
          end
        end
      when 'IssueShares', 'Issue', 'CorporateSellShares', 'ReissueShares', 'Reissue'
        if corp_id
          is_share = true
          pct = if bundle&.respond_to?(:percent)
                  bundle.percent
                elsif shares.any?
                  shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                elsif action.respond_to?(:percent) && action.percent
                  action.percent
                else
                  corp&.respond_to?(:share_percent) && corp&.share_percent ? corp.share_percent : 10
                end
          pct = 10 if pct.to_i <= 0
          delta = pct
          card_text = "#{delta}%"

          source_sel = if pending_source
                         pending_source.to_s.sub(/ \.game-card\z/, '')
                       elsif has_treasury && (bundle&.owner == corp || (shares.any? && shares.first.owner == corp))
                         "#treasury_shares_#{corp_id}"
                       else
                         has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
                       end

          target_sel = if pending_target
                         pending_target.to_s.sub(/ \.game-card\z/, '')
                       else
                         "#pool_shares_#{corp_id}"
                       end
        end
      when 'RedeemShares', 'Redeem', 'CorporateBuyShares'
        if corp_id
          is_share = true
          pct = if bundle&.respond_to?(:percent)
                  bundle.percent
                elsif shares.any?
                  shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                elsif action.respond_to?(:percent) && action.percent
                  action.percent
                else
                  corp&.respond_to?(:share_percent) && corp&.share_percent ? corp.share_percent : 10
                end
          pct = 10 if pct.to_i <= 0
          delta = pct
          card_text = "#{delta}%"

          source_sel = if pending_source
                         pending_source.to_s.sub(/ \.game-card\z/, '')
                       elsif bundle&.owner&.player?
                         "#player_shares_#{bundle.owner.id}_#{corp_id}"
                       elsif shares.any? && shares.first.owner&.player?
                         "#player_shares_#{shares.first.owner.id}_#{corp_id}"
                       else
                         "#pool_shares_#{corp_id}"
                       end

          target_sel = if pending_target && (!pending_target.to_s.include?('treasury') || has_treasury)
                         pending_target.to_s.sub(/ \.game-card\z/, '')
                       else
                         has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
                       end
        end
      when 'BuyCompany'
        if entity
          company = action.respond_to?(:company) ? action.company : nil

          card_text = company ? company.sym.to_s : 'Private'
          target_sel = "#companies_#{entity.id}"

          if pending_transfer
            source_type = transfer_val(pending_transfer, :source_type)&.to_s
            source_id = transfer_val(pending_transfer, :source_id)&.to_s
            item_id = transfer_val(pending_transfer, :item_id)&.to_s

            source_sel =
              if source_id && item_id && %w[player corporation].include?(source_type)
                "#company_wrapper_#{source_id}_#{item_id}"
              else
                '#extra_cards'
              end
          else
            source_sel = '#extra_cards'
          end
        end
      when 'DiscardTrain'
        if entity
          is_train = true
          train = action.respond_to?(:train) ? action.train : nil
          card_text = train ? train.name.to_s : 'Train'
          target_sel = '#extra_cards'
          source_sel = train ? "#train_wrapper_#{entity.id}_#{train.id}" : nil
        end
      end

      return nil unless source_sel && target_sel

      {
        id: action.id || action.object_id,
        source_sel: source_sel,
        target_sel: target_sel,
        card_text: card_text,
        is_share: is_share,
        is_train: is_train,
        delta: delta,
      }
    end

    def self.fly(_source_selector, _dest_selector, hide_source: false)
      # Retained for backwards compatibility if called elsewhere
      yield if block
    end

    def self.animate_action(_game, _action_data)
      yield if block
    end
  end
end
