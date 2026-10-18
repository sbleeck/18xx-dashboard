# frozen_string_literal: true

module Lib
  module RowAnimation
    # Row movement animation intentionally uses FLIP on the live row.
    # It never clones table rows, never hides the live row, and therefore
    # cannot leave a static Bank/Status snapshot behind after train transfers.
    %x(
      window.RowAnimCache = window.RowAnimCache || {};
    )

    def self.hook(id)
      {
        prepatch: %x{
          function(oldVnode, vnode) {
            var elm = oldVnode.elm;
            var dashboardRoot = window.document.getElementById('viz-master-frame');
            if (!dashboardRoot || !elm || !dashboardRoot.contains(elm)) return;

            // Never animate player rows, the Bank, or non-corporation rows
            if (!elm.hasAttribute('data-corp') || elm.querySelector('#bank, #extra_cards')) {
              delete window.RowAnimCache[#{id}];
              elm.style.transform = '';
              elm.style.transition = '';
              elm.style.opacity = '1';
              return;
            }

            // Suppress row movement animations during active card/train transfers
            var transferRecent = (Date.now() - (window._railcard_last_transfer_time || 0)) < 1200;
            if (window._railcard_pending_transfer || window._railcard_pending_source_rect || transferRecent) {
              delete window.RowAnimCache[#{id}];
              elm.style.transform = '';
              elm.style.transition = '';
              elm.style.opacity = '1';
              return;
            }

            window.RowAnimCache[#{id}] = elm.getBoundingClientRect();
          }
        },
        postpatch: %x{
          function(oldVnode, vnode) {
            var elm = vnode.elm;
            var dashboardRoot = window.document.getElementById('viz-master-frame');
            var oldRect = window.RowAnimCache[#{id}];
            delete window.RowAnimCache[#{id}];

            if (!dashboardRoot || !elm || !dashboardRoot.contains(elm) || !oldRect) return;

            // Strict safety guard: never transform rows containing or adjacent to the Bank
            if (!elm.hasAttribute('data-corp') || elm.querySelector('#bank, #extra_cards')) {
              elm.style.transform = '';
              elm.style.transition = '';
              elm.style.opacity = '1';
              return;
            }

            var transferRecent = (Date.now() - (window._railcard_last_transfer_time || 0)) < 1200;
            if (window._railcard_pending_transfer || window._railcard_pending_source_rect || transferRecent) {
              elm.style.transform = '';
              elm.style.transition = '';
              elm.style.opacity = '1';
              return;
            }

            Promise.resolve().then(function() {
              var newRect = elm.getBoundingClientRect();
              var deltaY = oldRect.top - newRect.top;
              if (Math.abs(deltaY) <= 1.0) return;

              elm.style.opacity = '1';
              elm.style.transition = 'none';
              elm.style.transform = 'translateY(' + deltaY + 'px)';
              elm.getBoundingClientRect();

              window.requestAnimationFrame(function() {
                elm.style.transition = 'transform 0.5s cubic-bezier(0.25, 0.8, 0.25, 1)';
                elm.style.transform = 'translateY(0px)';
              });

              setTimeout(function() {
                elm.style.transition = '';
                elm.style.transform = '';
                elm.style.opacity = '1';
              }, 560);
            });
          }
        },
      }
    end
  end
end
