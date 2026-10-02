# frozen_string_literal: true

module Lib
  module CardAnimation
    def self.fly(source_selector, dest_selector, hide_source: false, &block)
      %x{
        var js_block = #{block};
        var card = null, startX, startY, width, height, clone, styleEl;
        try {
          var sel = #{source_selector};
          card = window.document.querySelector(sel);
          if (!card) {
            var parts = sel.split(',');
            for (var p = 0; p < parts.length; p++) {
              var s = parts[p].trim();
              card = window.document.querySelector(s);
              if (card) break;
            }
          }
          if (card) {
            var innerToken = card.querySelector('.token') || card.querySelector('.game-card') || card.querySelector('.card') || card.querySelector('svg');
            if (innerToken && card.offsetWidth > 150) {
              card = innerToken;
            }
          }
        } catch(e) {
          console.warn("Animation failed to locate source: " + #{source_selector}, e);
        }

        if (!card) {
if (
  js_block &&
  js_block !== Opal.nil &&
  typeof js_block.$call === 'function'
) {
  js_block.$call();
}
          return;
        }

        var rect = card.getBoundingClientRect();
        startX = rect.left;
        startY = rect.top;
        width = rect.width || 40;
        height = rect.height || 40;

        clone = card.cloneNode(true);

        var nestedDivs = clone.getElementsByTagName('div');
        for (var i = 0; i < nestedDivs.length; i++) {
          if (nestedDivs[i].style.position === 'absolute') {
            nestedDivs[i].parentNode.removeChild(nestedDivs[i]);
          }
        }

        clone.style.position = 'fixed';
        clone.style.left = startX + 'px';
        clone.style.top = startY + 'px';
        clone.style.width = width + 'px';
        clone.style.height = height + 'px';
        clone.style.zIndex = '99999';
        clone.style.margin = '0';
        clone.style.transition = 'transform 0.6s cubic-bezier(0.25, 1, 0.5, 1), opacity 0.6s ease-in-out';
        clone.style.pointerEvents = 'none';

        window.document.body.appendChild(clone);

        if (#{hide_source}) {
          styleEl = window.document.createElement('style');
          styleEl.innerHTML = #{source_selector} + " { opacity: 0 !important; pointer-events: none !important; }";
          window.document.head.appendChild(styleEl);
        }

        window.requestAnimationFrame(function() {
          window.requestAnimationFrame(function() {
            var dest = window.document.querySelector(#{dest_selector});
            if (dest) {
              var destRect = dest.getBoundingClientRect();
              var destX = destRect.left + (destRect.width / 2) - (width / 2);
              var destY = destRect.top + (destRect.height / 2) - (height / 2);

              clone.style.transform = 'translate(' + (destX - startX) + 'px, ' + (destY - startY) + 'px)';
            } else {
              clone.style.transform = 'translate(0px, -50px) scale(1.1)';
              clone.style.opacity = '0';
            }

            setTimeout(function() {
if (
  js_block &&
  js_block !== Opal.nil &&
  typeof js_block.$call === 'function'
) {
  js_block.$call();
}

              setTimeout(function() {
                clone.style.transition = 'opacity 0.25s ease-out';
                clone.style.opacity = '0';

                setTimeout(function() {
                  if (clone.parentNode) {
                    clone.parentNode.removeChild(clone);
                  }
                  if (styleEl && styleEl.parentNode) {
                    styleEl.parentNode.removeChild(styleEl);
                  }
                }, 250);
              }, 100);
            }, 600);
          });
        });
      }
    end

    def self.animate_action(_game, action_data, &block)
      action_type = action_data['type']

      if action_type == 'buy_shares'
        entity_id = action_data['entity']
        bundle = action_data['shares'] || []
        corp_id = bundle.first&.dig('corporation') || action_data['corporation']

        source_selector = "#market-cell-#{corp_id}, #bank-pool-#{corp_id}, [data-corp='#{corp_id}']"
        dest_selector = "#player-row-#{entity_id}, #player-hand-#{entity_id}, #entity-#{entity_id}"

        fly(source_selector, dest_selector, &block)
      else
        yield
      end
    end
  end
end
