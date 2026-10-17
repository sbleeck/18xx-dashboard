# frozen_string_literal: true

module Lib
  class LoanAnimation
    def self.fly(source, target, &callback)
      s_str = source ? source.to_s : ''
      t_str = target ? target.to_s : ''
      done = callback

      %x(
        (function() {
          function resolveNode(selector) {
            if (!selector || selector === '') return null;
            if (selector === 'bank_loans_taken' || selector === '#bank_loan_active') {
              var bankEl = document.getElementById('bank_loan_active') ||
                           document.getElementById('bank_loan_btn') ||
                           document.getElementById('bank') ||
                           document.getElementById('extra_cards');
              if (bankEl) return bankEl;
            }

            var parts = String(selector).split(',');
            for (var i = 0; i < parts.length; i++) {
              var sel = parts[i].trim();
              if (!sel) continue;
              if (sel === 'bank_loans_taken' || sel === '#bank_loan_active') {
                var bEl = document.getElementById('bank_loan_active') ||
                          document.getElementById('bank_loan_btn') ||
                          document.getElementById('bank');
                if (bEl) return bEl;
              }
              if (sel.charAt(0) === '#') {
                var elById = document.getElementById(sel.slice(1));
                if (elById) return elById;
              }
              try {
                var elQs = document.querySelector(sel);
                if (elQs) return elQs;
              } catch (e) {}
            }
            return null;
          }

          var triggerDone = function() {
            var cb = #{done};
            if (!cb) return;
            if (typeof cb.$call === 'function') {
              cb.$call();
            } else if (typeof cb.call === 'function') {
              cb.call(null);
            } else if (typeof cb === 'function') {
              cb();
            }
          };

          var sourceNode = resolveNode(#{s_str});
          var targetNode = resolveNode(#{t_str});

          if (!sourceNode || !targetNode) {
            triggerDone();
            return;
          }

          var from = sourceNode.getBoundingClientRect();
          var to = targetNode.getBoundingClientRect();
          var fromX = from.left + (from.width > 0 ? from.width / 2 : 4);
          var fromY = from.top + (from.height > 0 ? from.height / 2 : 4);
          var toX = to.left + (to.width > 0 ? to.width / 2 : 4);
          var toY = to.top + (to.height > 0 ? to.height / 2 : 4);

          var dot = document.createElement('div');
          dot.setAttribute('aria-hidden', 'true');
          dot.style.position = 'fixed';
          dot.style.left = (fromX - 5) + 'px';
          dot.style.top = (fromY - 5) + 'px';
          dot.style.width = '10px';
          dot.style.height = '10px';
          dot.style.borderRadius = '50%';
          dot.style.backgroundColor = '#dc3545';
          dot.style.boxShadow = '0 0 6px rgba(220, 38, 38, 0.8)';
          dot.style.zIndex = '999999';
          dot.style.pointerEvents = 'none';
          dot.style.willChange = 'transform, box-shadow';
          document.body.appendChild(dot);

          var dx = toX - fromX;
          var dy = toY - fromY;
          var midX = dx * 0.5;
          var midY = dy * 0.5 - 60;

          var duration = 500;
          var finished = false;
          var finish = function() {
            if (finished) return;
            finished = true;
            if (dot && dot.parentNode) {
              dot.parentNode.removeChild(dot);
            }
            triggerDone();
          };

          if (typeof dot.animate === 'function') {
            var anim = dot.animate([
              {
                transform: 'translate(0px, 0px) scale(1)',
                boxShadow: '0 0 4px rgba(220, 38, 38, 0.5)',
                offset: 0
              },
              {
                transform: 'translate(' + midX + 'px, ' + midY + 'px) scale(3.2)',
                boxShadow: '0 24px 32px rgba(0, 0, 0, 0.45), 0 0 16px rgba(220, 38, 38, 0.9)',
                offset: 0.5
              },
              {
                transform: 'translate(' + dx + 'px, ' + dy + 'px) scale(1)',
                boxShadow: '0 0 4px rgba(220, 38, 38, 0.5)',
                offset: 1
              }
            ], {
              duration: duration,
              easing: 'cubic-bezier(0.25, 1, 0.5, 1)',
              fill: 'forwards'
            });
            anim.onfinish = finish;
            anim.oncancel = finish;
            setTimeout(finish, duration + 60);
          } else {
            dot.style.transition = 'transform ' + duration + 'ms cubic-bezier(0.25, 1, 0.5, 1)';
            requestAnimationFrame(function() {
              requestAnimationFrame(function() {
                dot.style.transform = 'translate(' + dx + 'px, ' + dy + 'px)';
              });
            });
            setTimeout(finish, duration + 60);
          }
        })();
      )
    end
  end
end
