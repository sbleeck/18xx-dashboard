# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/params'
require 'lib/settings'
require 'lib/storage'

# History navigation deliberately uses full-page navigation when changing actions.
# This avoids reconciling VDOM trees belonging to different reconstructed game states.

# Monkey-patch Lib::Params to support runtime overrides and preserve tab anchors (e.g. #dashboard)
module Lib
  module Params
    class << self
      alias _orig_get_param [] unless method_defined?(:_orig_get_param)
      alias _orig_add_dashboard_anchor add unless method_defined?(:_orig_add_dashboard_anchor)

      def [](key)
        url_val = _orig_get_param(key)
        if @overrides&.key?(key.to_s)
          @overrides[key.to_s] = url_val if url_val && !url_val.empty? && url_val != @overrides[key.to_s]
          return @overrides[key.to_s]
        end

        url_val
      end

      def []=(key, val)
        @overrides ||= {}
        if val.nil? || val.to_s.empty?
          @overrides.delete(key.to_s)
        else
          @overrides[key.to_s] = val.to_s
        end
      end

      def add(route, param, value)
        route_str = route.to_s
        anchor = route_str.split('#')[1]&.split('?')&.first
        base_route = route_str.split('#').first
        res = _orig_add_dashboard_anchor(base_route, param, value)
        anchor && !anchor.empty? ? "#{res.split('#').first}##{anchor}" : res
      end
    end
  end
end

# Ensure GamePage does not cache stale @cursor values across history steps
module View
  class GamePage < Snabberb::Component
    def cursor
      param = Lib::Params['action']
      return param.to_i if param && !param.to_s.empty?

      nil
    end
  end
end

# frozen_string_literal: true

# backtick_javascript: true

