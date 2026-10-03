# frozen_string_literal: true

module Lib
  module CardAnimation
    def self.check_and_animate(game, has_treasury = false)
      return unless game

      action = if game.respond_to?(:last_action) && game.last_action
                 game.last_action
               elsif game.respond_to?(:actions) && game.actions&.last
                 game.actions.last
               end

      current_id = if action&.respond_to?(:id)
                     action.id
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

      /*
       * Do not overwrite the original route during redo.
       * The original route contains the pre-action owner/source.
       */
      if (!cache[actId]) {
        cache[actId] = newData;
      }
    }

    if (prevActId === undefined) {
      window[trackerKey] = actId;
      return;
    }

    if (prevActId === actId) {
      return;
    }

    var isForward = actId > prevActId;

    /*
     * Forward/redo uses the route belonging to the current action.
     * Undo reverses the route belonging to the action being removed.
     */
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
        var sanitize = function(sel) {
          if (!sel || sel.indexOf('#') !== 0) return sel;

          var tokens = sel.split(' ');
          var rawId = tokens[0].substring(1);
          var safeId = '#' +
            (window.CSS && window.CSS.escape
              ? window.CSS.escape(rawId)
              : rawId);

          tokens[0] = safeId;
          return tokens.join(' ');
        };

        var getElm = function(selector, isDrop) {
          if (!selector) return null;

          var el = document.querySelector(selector);

          if (!el && selector.indexOf(' ') !== -1) {
            el = document.querySelector(selector.split(' ')[0]);
          }

          if (!el && isDrop && selector.indexOf('train_drop_') !== -1) {
            var entityId = selector.substring(
              selector.indexOf('train_drop_') + 'train_drop_'.length
            );

            el = document.querySelector(
              sanitize('#trains_' + entityId)
            );
          }

          return el;
        };

        var src = sanitize(fromSel);
        var tgt = sanitize(toSel);

        var fromEl = getElm(src, false);
        var toEl = getElm(tgt, true);

        if (!fromEl || !toEl) return;

        var fromCard =
          fromEl.querySelector('.game-card') ||
          fromEl.querySelector('.major-railcard') ||
          fromEl;

        var toCardInner =
          toEl.querySelector('.game-card') ||
          toEl.querySelector('.major-railcard');

        /*
         * The engine has already rendered the arriving train/private.
         * Hide that newly rendered target card until the flight lands.
         */
        var hiddenArrival = null;

        if (!isShare && toCardInner) {
          hiddenArrival = toCardInner;
          hiddenArrival.style.visibility = 'hidden';
        }

        var fromRect = fromCard.getBoundingClientRect();
        var toRect = (toCardInner || toEl).getBoundingClientRect();

        if (fromRect.width === 0 || toRect.width === 0) {
          if (hiddenArrival) {
            hiddenArrival.style.visibility = 'visible';
          }
          return;
        }

        var originalTargetText = null;

        if (isShare && toCardInner && isForward) {
          originalTargetText = toCardInner.innerText;

          var currentVal = parseInt(
            originalTargetText.replace(/[^0-9]/g, ''),
            10
          );

          if (!isNaN(currentVal)) {
            var previousVal = currentVal - delta;

            toCardInner.innerText =
              previousVal > 0 ? previousVal + '%' : '';

            if (previousVal <= 0) {
              toCardInner.style.visibility = 'hidden';
            }
          }
        }

        var cardWidth = 56;
        var cardHeight = 23;

        var startX =
          fromRect.left + (fromRect.width / 2) - (cardWidth / 2);

        var startY =
          fromRect.top + (fromRect.height / 2) - (cardHeight / 2);

        var endX =
          toRect.left + (toRect.width / 2) - (cardWidth / 2);

        var endY =
          toRect.top + (toRect.height / 2) - (cardHeight / 2);

        var flying = document.createElement('div');

        flying.className =
          'game-card flying-railcard-token';

        flying.innerText = text;
        flying.style.position = 'fixed';
        flying.style.left = startX + 'px';
        flying.style.top = startY + 'px';
        flying.style.minWidth = '3.5rem';
        flying.style.height = '1.45rem';
        flying.style.margin = '0';
        flying.style.boxSizing = 'border-box';
        flying.style.display = 'inline-flex';
        flying.style.alignItems = 'center';
        flying.style.justifyContent = 'center';
        flying.style.backgroundColor = '#fdfbf7';
        flying.style.color = '#000000';
        flying.style.border = '2px solid #2563eb';
        flying.style.borderRadius = isTrain ? '12px' : '4px';
        flying.style.fontSize = '0.85rem';
        flying.style.fontWeight = 'bold';
        flying.style.fontFamily =
          '"Helvetica Neue", Helvetica, Arial, sans-serif';
        flying.style.zIndex = '999999';
        flying.style.pointerEvents = 'none';
        flying.style.boxShadow =
          '0 14px 28px rgba(0,0,0,0.35), ' +
          '0 4px 10px rgba(0,0,0,0.2)';
        flying.style.transform = 'scale(1.15)';
        flying.style.transition =
          'transform 0.45s cubic-bezier(0.2, 0.9, 0.3, 1), ' +
          'opacity 0.15s ease-out';

        document.body.appendChild(flying);

        window.requestAnimationFrame(function() {
          var deltaX = endX - startX;
          var deltaY = endY - startY;

          flying.style.transform =
            'translate(' + deltaX + 'px, ' + deltaY +
            'px) scale(1.02)';

          setTimeout(function() {
            if (toCardInner) {
              if (originalTargetText !== null) {
                toCardInner.innerText = originalTargetText;
              }

              toCardInner.style.visibility = 'visible';
              toCardInner.style.transition =
                'transform 0.18s ease-out, filter 0.18s ease-out';
              toCardInner.style.transform = 'scale(1.22)';
              toCardInner.style.filter = 'brightness(1.3)';

              setTimeout(function() {
                toCardInner.style.transform = 'scale(1)';
                toCardInner.style.filter = 'none';
              }, 180);
            }

            flying.style.opacity = '0';

            setTimeout(function() {
              if (flying.parentNode) {
                flying.parentNode.removeChild(flying);
              }
            }, 160);
          }, 460);
        });
      }, 35);
    });
  }
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

      corp = if bundle&.respond_to?(:corporation)
               bundle.corporation
             elsif action.respond_to?(:corporation)
               action.corporation
             elsif shares.any? && shares.first.respond_to?(:corporation)
               shares.first.corporation
             end
      corp_id = corp&.id

      source_sel = nil
      target_sel = nil
      card_text = nil
      is_share = false
      is_train = false
      delta = 10

      pending_transfer = `typeof window !== 'undefined' ? window._railcard_pending_transfer : null`

      %x{
  if (typeof window !== 'undefined') {
    window._railcard_pending_transfer = null;
  }
}

      case action_name
      when 'BuyShares'
        if entity && corp_id
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

          pending_source = `typeof window !== 'undefined' ? window._railcard_pending_source : null`

          %x{
if (typeof window !== 'undefined') {
window._railcard_pending_source = null;
}
}
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
      when 'SellShares'
        if entity && corp_id
          is_share = true
          pct = if bundle&.respond_to?(:percent)
                  bundle.percent
                else
                  shares.sum { |s| s.respond_to?(:percent) ? s.percent : 10 }
                end
          pct = 10 if pct.to_i <= 0
          delta = pct
          card_text = "#{delta}%"

          source_sel = "#player_shares_#{entity.id}_#{corp_id}"
          target_sel = "#pool_shares_#{corp_id}"
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
          target_sel = "#train_drop_#{entity.id}"

          if pending_transfer
            source_type = `#{pending_transfer}["source_type"]`
            source_id = `#{pending_transfer}["source_id"]`
            item_id = `#{pending_transfer}["item_id"]`
            variant = `#{pending_transfer}["variant"]`

            item_id = item_id.to_s
            safe_variant = variant.to_s.tr('/', '_')

            source_sel =
              case source_type.to_s
              when 'train_pool'
                "#bank_train_pool_#{item_id}_#{safe_variant}"
              when 'train_fresh'
                "#bank_train_fresh_#{item_id}_#{safe_variant}"
              when 'corporation'
                "#train_wrapper_#{source_id}_#{item_id}"
              else
                '#extra_cards'
              end
          elsif other && train
            source_sel = "#train_wrapper_#{other.id}_#{train.id}"
          elsif train
            source_sel = '#extra_cards'
          end
        end
      when 'IssueShares', 'Issue', 'CorporateSellShares', 'ReissueShares', 'Reissue'
        if corp_id
          is_share = true
          card_text = '10%'
          source_sel = has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
          target_sel = "#pool_shares_#{corp_id}"
        end
      when 'RedeemShares', 'Redeem', 'CorporateBuyShares'
        if corp_id
          is_share = true
          card_text = '10%'
          source_sel = "#pool_shares_#{corp_id}"
          target_sel = has_treasury ? "#treasury_shares_#{corp_id}" : "#ipo_shares_#{corp_id}"
        end
      when 'BuyCompany'
        if entity
          company = action.respond_to?(:company) ? action.company : nil

          card_text = company ? company.sym.to_s : 'Private'
          target_sel = "#companies_#{entity.id}"

          if pending_transfer
            source_type = `#{pending_transfer}["source_type"]`
            source_id = `#{pending_transfer}["source_id"]`
            item_id = `#{pending_transfer}["item_id"]`

            source_sel =
              case source_type.to_s
              when 'player', 'corporation'
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

    def self.fly(source_selector, dest_selector, hide_source: false, &block)
      # Retained for backwards compatibility if called elsewhere
      yield if block_given?
    end

    def self.animate_action(_game, _action_data, &block)
      yield if block_given?
    end
  end
end
