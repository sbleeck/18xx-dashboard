# frozen_string_literal: true

module Lib
  module MarkerAnimation
    def self.check_and_animate(game)
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

      info = action ? resolve_action(game, action) : nil

      info_corp_id = info && info[:corp_id]
      info_hex_id = info && info[:hex_id]
      info_color = info && info[:color]
      info_text_color = info && info[:text_color]
      info_token_text = info && info[:token_text]
      info_logo = info && info[:logo]
      info_source = info && info[:source_sel]
      info_target = info && info[:target_sel]
      game_id = game.respond_to?(:id) && game.id ? game.id.to_s : 'default'

      %x{
    if (typeof window === 'undefined') return;

    var actId = #{current_id};
    var gameId = #{game_id};
    var trackerKey = '_marker_anim_last_act_' + gameId;
    var cacheKey = '_marker_anim_cache_' + gameId;

    if (!window[cacheKey]) {
      window[cacheKey] = {};
    }

    var cache = window[cacheKey];
    var prevActId = window[trackerKey];

    var newData = null;

    if (#{!info.nil?}) {
      newData = {
        corp_id: #{info_corp_id},
        hex_id: #{info_hex_id},
        color: #{info_color},
        text_color: #{info_text_color},
        token_text: #{info_token_text},
        logo: #{info_logo},
        source_sel: #{info_source},
        target_sel: #{info_target}
      };

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
    var activeData = isForward ? (cache[actId] || newData) : cache[prevActId];

    window[trackerKey] = actId;

    if (!activeData) return;

    var fromSel = isForward ? activeData.source_sel : activeData.target_sel;
    var toSel = isForward ? activeData.target_sel : activeData.source_sel;

    window.requestAnimationFrame(function() {
      setTimeout(function() {
        var sanitize = function(sel) {
          if (!sel || sel.indexOf('#') !== 0) return sel;
          var tokens = sel.split(' ');
          var rawId = tokens[0].substring(1);
          var safeId = '#' + (window.CSS && window.CSS.escape ? window.CSS.escape(rawId) : rawId);
          tokens[0] = safeId;
          return tokens.join(' ');
        };

        var getElm = function(selector, isHex) {
          if (!selector) return null;
          var el = document.querySelector(selector);
          if (!el && selector.indexOf(' ') !== -1) {
            el = document.querySelector(selector.split(' ')[0]);
          }
          if (!el && isHex) {
            var rawHex = selector.replace(/^#hex-/, '');
            el = document.getElementById('hex-' + rawHex) ||
                 document.getElementById('hex-' + rawHex.toUpperCase()) ||
                 document.querySelector('.hex-' + rawHex) ||
                 document.querySelector('.hex-' + rawHex.toUpperCase());
          }
          if (!el && !isHex && selector.indexOf('#tokens_') !== -1) {
            var corp = selector.replace(/^#tokens_/, '');
            el = document.querySelector('#tokens_cell_' + corp) ||
                 document.querySelector('#status_major_' + corp);
          }
          return el;
        };

        var fromEl = getElm(sanitize(fromSel), !isForward);
        var toEl = getElm(sanitize(toSel), isForward);

        if (!fromEl || !toEl) return;

        var fromRect = fromEl.getBoundingClientRect();
        var toRect = toEl.getBoundingClientRect();

        if (fromRect.width === 0 || toRect.width === 0) return;

        var targetCitySlot = toEl.querySelector ? (
          toEl.querySelector('.token-' + activeData.corp_id) ||
          toEl.querySelector('circle[r]') ||
          toEl.querySelector('.city-slot')
        ) : null;

        var targetRect = targetCitySlot ? targetCitySlot.getBoundingClientRect() : toRect;

        var markerSize = 44;
        var startX = fromRect.left + (fromRect.width / 2) - (markerSize / 2);
        var startY = fromRect.top + (fromRect.height / 2) - (markerSize / 2);
        var endX = targetRect.left + (targetRect.width / 2) - (markerSize / 2);
        var endY = targetRect.top + (targetRect.height / 2) - (markerSize / 2);

        var flying = document.createElement('div');
        flying.className = 'flying-marker-token';
        flying.style.position = 'fixed';
        flying.style.left = startX + 'px';
        flying.style.top = startY + 'px';
        flying.style.width = markerSize + 'px';
        flying.style.height = markerSize + 'px';
        flying.style.borderRadius = '50%';
        flying.style.boxSizing = 'border-box';
        flying.style.display = 'flex';
        flying.style.alignItems = 'center';
        flying.style.justifyContent = 'center';
        flying.style.backgroundColor = activeData.color || '#4169e1';
        flying.style.color = activeData.text_color || '#ffffff';
        flying.style.border = '3px solid #ffffff';
        flying.style.fontFamily = '"Helvetica Neue", Arial, sans-serif';
        flying.style.fontSize = '0.92rem';
        flying.style.fontWeight = '900';
        flying.style.textAlign = 'center';
        flying.style.zIndex = '9999999';
        flying.style.pointerEvents = 'none';
        flying.style.boxShadow = '0 10px 25px rgba(0,0,0,0.5), 0 0 20px ' + (activeData.color || '#00ffff');

        if (activeData.logo) {
          var img = document.createElement('img');
          img.src = activeData.logo;
          img.style.width = '100%';
          img.style.height = '100%';
          img.style.borderRadius = '50%';
          img.style.objectFit = 'contain';
          img.style.pointerEvents = 'none';
          flying.appendChild(img);
        } else {
          flying.innerText = activeData.token_text || activeData.corp_id || 'TOK';
        }

        document.body.appendChild(flying);

        var startTime = performance.now();
        var flightDuration = 560;
        var slamDuration = 280;
        var totalDuration = flightDuration + slamDuration;
        var slamTriggered = false;

        function triggerHexSlamAndShockwave() {
          if (slamTriggered) return;
          slamTriggered = true;

          // 1. Seismic Hex Shake
          var shakeStart = performance.now();
          var shakeDur = 340;

          function shakeStep(now) {
            var shakeElapsed = now - shakeStart;
            if (shakeElapsed < shakeDur) {
              var decay = 1 - (shakeElapsed / shakeDur);
              var sx = (Math.sin(shakeElapsed * 0.12) * 8 * decay).toFixed(2);
              var sy = (Math.cos(shakeElapsed * 0.14) * 6 * decay).toFixed(2);
              toEl.style.transform = 'translate(' + sx + 'px, ' + sy + 'px)';
              window.requestAnimationFrame(shakeStep);
            } else {
              toEl.style.transform = '';
            }
          }
          window.requestAnimationFrame(shakeStep);

          // 2. Cyan Shockwave Ripple
          var poly = toEl.querySelector('.hex-highlight-poly');
          var pointsStr = poly ? poly.getAttribute('points') : '';
          if (!pointsStr) pointsStr = '-50,0 -25,-43.3 25,-43.3 50,0 25,43.3 -25,43.3';

          var transformStr = toEl.getAttribute('data-transform') || '';
          var shockGroup = document.createElementNS('http://www.w3.org/2000/svg', 'g');
          shockGroup.setAttribute('transform', transformStr);
          shockGroup.setAttribute('pointer-events', 'none');

          var shockPoly = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
          shockPoly.setAttribute('points', pointsStr);
          shockPoly.setAttribute('fill', '#00ffff');
          shockPoly.setAttribute('fill-opacity', '0.45');
          shockPoly.setAttribute('stroke', '#00ffff');
          shockPoly.setAttribute('stroke-width', '10');
          shockPoly.setAttribute('stroke-opacity', '1.0');
          shockPoly.style.filter = 'drop-shadow(0 0 12px #00ffff)';

          shockGroup.appendChild(shockPoly);
          toEl.appendChild(shockGroup);

          var waveStart = performance.now();
          var waveDur = 550;

          function waveStep(now) {
            var waveElapsed = now - waveStart;
            if (waveElapsed < waveDur) {
              var pw = waveElapsed / waveDur;
              var sw = 1.0 + 2.2 * (1 - Math.pow(1 - pw, 3));
              var op = Math.max(0, 1.0 - pw);
              shockPoly.setAttribute('transform', 'scale(' + sw.toFixed(3) + ')');
              shockPoly.setAttribute('stroke-opacity', op.toFixed(3));
              shockPoly.setAttribute('fill-opacity', (0.35 * op).toFixed(3));
              shockPoly.setAttribute('stroke-width', (10 * (1 - pw * 0.7)).toFixed(1));
              window.requestAnimationFrame(waveStep);
            } else {
              if (shockGroup.parentNode) shockGroup.parentNode.removeChild(shockGroup);
            }
          }
          window.requestAnimationFrame(waveStep);

          // 3. Hex Border Flash
          if (poly) {
            poly.setAttribute('stroke', '#00ffff');
            poly.setAttribute('stroke-width', '10');
            poly.setAttribute('fill', '#00ffff');
            poly.setAttribute('fill-opacity', '0.35');
            setTimeout(function() {
              poly.setAttribute('stroke', poly.getAttribute('data-orig-stroke') || 'transparent');
              poly.setAttribute('stroke-width', poly.getAttribute('data-orig-width') || '0');
              poly.setAttribute('fill', poly.getAttribute('data-orig-fill') || 'transparent');
              poly.setAttribute('fill-opacity', poly.getAttribute('data-orig-fill-opacity') || '0');
            }, 550);
          }
        }

        function frame(now) {
          var elapsed = now - startTime;

          if (elapsed <= flightDuration) {
            var p = elapsed / flightDuration;
            var ease = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2;
            var arcY = Math.sin(p * Math.PI) * 110;

            var curX = startX + (endX - startX) * ease;
            var curY = startY + (endY - startY) * ease - arcY;

            var scale = 1.0;
            if (p < 0.65) {
              scale = 1.0 + 2.6 * Math.sin((p / 0.65) * Math.PI / 2);
            } else {
              var pLand = (p - 0.65) / 0.35;
              scale = 3.6 - 2.75 * pLand;
            }

            var rot = Math.sin(p * Math.PI) * 18;
            var shadowSize = 15 + 40 * Math.sin(p * Math.PI);

            flying.style.left = curX.toFixed(1) + 'px';
            flying.style.top = curY.toFixed(1) + 'px';
            flying.style.transform = 'scale(' + scale.toFixed(3) + ') rotate(' + rot.toFixed(1) + 'deg)';
            flying.style.boxShadow = '0 ' + (shadowSize * 0.8).toFixed(1) + 'px ' + shadowSize.toFixed(1) +
                                    'px rgba(0,0,0,0.65), 0 0 ' + (shadowSize * 0.9).toFixed(1) + 'px #00ffff';

            window.requestAnimationFrame(frame);
          } else if (elapsed <= totalDuration) {
            triggerHexSlamAndShockwave();

            var slamP = (elapsed - flightDuration) / slamDuration;
            var settleScale = 0.85 + 0.25 * Math.sin(slamP * Math.PI);
            var opacity = Math.max(0, 1.0 - (slamP * 1.6));

            flying.style.left = endX.toFixed(1) + 'px';
            flying.style.top = endY.toFixed(1) + 'px';
            flying.style.transform = 'scale(' + settleScale.toFixed(3) + ')';
            flying.style.opacity = opacity.toFixed(2);

            window.requestAnimationFrame(frame);
          } else {
            triggerHexSlamAndShockwave();
            if (flying.parentNode) {
              flying.parentNode.removeChild(flying);
            }
          }
        }

        window.requestAnimationFrame(frame);
      }, 35);
    });
  }
    end

    def self.resolve_action(_game, action)
      action_name = action.class.name.split('::').last
      valid_actions = %w[PlaceToken HexToken LayToken PlaceHomeToken HomeToken]

      is_token_action = valid_actions.include?(action_name) ||
                        (action.respond_to?(:token) && action.token && action_name.downcase.include?('token')) ||
                        (action.respond_to?(:city) && action.city && action_name.downcase.include?('token'))

      return nil unless is_token_action

      entity = action.respond_to?(:entity) ? action.entity : nil
      token = action.respond_to?(:token) ? action.token : nil

      corp = if entity&.respond_to?(:corporation?) && entity.corporation?
               entity
             elsif token&.respond_to?(:corporation) && token.corporation
               token.corporation
             elsif entity&.respond_to?(:owner) && entity.owner&.respond_to?(:corporation?) && entity.owner.corporation?
               entity.owner
             else
               entity
             end

      return nil unless corp

      corp_id = corp.respond_to?(:id) ? corp.id.to_s : corp.to_s

      city = action.respond_to?(:city) ? action.city : nil
      hex = if city&.respond_to?(:hex) && city.hex
              city.hex
            elsif action.respond_to?(:hex) && action.hex
              action.hex
            elsif token&.respond_to?(:hex) && token.hex
              token.hex
            end

      hex_id = if hex&.respond_to?(:id)
                 hex.id.to_s
               elsif hex
                 hex.to_s
               end

      return nil unless hex_id && !hex_id.empty?

      logo = if corp.respond_to?(:logo) && corp.logo
               corp.logo
             elsif corp.respond_to?(:simple_logo) && corp.simple_logo
               corp.simple_logo
             end

      color = (corp.respond_to?(:color) && corp.color) || '#4169e1'
      text_color = (corp.respond_to?(:text_color) && corp.text_color) || '#ffffff'
      token_text = corp_id[0..2].upcase

      {
        id: action.id || action.object_id,
        corp_id: corp_id,
        hex_id: hex_id,
        color: color,
        text_color: text_color,
        token_text: token_text,
        logo: logo,
        source_sel: "#tokens_#{corp_id}",
        target_sel: "#hex-#{hex_id}",
      }
    end
  end
end