require 'lib/params'
require 'native'
require 'lib/storage'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    module Dashboard
      class DashboardHistoryOverlay < Snabberb::Component
        include RailcardHelper

        needs :game, store: true
        needs :game_data, store: true, default: nil
        needs :show_history_overlay, store: true, default: false
        needs :app_route, store: true, default: nil
        needs :on_close, default: nil

        PLAYER_NEUTRAL_BG = '#475569'

        def total_actions
          acts = if @game_data && @game_data['actions']&.any?
                   @game_data['actions'].last['id'] || @game_data['actions'].size
                 elsif @game.respond_to?(:raw_actions) && @game.raw_actions&.any?
                   last = @game.raw_actions.last
                   if last.is_a?(Hash)
                     last['id'] || last[:id]
                   else
                     (last.respond_to?(:id) ? last.id : @game.raw_actions.size)
                   end
                 elsif @game.respond_to?(:last_game_action_id)
                   @game.last_game_action_id
                 else
                   0
                 end
          acts.to_i
        end

        def current_cursor
          param = Lib::Params['action']
          param && !param.to_s.empty? ? param.to_i : total_actions
        end

        def viewing_history?
          param = Lib::Params['action']
          !param.nil? && !param.to_s.empty? && param.to_i < total_actions
        end

        def full_log
          raw_log = @game&.log || []
          gid = (@game.respond_to?(:id) ? @game.id : (@game_data && @game_data['id'])).to_s

          if !viewing_history? && raw_log.any?
            %x{
              if (!window._dashboard_full_log_cache) window._dashboard_full_log_cache = {};
              window._dashboard_full_log_cache[#{gid}] = #{raw_log};
            }
            raw_log
          else
            cached = `(window._dashboard_full_log_cache && window._dashboard_full_log_cache[#{gid}]) || null`
            if cached && cached.length > raw_log.length
              cached
            else
              raw_log
            end
          end
        rescue StandardError
          @game&.log || []
        end

        def view_action(target_id)
          aid = target_id.to_i
          max_id = [total_actions, 1].max
          new_cursor = aid >= max_id ? nil : aid

          Lib::Params['action'] = new_cursor ? new_cursor.to_s : nil

          curr_route = @app_route
          if !curr_route || curr_route.empty?
            curr_route = `window.location.pathname + window.location.search + window.location.hash`
          end
          new_route = Lib::Params.add(curr_route, 'action', new_cursor)

          %x{
            if (window.history && window.history.replaceState) {
              window.history.replaceState(null, '', #{new_route});
            }
          }

          store(:app_route, new_route)
          %x{
            var slider = document.querySelector('#dashboard_history_floating_hud input[type="range"]');
            if (slider) slider.value = #{aid};
          }
          `window.__user_scrolled_move_hist = false;` if aid >= max_id
          scroll_to_action(aid)
        end

        def close_overlay
          view_action(total_actions) if viewing_history?
          Lib::Storage['cmd_history_overlay'] = nil
          begin
            store(:show_history_overlay, false)
          rescue StandardError
            nil
          end
          @on_close&.call
          # Do not alter style.display on the DOM node directly; allow VDOM unmount
        end

        def start_drag(e)
          %x{
            var ev = #{e} || window.event;
            if (!ev) return;

            var target = ev.target || ev.srcElement;
            if (target) {
              var tag = (target.tagName || '').toUpperCase();
              if (tag === 'BUTTON' || tag === 'INPUT' ||
                  (target.closest && target.closest('button'))) {
                return;
              }
            }

            var header = ev.currentTarget;
            var hud = header && header.parentElement;
            if (!hud) return;

            if (ev.preventDefault) ev.preventDefault();

            header.style.cursor = 'grabbing';

            var rect = hud.getBoundingClientRect();
            var shiftX = ev.clientX - rect.left;
            var shiftY = ev.clientY - rect.top;

            hud.style.position = 'fixed';
            hud.style.left = rect.left + 'px';
            hud.style.top = rect.top + 'px';
            hud.style.margin = '0';
            hud.style.transform = 'none';

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

              hud.style.left = newLeft + 'px';
              hud.style.top = newTop + 'px';
            }

            function onMouseUp() {
              document.removeEventListener('mousemove', onMouseMove, true);
              document.removeEventListener('mouseup', onMouseUp, true);
              window.removeEventListener('mousemove', onMouseMove, true);
              window.removeEventListener('mouseup', onMouseUp, true);

              header.style.cursor = 'grab';

              try {
                localStorage.setItem(
                  'move_hist_overlay_pos',
                  JSON.stringify({
                    left: hud.style.left,
                    top: hud.style.top
                  })
                );
              } catch (err) {}
            }

            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('mouseup', onMouseUp, true);
            window.addEventListener('mousemove', onMouseMove, true);
            window.addEventListener('mouseup', onMouseUp, true);
          }
        end

        def start_resize(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;
            if (ev.preventDefault) ev.preventDefault();
            if (ev.stopPropagation) ev.stopPropagation();

            var hud = document.getElementById('dashboard_history_floating_hud');
            if (!hud) return;

            var startX = ev.clientX;
            var startY = ev.clientY;
            var startW = hud.offsetWidth;
            var startH = hud.offsetHeight;
            document.body.style.userSelect = 'none';

            var onMove = function(me) {
              var maxW = window.innerWidth - 20;
              var maxH = window.innerHeight - 20;
              var newW = Math.max(300, Math.min(maxW, startW + (me.clientX - startX)));
              var newH = Math.max(250, Math.min(maxH, startH + (me.clientY - startY)));
              hud.style.width = newW + 'px';
              hud.style.height = newH + 'px';
            };

            var onUp = function() {
              window.removeEventListener('mousemove', onMove);
              window.removeEventListener('mouseup', onUp);
              document.body.style.userSelect = '';
              try {
                localStorage.setItem('move_hist_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove);
            window.addEventListener('mouseup', onUp);
          }
        end

        def scroll_to_action(aid)
          %x{
            window.__user_scrolled_move_hist = true;
            setTimeout(function() {
              var container = document.getElementById('dashboard_history_scroll_body');
              if (!container) return;
              var rows = container.querySelectorAll('[data-history-action-id]');
              var best = null, distance = Infinity;
              for (var i = 0; i < rows.length; i++) {
                var d = Math.abs(Number(rows[i].getAttribute('data-history-action-id')) - #{aid});
                if (d < distance) { best = rows[i]; distance = d; }
              }
              if (best) container.scrollTop += best.getBoundingClientRect().top - container.getBoundingClientRect().top - 12;
            }, 100);
          }
        end

        def scroll_to_latest
          return if viewing_history?

          %x{
            var container = document.getElementById('dashboard_history_scroll_body');
            if (container) {
              var isUserScrolledUp = container.scrollTop < (container.scrollHeight - container.offsetHeight - 35);
              if (!window.__user_scrolled_move_hist || !isUserScrolledUp) {
                container.scrollTop = container.scrollHeight;
              }
            }
          }
        end

        def player_color(_name)
          PLAYER_NEUTRAL_BG
        end

        def entity_badge(entity, fallback_text)
          is_corp = entity.respond_to?(:corporation?) && entity.corporation?
          is_minor = entity.respond_to?(:minor?) && entity.minor?

          if entity && (is_corp || is_minor)
            bg = entity.respond_to?(:color) && entity.color ? entity.color : '#333333'
            fg = entity.respond_to?(:text_color) && entity.text_color ? entity.text_color : '#ffffff'
            text = entity.respond_to?(:sym) ? entity.sym : entity.id
            corp_id = entity.respond_to?(:id) && entity.id ? entity.id.to_s : text.to_s
            hexes = resolve_target_hexes(entity).join(',')

            h(:div, {
                style: {
                  width: '36px',
                  height: '36px',
                  borderRadius: '50%',
                  backgroundColor: bg,
                  color: fg,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontWeight: '800',
                  fontSize: '0.85rem',
                  flexShrink: '0',
                  border: '2px solid rgba(0,0,0,0.25)',
                  boxShadow: '0 1px 3px rgba(0,0,0,0.15)',
                  cursor: 'help',
                  position: 'relative',
                },
                attrs: {
                  class: 'status-corp-wrapper cmd-corp-wrapper',
                  'data-corp': corp_id,
                  'data-hexes': hexes,
                  title: entity.respond_to?(:name) ? entity.name.to_s : text.to_s,
                },
              }, [
                text.to_s,
                render_corp_tooltip(entity),
              ].compact)
          else
            text = entity.respond_to?(:name) ? entity.name : fallback_text.to_s
            initials = text[0..1].to_s.upcase
            bg = player_color(text)

            h(:div, {
                style: {
                  width: '36px',
                  height: '36px',
                  borderRadius: '6px',
                  backgroundColor: bg,
                  color: '#ffffff',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontWeight: '800',
                  fontSize: '0.9rem',
                  flexShrink: '0',
                  border: '1px solid rgba(0,0,0,0.2)',
                  boxShadow: '0 1px 2px rgba(0,0,0,0.1)',
                  letterSpacing: '0.5px',
                },
                attrs: { title: text.to_s },
              }, initials)
          end
        end

        def entity_lookup
          @entity_lookup ||= begin
            list = []
            companies = @game.respond_to?(:companies) ? Array(@game.companies) : []
            corps = @game.respond_to?(:corporations) ? Array(@game.corporations) : []
            minors = @game.respond_to?(:minors) ? Array(@game.minors) : []
            companies.each { |c| list << { name: c.name.to_s, type: :company, entity: c, priority: 0 } if c.name }
            (corps + minors).each do |c|
              list << { name: c.name.to_s, type: :corp, entity: c, priority: 1 } if c.name
            end
            (corps + minors).each do |c|
              [c.respond_to?(:sym) ? c.sym : nil, c.respond_to?(:id) ? c.id : nil].compact.each do |label|
                next if label.to_s.match?(/\A\d+\z/)

                list << { name: label.to_s, type: :corp, entity: c, priority: 2 }
              end
            end
            companies.each do |c|
              next unless c.respond_to?(:sym) && c.sym
              next if c.sym.to_s.match?(/\A\d+\z/)

              list << { name: c.sym.to_s, type: :company, entity: c, priority: 3 }
            end
            list.reject { |item| item[:name].empty? }
                .sort_by { |item| [item[:priority], -item[:name].length] }
                .uniq { |item| item[:name].downcase }
          end
        end

        def render_entity_railcard_node(item)
          ent = item[:entity]
          if item[:type] == :corp
            render_major_railcard(ent)
          else
            label = ent.respond_to?(:sym) && ent.sym ? ent.sym.to_s : item[:name].to_s
            render_railcard(
              label,
              %w[game-card card-private],
              nil,
              build_entity_tooltip(ent),
              nil,
              nil,
              nil,
              entity: ent
            )
          end
        end

        def format_log_line_nodes(text, actor_names = [])
          clean_text = text.to_s

          Array(actor_names).each do |act|
            next if act.to_s.strip.empty?

            escaped = Regexp.escape(act.to_s)
            case clean_text
            when /^#{escaped}'s\s+share\s+price\s+/i
              clean_text = clean_text.sub(/^#{escaped}'s\s+share\s+price\s+/i, 'Share price ')
              break
            when /^#{escaped}'s\s+/i
              clean_text = clean_text.sub(/^#{escaped}'s\s+/i, '')
              break
            when /^#{escaped}\s+/i
              clean_text = clean_text.sub(/^#{escaped}\s+/i, '')
              break
            end
          end
          clean_text = clean_text[0].upcase + clean_text[1..-1] if clean_text.length.positive?

          tokens = {}
          tok_idx = 0
          next_tok = lambda do |vnode|
            key = "\u0001\u0002#{tok_idx}\u0002\u0001"
            tok_idx += 1
            tokens[key] = vnode
            key
          end

          # Resolve entities before hex and currency formatting. Placeholders protect
          # full names (including names containing numbers) from later substitutions.
          entity_lookup.each do |item|
            name = item[:name]
            next if name.length < 2 || %w[IN ON OR AT TO A AN BY OF FOR WITH].include?(name.upcase)

            pattern = Regexp.new('(?<![[:alnum:]])' + Regexp.escape(name) + '(?![[:alnum:]])',
                                 name.length <= 3 ? nil : Regexp::IGNORECASE)
            clean_text = clean_text.gsub(pattern) { next_tok.call(render_entity_railcard_node(item)) }
          end

          # 1. Tile numbers (#57, #8, etc.)
          clean_text = clean_text.gsub(/(#[A-Za-z0-9]+)/) do |m|
            next_tok.call(h(:span, { style: { color: '#64748b', fontWeight: '700' } }, m))
          end

          # 2. Currency values ($20, £180, etc.) -> Canonical FONT_MONEY & COLOR_MONEY from RailcardHelper
          clean_text = clean_text.gsub(/([$£€¥]\d+(?:[.,]\d+)?)/) do |m|
            next_tok.call(h(:strong,
                            { style: { color: COLOR_MONEY, fontFamily: FONT_MONEY, fontSize: '0.95em' } }, m))
          end

          # 3. Share percentages (10%, 20%, etc.) -> Canonical RailcardHelper share card
          clean_text = clean_text.gsub(/(\b\d+%\b)/) do |m|
            next_tok.call(render_railcard(m, %w[game-card cert-share-card]))
          end

          # 4. Only train transactions get train cards, not running trains.
          train_transaction = clean_text.match?(/\b(buys?|purchases?|sells?|sold|transfers?|exchanges?|rusts?|rusted|scraps?|discards?)\b/i)
          clean_text = clean_text.gsub(%r{\b(\d+(?:[/+]\d+|[A-Z]+)?)\s+(trains?)\b}i) do
            m = Regexp.last_match(1)
            word = Regexp.last_match(2)
            if train_transaction
              train_node = render_railcard(m, %w[game-card card-train])
              next_tok.call(h(:span,
                              { style: { display: 'inline-flex', alignItems: 'center', gap: '3px', verticalAlign: 'middle' } }, [train_node, " #{word}"]))
            else
              "#{m} #{word}"
            end
          end

          # 5. Map hex coordinates (C13, G9, etc.) -> Cyan spatial link
          hex_id_str = nil
          clean_text = clean_text.gsub(/\b([A-Z]\d{1,2})\b/) do |m|
            h_id = m
            next_tok.call(
              h(:span, {
                  attrs: { class: 'history-hex-link' },
                  style: {
                    color: '#0891b2',
                    cursor: 'pointer',
                    fontWeight: '700',
                    textDecoration: 'underline',
                    textUnderlineOffset: '2px',
                  },
                  on: {
                    mouseenter: lambda {
                      %x{
                        if (typeof window !== 'undefined' && window.highlightMapHexes) {
                          window.highlightMapHexes([#{h_id}]);
                        }
                      }
                    },
                    mouseleave: lambda {
                      %x{
                        if (typeof window !== 'undefined' && window.clearMapHexHighlights) {
                          window.clearMapHexHighlights();
                        }
                      }
                    },
                  },
                }, h_id)
            )
          end

          parts = clean_text.split(/(\u0001\u0002\d+\u0002\u0001)/)
          children = parts.reject(&:empty?).map do |part|
            tokens.key?(part) ? tokens[part] : part
          end

          is_boring = text.match?(/skips|passes|lays tile|does not run|places a token|places its destination/i)
          h(:span, {
              style: {
                color: is_boring ? '#64748b' : '#0f172a',
                fontSize: is_boring ? '0.92em' : '1em',
              },
            }, children)
        end

        def action_time_map
          @action_time_map ||= begin
            actions = (@game_data && @game_data['actions']) ||
                      (@game.respond_to?(:raw_actions) ? @game.raw_actions : nil) ||
                      []
            map = {}
            actions.each do |a|
              aid = if a.is_a?(Hash)
                      a['id'] || a[:id]
                    else
                      (a.respond_to?(:id) ? a.id : nil)
                    end
              ts = if a.is_a?(Hash)
                     a['created_at'] || a[:created_at]
                   else
                     (a.respond_to?(:created_at) ? a.created_at : nil)
                   end
              map[aid.to_i] = ts if aid && ts
            end
            map
          end
        end

        def action_entity_map
          @action_entity_map ||= begin
            map = {}
            if @game.respond_to?(:actions)
              @game.actions.each do |a|
                map[a.id] = a.entity if a.respond_to?(:id) && a.respond_to?(:entity)
              end
            end
            map
          end
        end

        def format_timestamp(ts)
          return nil unless ts

          %x{
            var t = #{ts};
            var d = null;
            if (typeof t === 'number') {
              d = new Date(t > 1e11 ? t : t * 1000);
            } else if (typeof t === 'string' && !isNaN(Date.parse(t))) {
              d = new Date(t);
            }
            if (d && !isNaN(d.getTime())) {
              var hh = String(d.getHours()).padStart(2, '0');
              var mm = String(d.getMinutes()).padStart(2, '0');
              return hh + ':' + mm;
            }
            return null;
          }
        end

        def extract_log_entry(entry)
          return { message: entry.to_s } if entry.is_a?(String)

          msg = nil
          if entry.respond_to?(:message)
            msg = entry.message
          elsif entry.respond_to?(:text)
            msg = entry.text
          elsif entry.respond_to?(:[])
            msg = entry[:message] || entry['message'] || entry[:text] || entry['text']
          end

          if msg.nil?
            msg = %x{
              (function(e) {
                if (!e) return '';
                if (typeof e === 'string') return e;
                if (typeof e.message === 'string') return e.message;
                if (typeof e.$message === 'function') return e.$message();
                if (e.message) return String(e.message);
                if (typeof e.text === 'string') return e.text;
                if (typeof e.$text === 'function') return e.$text();
                return '';
              })(#{entry})
            }
          end

          { message: msg.to_s }
        end

        def group_log_entries
          blocks = []
          current_block = nil
          time_map = action_time_map
          entity_map = action_entity_map
          round_kind = nil
          awaiting_first_operator = false

          log = full_log
          log.each do |entry|
            raw_message = entry.respond_to?(:message) ? entry.message : nil

            # Personal player messages belong exclusively in the Chat overlay.
            # Keep them completely out of the Move Feed.
            next if entry.is_a?(Engine::Action::Message) || raw_message.is_a?(Engine::Action::Message)

            info = extract_log_entry(entry)
            msg = info[:message]
            aid = entry.respond_to?(:action_id) ? entry.action_id : nil
            ts = time_map[aid.to_i] if aid
            time_str = format_timestamp(ts)

            is_divider = msg.start_with?('--') || msg.include?('-- Phase') || msg.include?('-- Event') || msg.include?('-- Stock') || msg.include?('-- Operating')

            # Also filter out string-formatted chat lines (e.g. "PlayerName: hello")
            is_chat_line = !is_divider &&
                           msg.match?(/^[a-zA-Z0-9_\s]+:\s/) &&
                           !msg.match?(/pays out|runs a|withholds|operates|buys|sells|lays|places|pars|redeems|issues|takes|declares|receives|chooses|passes|skips|bids/i)
            next if is_chat_line
            next if routine_history_line?(msg)

            if is_divider
              blocks << current_block if current_block && current_block[:lines]&.any?
              current_block = nil
              blocks << { type: :divider, text: msg }
              round_kind = if msg.match?(/Stock Round/i)
                             :stock
                           else
                             (msg.match?(/Operating Round/i) ? :operating : nil)
                           end
              awaiting_first_operator = round_kind == :operating
              next
            end

            if awaiting_first_operator && msg.match?(/\bcollects?\s+[$£€¥][\d,]+\s+from\b/i)
              if current_block && current_block[:type] == :transition && current_block[:phase] == :preparing
                current_block[:lines] << { text: msg, time: time_str, id: aid }
              else
                blocks << current_block if current_block && current_block[:lines]&.any?
                current_block = { type: :transition, phase: :preparing, lines: [{ text: msg, time: time_str, id: aid }] }
              end
              next
            end

            # End-of-stock-round adjustments are not actions of the last player.
            # Require a preceding pass, so ordinary share-price changes stay
            # attached to the actual corporation's action.
            closing_event = msg.match?(/\b(?:share price moves?|has priority deal|priority deal passes?)\b/i)
            previous_pass = current_block && current_block[:lines]&.last &&
                            current_block[:lines].last[:text].to_s.match?(/\bpasses?\b/i)
            if round_kind == :stock && closing_event &&
               (previous_pass || (current_block && current_block[:type] == :transition && current_block[:phase] == :finishing))
              if current_block[:type] == :transition && current_block[:phase] == :finishing
                current_block[:lines] << { text: msg, time: time_str, id: aid }
              else
                blocks << current_block if current_block[:lines]&.any?
                current_block = { type: :transition, phase: :finishing, lines: [{ text: msg, time: time_str, id: aid }] }
              end
              next
            end

            if (op_match = msg.match(/^(.+?)\s+operates\s+(.+)$/i))
              blocks << current_block if current_block && current_block[:lines]&.any?
              awaiting_first_operator = false
              player_name = op_match[1].strip
              corp_name = op_match[2].strip

              corp_obj = begin
                @game.corporation_by_id(corp_name) || @game.minor_by_id(corp_name)
              rescue StandardError
                nil
              end
              player_obj = begin
                @game.player_by_id(player_name)
              rescue StandardError
                nil
              end

              current_block = {
                type: :action,
                entity: corp_obj,
                operator: (player_obj ? player_obj.name : player_name),
                group_key: corp_name,
                operating: true,
                lines: [],
              }
              next
            end

            entity = entity_map[aid] if aid
            if !entity && msg
              first_word = msg.split.first
              entity = begin
                @game.corporation_by_id(first_word) || @game.minor_by_id(first_word) || @game.player_by_id(first_word) || @game.company_by_id(first_word)
              rescue StandardError
                nil
              end
            end

            group_key = entity || msg.split.first

            if current_block && current_block[:type] != :transition &&
               (current_block[:operating] || current_block[:group_key] == group_key)
              current_block[:lines] << { text: msg, time: time_str, id: aid }
            else
              blocks << current_block if current_block && current_block[:lines]&.any?
              current_block = {
                type: :action,
                entity: entity,
                operator: nil,
                group_key: group_key,
                lines: [{ text: msg, time: time_str, id: aid }],
              }
            end
          end

          blocks << current_block if current_block && current_block[:lines]&.any?
          blocks
        end

        # Compact a stock-round par and its matching initial share purchase.
        # Retain the exact price and amount; do not alter the engine log.
        def summarize_stock_lines(lines)
          output = []
          i = 0
          while i < lines.length
            first = lines[i]
            second = lines[i + 1]
            par = first[:text].match(/\A(.+?) pars (.+?) at (\$[\d,]+)\z/i)
            buy = second && second[:text].match(/\A(.+?) buys a (\d+%) share of (.+?) from the Treasury for (\$[\d,]+)\z/i)
            if par && buy && par[1] == buy[1] && par[2] == buy[3]
              output << first.merge(text: "Pars #{par[2]} at #{par[3]}; buys #{buy[2]} for #{buy[4]}",
                                    id: second[:id] || first[:id])
              i += 2
            else
              output << first
              i += 1
            end
          end
          output
        end

        def routine_history_line?(text)
          text.to_s.match?(%r{\b(?:passes? (?:buy(?:ing)? trains?|buy/use companies|place (?:a )?token|lay track|acquire companies|buy(?:ing)? shares?|purchase shares?)|skips? (?:place (?:a )?token|acquire companies|buy(?:ing)? trains?|buy/use companies|lay track)|declines? to buy shares?|does not run)\b}i)
        end

        # Transform only explicit engine-log statements. Retain the last source
        # action ID for navigation, and never calculate revenue from route counts.
        def summarize_operating_lines(lines)
          output = []
          i = 0
          while i < lines.size
            line = lines[i]
            text = line[:text].to_s
            run = text.match(%r{\A.*?\bruns? (?:an? )?[\w/+]+ trains? for ([$£€¥][\d,]+)(?:\s*:\s*.*)?\z}i) ||
                  text.match(/\A.*?\bruns? for ([$£€¥][\d,]+)(?:\s*:\s*.*)?\z/i)
            if run
              revenue = run[1]
              j = i + 1
              # Combine consecutive runs only, and only within this operating block.
              while j < lines.size
                next_run = lines[j][:text].to_s.match(%r{\A.*?\bruns? (?:an? )?[\w/+]+ trains? for ([$£€¥][\d,]+)(?:\s*:\s*.*)?\z}i) ||
                           lines[j][:text].to_s.match(/\A.*?\bruns? for ([$£€¥][\d,]+)(?:\s*:\s*.*)?\z/i)
                break unless next_run
                # A generic "runs for" line may be an engine-provided total.
                # Do not add it to individual train runs.
                break unless lines[j][:text].to_s.match?(%r{\bruns? (?:an? )?[\w/+]+ trains? for\b}i) &&
                             text.match?(%r{\bruns? (?:an? )?[\w/+]+ trains? for\b}i)
                # Sum only same-currency, explicit, separate running entries.
                break unless next_run[1][0] == revenue[0]

                revenue = revenue[0] + (revenue[1..-1].delete(',').to_i + next_run[1][1..-1].delete(',').to_i).to_s
                j += 1
              end
              summary = "Runs for #{revenue}"
              if j < lines.size
                dividend = lines[j][:text].to_s
                if (pay = dividend.match(/\bpays? out ([$£€¥][\d,]+)/i))
                  summary += ", pays out #{pay[1]}"
                  j += 1
                elsif dividend.match?(/\bpays? half\b/i)
                  summary += ', pays half'
                  j += 1
                elsif dividend.match?(/\bwithholds?\b/i)
                  summary += ', withholds'
                  j += 1
                end
              end
              output << line.merge(text: summary, id: lines[j - 1][:id] || line[:id])
              i = j
            else
              # Make explicit share-price changes compact, without inferring dividends.
              price = text.match(/\bshare price moves? (?:right|left|up|down) from ([$£€¥][\d,]+) to ([$£€¥][\d,]+)/i)
              output << (price ? line.merge(text: "Share price #{price[1]} → #{price[2]}") : line)
              i += 1
            end
          end
          output
        end

        def render_blocks
          blocks = group_log_entries

          if blocks.empty?
            return [
              h(:div, {
                  style: {
                    padding: '2rem 1rem',
                    color: '#64748b',
                    textAlign: 'center',
                    fontStyle: 'italic',
                    fontSize: '0.85rem',
                  },
                }, 'No moves recorded yet.'),
            ]
          end

          nodes = blocks.map.with_index do |block, _idx|
            if block[:type] == :divider
              clean_text = block[:text].gsub('--', '').strip
              h(:div, {
                  style: {
                    position: 'sticky',
                    top: '-1px',
                    zIndex: '10',
                    backgroundColor: '#0f172a',
                    borderTop: '2px solid #1e293b',
                    borderBottom: '2px solid #1e293b',
                    padding: '6px 8px',
                    margin: '12px 0 8px 0',
                    textAlign: 'center',
                    fontWeight: 'bold',
                    fontSize: '0.9rem',
                    color: '#f8fafc',
                    boxShadow: '0 2px 6px rgba(0,0,0,0.15)',
                    letterSpacing: '0.5px',
                  },
                }, clean_text)

            else
              transition_block = block[:type] == :transition
              player_block = transition_block || (block[:entity] && block[:entity].respond_to?(:player?) && block[:entity].player?)
              badge = transition_block || player_block ? nil : entity_badge(block[:entity], block[:group_key])
              actor_label = if transition_block
                              block[:phase] == :preparing ? 'Preparing operating round · Private income' : 'Finishing stock round · Adjustments'
                            else
                              (block[:entity].respond_to?(:name) ? block[:entity].name : block[:group_key]).to_s
                            end
              if !player_block && block[:entity] && block[:entity].respond_to?(:sym) &&
                 actor_label == block[:entity].sym.to_s
                actor_label = ''
              end

              operator = block[:operator]
              operator = block[:entity].owner.name if !operator && block[:entity].respond_to?(:owner) && block[:entity].owner

              actor_names = []
              actor_names << operator if operator
              if block[:entity]
                actor_names << block[:entity].sym if block[:entity].respond_to?(:sym)
                actor_names << block[:entity].id if block[:entity].respond_to?(:id)
                actor_names << block[:entity].name if block[:entity].respond_to?(:name)
              end
              actor_names << block[:group_key] if block[:group_key]
              actor_names = actor_names.compact.map(&:to_s).reject(&:empty?).uniq.sort_by { |s| -s.length }

              lines = block[:lines] || []
              lines = summarize_stock_lines(lines)
              lines = summarize_operating_lines(lines) if block[:operating]
              line_nodes = lines.map do |line|
                time_node = if line[:time]
                              h(:span, {
                                  style: {
                                    color: '#94a3b8',
                                    fontSize: '0.75rem',
                                    marginRight: '6px',
                                    userSelect: 'none',
                                    fontWeight: '500',
                                  },
                                }, "[#{line[:time]}]")
                            end
                body_node = format_log_line_nodes(line[:text], actor_names)
                h(:div, { style: { marginBottom: '3px', display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: '2px' } },
                  [time_node, body_node].compact)
              end

              last_line = lines.last
              last_id = last_line ? last_line[:id] : nil
              id_str = last_id ? "##{last_id}" : ''

              header_title_nodes = [
                h(:strong, { style: { fontSize: '0.95rem', color: '#0f172a', marginRight: '6px' } }, actor_label),
              ]
              if operator && !player_block
                header_title_nodes << h(:span, { style: { fontSize: '0.8rem', fontWeight: '600', color: '#334155' } },
                                        " | #{operator}")
              end

              action_controls = []
              action_controls << h(:span, { style: { fontSize: '0.72rem', color: '#94a3b8', fontWeight: 'bold' } }, id_str)

              if last_id
                aid_num = last_id.to_i
                is_current = current_cursor == aid_num

                action_controls << h(:button, {
                                       attrs: { type: 'button', title: "View board at Action ##{aid_num}" },
                                       style: {
                                         padding: '1px 5px',
                                         fontSize: '0.68rem',
                                         fontWeight: '600',
                                         backgroundColor: is_current ? '#2563eb' : '#f1f5f9',
                                         color: is_current ? '#ffffff' : '#334155',
                                         border: '1px solid #cbd5e1',
                                         borderRadius: '3px',
                                         cursor: 'pointer',
                                         lineHeight: '1.2',
                                         boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                                       },
                                       on: {
                                         click: lambda { |e|
                                           %x{
                        if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();
                      }
                                           view_action(aid_num)
                                         },
                                       },
                                     }, is_current ? 'Viewing' : 'View here')

              end

              action_header_right = h(:div, { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, action_controls)

              h(:div, {
                  attrs: { 'data-history-action-id': last_id.to_s },
                  style: {
                    display: 'flex',
                    flexDirection: 'row',
                    gap: '10px',
                    backgroundColor: '#ffffff',
                    borderRadius: '8px',
                    padding: '10px',
                    marginBottom: '10px',
                    border: '1px solid #cbd5e1',
                    boxShadow: '0 2px 4px rgba(0,0,0,0.04)',
                  },
                }, [
                (player_block ? h(:span, { style: { display: 'none' } }, '') : h(:div, { style: { flexShrink: '0' } }, [badge])),
                h(:div, { style: { flex: '1', minWidth: '0' } }, [
                  h(:div, {
                      style: {
                        display: 'flex',
                        justifyContent: 'space-between',
                        alignItems: 'center',
                        marginBottom: '5px',
                        borderBottom: '1px solid #f1f5f9',
                        paddingBottom: '4px',
                      },
                    }, [
                    h(:div, { style: { display: 'flex', alignItems: 'center', flexWrap: 'wrap' } }, header_title_nodes),
                    action_header_right,
                  ]),
                  h(:div, {
                      style: { fontSize: '0.85rem', lineHeight: '1.45', wordBreak: 'break-word' },
                    }, line_nodes.empty? ? [h(:span, { style: { color: '#94a3b8', fontStyle: 'italic' } }, 'Operating...')] : line_nodes),
                ]),
              ])
            end
          end

          nodes << h(:div, { style: { height: '10px' } }, '')
          nodes
        end

        # // --- START FIX ---
        def render_history_banner
          nil
        end

        def render_timeline
          total = total_actions
          current = current_cursor
          button = {
            padding: '5px 9px',
            backgroundColor: '#ffffff',
            border: '1px solid #cbd5e1',
            borderRadius: '4px',
            cursor: 'pointer',
            fontWeight: 'bold',
          }
          h(:div, { style: { padding: '8px 12px', backgroundColor: '#ffffff', borderBottom: '1px solid #cbd5e1', flexShrink: '0' } }, [
            h(:div, { style: { display: 'flex', gap: '6px', alignItems: 'center', flexWrap: 'wrap' } }, [
              h(:button, {
                  style: button,
                  attrs: { type: 'button', disabled: current <= 1, title: 'Previous action' },
                  on: {
                    click: lambda {
                      view_action([current - 1, 1].max)
                    },
                  },
                }, '◀'),
              h(:button, {
                  style: button,
                  attrs: { type: 'button', disabled: current >= total, title: 'Next action' },
                  on: {
                    click: lambda {
                      view_action([current + 1, total].min)
                    },
                  },
                }, '▶'),
              h(:span, { style: { fontSize: '0.82rem', fontWeight: 'bold', color: '#334155' } }, "Action #{current} / #{total}"),
              h(:button, {
                  style: button.merge(marginLeft: 'auto', backgroundColor: '#dbeafe', color: '#1d4ed8'),
                  attrs: { type: 'button' },
                  on: {
                    click: lambda {
                      view_action(total)
                    },
                  },
                }, 'Return to Live'),
            ]),
            h(:input, {
                attrs: { type: 'range', min: 1, max: [total, 1].max, value: current, 'aria-label': 'Browse game actions' },
                style: { width: '100%', marginTop: '8px' },
                on: {
                  change: lambda { |e|
                    view_action(`#{e}.target.value`.to_i)
                  },
                },
              }),
          ])
        end

        def render
          saved_pos = %x{
            (function() {
              try {
                var p = JSON.parse(localStorage.getItem('move_hist_overlay_pos'));
                if (p && typeof p.left === 'string' && typeof p.top === 'string') {
                  var leftNum = parseFloat(p.left);
                  var topNum = parseFloat(p.top);
                  if (!isNaN(leftNum) && !isNaN(topNum) &&
                      leftNum >= 10 && leftNum <= (window.innerWidth - 120) &&
                      topNum >= 10 && topNum <= (window.innerHeight - 80)) {
                    return p;
                  }
                  localStorage.removeItem('move_hist_overlay_pos');
                }
              } catch(e) {}
              return null;
            })()
          }
          pos_native = Native(saved_pos) if saved_pos
          has_pos = pos_native && pos_native['left'] && pos_native['top']

          saved_size = %x{
            (function() {
              try {
                var s = JSON.parse(localStorage.getItem('move_hist_overlay_size'));
                if (s && typeof s.width === 'string' && typeof s.height === 'string' && s.width.indexOf('px') !== -1 && s.height.indexOf('px') !== -1) {
                  return s;
                }
              } catch(e) {}
              return null;
            })()
          }
          size_native = Native(saved_size) if saved_size
          has_size = size_native && size_native['width'] && size_native['height']

          feed_blocks = group_log_entries
          moves_count = feed_blocks.count { |b| b[:type] == :action }

          hud_style = {
            position: 'fixed',
            top: has_pos ? pos_native['top'] : '70px',
            left: has_pos ? pos_native['left'] : 'calc(100vw - 460px)',
            width: has_size ? size_native['width'] : '440px',
            height: has_size ? size_native['height'] : '560px',
            maxWidth: '96vw',
            maxHeight: '92vh',
            minWidth: '300px',
            minHeight: '250px',
            backgroundColor: '#f8fafc',
            borderRadius: '10px',
            boxShadow: '0 16px 32px -8px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(0, 0, 0, 0.15)',
            border: '1px solid #94a3b8',
            zIndex: '999999',
            pointerEvents: 'auto',
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
            resize: 'both',
            userSelect: 'none',
          }

          # // --- START FIX ---
          hud_children = [
            h('div#dashboard_history_hud_handle', {
                style: {
                  padding: '0.6rem 0.9rem',
                  backgroundColor: '#e2e8f0',
                  borderBottom: '1px solid #cbd5e1',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  cursor: 'grab',
                  flexShrink: '0',
                },
                on: {
                  mousedown: ->(e) { start_drag(e) },
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', pointerEvents: 'none' } }, [
                h(:span, { style: { fontSize: '1rem', color: '#64748b' } }, '⠿'),
                h(:h3, { style: { margin: '0', fontSize: '0.95rem', color: '#0f172a', fontWeight: '800' } }, 'Game History'),
                h(:span, {
                    style: {
                      fontSize: '0.72rem',
                      padding: '2px 6px',
                      borderRadius: '12px',
                      backgroundColor: '#cbd5e1',
                      color: '#1e293b',
                      fontWeight: 'bold',
                    },
                  }, "#{moves_count} Events"),
              ]),
              h(:button, {
                  attrs: { id: 'btn_close_dashboard_history_overlay', type: 'button', title: 'Close History' },
                  style: {
                    background: 'none',
                    border: 'none',
                    fontSize: '1.3rem',
                    color: '#64748b',
                    cursor: 'pointer',
                    padding: '2px 6px',
                    borderRadius: '4px',
                    lineHeight: '1',
                  },
                  on: {
                    click: lambda { |e|
                      %x{
                        if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();
                      }
                      close_overlay
                    },
                  },
                }, '✕'),
            ]),

            render_timeline,
            render_history_banner,

            h('div#dashboard_history_scroll_body', {
                style: {
                  flex: '1',
                  overflowY: 'auto',
                  backgroundColor: '#f8fafc',
                  userSelect: 'text',
                  display: 'flex',
                  flexDirection: 'column',
                  padding: '0 12px',
                },
                on: {
                  scroll: lambda { |e|
                    %x{
                      var target = #{e}.target;
                      if (target) {
                        window.__user_scrolled_move_hist = target.scrollTop < (target.scrollHeight - target.offsetHeight - 45);
                      }
                    }
                  },
                },
              }, render_blocks),

            h('div#dashboard_history_resize_grip', {
                style: {
                  position: 'absolute',
                  right: '2px',
                  bottom: '2px',
                  width: '14px',
                  height: '14px',
                  cursor: 'nwse-resize',
                  display: 'flex',
                  alignItems: 'flex-end',
                  justifyContent: 'flex-end',
                  opacity: '0.5',
                  pointerEvents: 'auto',
                  zIndex: '20',
                },
                on: {
                  mousedown: ->(e) { start_resize(e) },
                },
              }, [
              h(:svg, {
                  attrs: {
                    width: '10',
                    height: '10',
                    viewBox: '0 0 10 10',
                  },
                  style: { display: 'block', pointerEvents: 'none' },
                }, [
                h(:line,
                  attrs: {
                    x1: '9',
                    y1: '1',
                    x2: '1',
                    y2: '9',
                    stroke: '#475569',
                    'stroke-width': '1.5',
                    'stroke-linecap': 'round',
                  }),
                h(:line,
                  attrs: {
                    x1: '9',
                    y1: '5',
                    x2: '5',
                    y2: '9',
                    stroke: '#475569',
                    'stroke-width': '1.5',
                    'stroke-linecap': 'round',
                  }),
              ]),
            ]),
          ].compact
          # // --- END FIX ---

          h('div#dashboard_history_floating_hud', {
              style: hud_style,
              hook: {
                insert: lambda {
                  `window.__user_scrolled_move_hist = false;`
                  view_action(total_actions) if viewing_history?
                  scroll_to_latest
                },
                postpatch: -> { scroll_to_latest },
              },
              on: {
                mouseup: lambda {
                  %x{
                    var hud = document.getElementById('dashboard_history_floating_hud');
                    if (hud && hud.style.width && hud.style.height) {
                      try {
                        localStorage.setItem('move_hist_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
                      } catch(e) {}
                    }
                  }
                },
              },
              # // --- DELETE --- }, [
              # // --- DELETE ---   h('div#dashboard_history_hud_handle', ...),
              # // --- DELETE ---   (if viewing_history? ... end),
              # // --- DELETE ---   h('div#dashboard_history_scroll_body', ...),
              # // --- DELETE ---   h('div#dashboard_history_resize_grip', ...),
              # // --- DELETE --- ])
              # // --- START FIX ---
            }, hud_children)
          # // --- END FIX ---
        end
      end
    end
  end
end
