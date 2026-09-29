# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/storage'
require 'view/game/dashboard/railcard_helper'

module View
  module Game
    module Dashboard
      class MoveHistoryOverlay < Snabberb::Component
        include RailcardHelper

        needs :game, store: true
        needs :game_data, store: true, default: nil
        needs :show_move_history, store: true, default: true
        needs :on_close, default: nil

        PLAYER_PALETTE = ['#0284c7', '#16a34a', '#d97706', '#dc2626', '#7c3aed', '#db2777', '#0d9488', '#ea580c'].freeze

        def close_overlay
          Lib::Storage['cmd_move_history_overlay'] = nil
          begin
            store(:show_move_history, false)
          rescue StandardError
            nil
          end
          @on_close&.call
          %x{
            var hud = document.getElementById('move_history_floating_hud');
            if (hud) hud.style.display = 'none';
          }
        end

        def start_drag(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;

            var target = ev.target || ev.srcElement;
            if (target && (target.tagName === 'BUTTON' || (target.closest && target.closest('button')))) {
              return;
            }
            if (ev.preventDefault) ev.preventDefault();

            var hud = document.getElementById('move_history_floating_hud');
            if (!hud) return;

            var rect = hud.getBoundingClientRect();
            var startX = ev.clientX;
            var startY = ev.clientY;
            var origLeft = rect.left;
            var origTop = rect.top;

            hud.style.transform = 'none';
            hud.style.left = origLeft + 'px';
            hud.style.top = origTop + 'px';
            hud.style.right = 'auto';
            hud.style.bottom = 'auto';
            hud.style.margin = '0';
            document.body.style.userSelect = 'none';

            var onMove = function(me) {
              if (me.preventDefault) me.preventDefault();
              var dx = me.clientX - startX;
              var dy = me.clientY - startY;
              var maxLeft = window.innerWidth - hud.offsetWidth - 10;
              var maxTop = window.innerHeight - hud.offsetHeight - 10;
              var newLeft = Math.max(10, Math.min(maxLeft, origLeft + dx));
              var newTop = Math.max(10, Math.min(maxTop, origTop + dy));
              hud.style.left = newLeft + 'px';
              hud.style.top = newTop + 'px';
            };

            var onUp = function() {
              window.removeEventListener('mousemove', onMove, true);
              window.removeEventListener('mouseup', onUp, true);
              document.body.style.userSelect = '';
              try {
                localStorage.setItem('move_hist_overlay_pos', JSON.stringify({ left: hud.style.left, top: hud.style.top }));
              } catch(err) {}
            };

            window.addEventListener('mousemove', onMove, true);
            window.addEventListener('mouseup', onUp, true);
          }
        end

        def start_resize(e)
          %x{
            var ev = #{e};
            if (ev && ev.native) ev = ev.native;
            if (!ev || ev.button !== 0) return;
            if (ev.preventDefault) ev.preventDefault();
            if (ev.stopPropagation) ev.stopPropagation();

            var hud = document.getElementById('move_history_floating_hud');
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

        def scroll_to_latest
          %x{
            var container = document.getElementById('move_history_scroll_body');
            if (container) {
              var isUserScrolledUp = container.scrollTop < (container.scrollHeight - container.offsetHeight - 35);
              if (!window.__user_scrolled_move_hist || !isUserScrolledUp) {
                container.scrollTop = container.scrollHeight;
              }
            }
          }
        end

        def player_color(name)
          if @game.respond_to?(:players) && @game.players
            idx = @game.players.index { |p| p.name.to_s == name.to_s || p.id.to_s == name.to_s }
            return PLAYER_PALETTE[idx % PLAYER_PALETTE.size] if idx
          end

          hash = 0
          name.to_s.each_char { |c| hash = c.ord + ((hash << 5) - hash) }
          PLAYER_PALETTE[hash.abs % PLAYER_PALETTE.size]
        end

        def entity_badge(entity, fallback_text)
          is_corp = entity.respond_to?(:corporation?) && entity.corporation?
          is_minor = entity.respond_to?(:minor?) && entity.minor?

          if entity && (is_corp || is_minor)
            bg = entity.respond_to?(:color) && entity.color ? entity.color : '#333333'
            fg = entity.respond_to?(:text_color) && entity.text_color ? entity.text_color : '#ffffff'
            text = entity.respond_to?(:sym) ? entity.sym : entity.id

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
                },
                attrs: { title: entity.respond_to?(:name) ? entity.name.to_s : text.to_s },
              }, text.to_s)
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
            if @game.respond_to?(:companies) && @game.companies
              @game.companies.each do |c|
                list << { name: c.name.to_s, type: :company, entity: c } if c.name
                list << { name: c.sym.to_s, type: :company, entity: c } if c.respond_to?(:sym) && c.sym && c.sym != c.name
              end
            end
            if @game.respond_to?(:corporations) && @game.corporations
              @game.corporations.each do |c|
                list << { name: c.name.to_s, type: :corp, entity: c } if c.name
                list << { name: c.id.to_s, type: :corp, entity: c } if c.id
                list << { name: c.sym.to_s, type: :corp, entity: c } if c.respond_to?(:sym) && c.sym && c.sym != c.name
              end
            end
            if @game.respond_to?(:minors) && @game.minors
              @game.minors.each do |m|
                list << { name: m.name.to_s, type: :corp, entity: m } if m.name
                list << { name: m.id.to_s, type: :corp, entity: m } if m.id
              end
            end
            list.uniq { |item| item[:name] }.sort_by { |item| -item[:name].length }
          end
        end

        def company_tooltip_html(c)
          name = c.name.to_s
          desc = c.desc.to_s
          desc = c.abilities.map(&:description).compact.join(' ') if desc.empty? && c.respond_to?(:abilities) && c.abilities
          val = @game.format_currency(c.value || 0)
          rev = @game.format_currency(c.revenue || 0)
          owner = c.owner&.name || 'Bank'
          hexes = resolve_target_hexes(c).join(',')

          "<div class=\"status-company-tooltip cmd-company-tooltip\" data-hexes=\"#{hexes}\" style=\"display:none;\">" \
            '<div style="background-color:#ffff00;border:1px solid #000;font-weight:bold;font-size:0.8rem;text-align:center;padding:2px 4px;margin-bottom:4px;text-transform:uppercase;border-radius:3px;color:#000;">Private Company</div>' \
            "<div style=\"font-weight:bold;font-size:0.95rem;text-align:center;margin-bottom:4px;color:#111;\">#{name}</div>" \
            "<div style=\"font-size:0.8rem;line-height:1.3;margin-bottom:8px;color:#333;\">#{desc}</div>" \
            '<div style="display:flex;justify-content:space-between;font-size:0.8rem;font-weight:bold;border-top:1px solid #ddd;padding-top:4px;margin-bottom:2px;color:#111;">' \
            "<span>Value: <strong style=\"color:#4c1d95;font-family:'Courier New',Courier,monospace;\">#{val}</strong></span>" \
            "<span>Revenue: <strong style=\"color:#4c1d95;font-family:'Courier New',Courier,monospace;\">#{rev}</strong></span>" \
            '</div>' \
            "<div style=\"font-size:0.78rem;font-weight:bold;text-align:center;color:#666;\">Owner: #{owner}</div>" \
            '</div>'
        end

        def corp_tooltip_html(corp)
          return '' unless corp

          name = corp.respond_to?(:name) ? corp.name.to_s : ''
          sym = if corp.respond_to?(:sym) && corp.sym
                  corp.sym.to_s
                else
                  (corp.respond_to?(:id) ? corp.id.to_s : name)
                end
          bg = corp.respond_to?(:color) && corp.color ? corp.color : '#333333'
          fg = corp.respond_to?(:text_color) && corp.text_color ? corp.text_color : '#ffffff'
          price = corp.respond_to?(:share_price) && corp.share_price ? @game.format_currency(corp.share_price.price) : 'Unparred'
          par = corp.respond_to?(:par_price) && corp.par_price ? @game.format_currency(corp.par_price.price) : 'N/A'
          cash = corp.respond_to?(:cash) && corp.cash ? @game.format_currency(corp.cash) : @game.format_currency(0)
          owner = corp.respond_to?(:owner) && corp.owner ? corp.owner.name : 'None'
          trains = corp.respond_to?(:trains) && corp.trains && corp.trains.any? ? corp.trains.map(&:name).join(', ') : 'None'
          tokens = if corp.respond_to?(:tokens) && corp.tokens
                     "#{corp.tokens.count(&:used)} / #{corp.tokens.size}"
                   else
                     'N/A'
                   end
          hexes = resolve_target_hexes(corp).join(',')

          "<div class=\"status-corp-tooltip cmd-corp-tooltip\" data-hexes=\"#{hexes}\" style=\"display:none;\">" \
            "<div style=\"background-color:#{bg};color:#{fg};font-weight:bold;font-size:0.85rem;text-align:center;padding:4px;margin-bottom:6px;border-radius:4px;letter-spacing:0.5px;\">#{sym} - #{name}</div>" \
            '<div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;font-size:0.8rem;margin-bottom:4px;color:#111;">' \
            "<div>Price: <strong style=\"color:#4c1d95;font-family:'Courier New',Courier,monospace;\">#{price}</strong></div>" \
            "<div>Par: <strong style=\"color:#4c1d95;font-family:'Courier New',Courier,monospace;\">#{par}</strong></div>" \
            "<div>Treasury: <strong style=\"color:#4c1d95;font-family:'Courier New',Courier,monospace;\">#{cash}</strong></div>" \
            "<div>Owner: <strong>#{owner}</strong></div>" \
            "<div>Trains: <strong>#{trains}</strong></div>" \
            "<div>Tokens: <strong>#{tokens}</strong></div>" \
            '</div>' \
            '</div>'
        end

        def entity_railcard_html(item)
          if item[:type] == :corp
            corp = item[:entity]
            bg = corp.respond_to?(:color) && corp.color ? corp.color : '#4169e1'
            fg = corp.respond_to?(:text_color) && corp.text_color ? corp.text_color : '#ffffff'
            label = corp.respond_to?(:sym) && corp.sym ? corp.sym : item[:name]

            '<span class="status-corp-wrapper cmd-corp-wrapper" style="display:inline-flex;position:relative;vertical-align:baseline;cursor:pointer;margin:0 2px;">' \
              "<span style=\"display:inline-flex;align-items:center;justify-content:center;height:1.35rem;padding:0 6px;border-radius:3px;font-weight:800;font-size:0.78rem;background-color:#{bg};color:#{fg};border:1px solid rgba(0,0,0,0.35);line-height:1;letter-spacing:0.3px;box-shadow:0 1px 2px rgba(0,0,0,0.1);\">#{label}</span>" \
              "#{corp_tooltip_html(corp)}" \
              '</span>'
          else
            c = item[:entity]
            name = item[:name]

            '<span class="status-company-wrapper cmd-company-wrapper" style="display:inline-flex;position:relative;vertical-align:baseline;cursor:pointer;margin:0 2px;">' \
              "<span style=\"display:inline-flex;align-items:center;justify-content:center;height:1.35rem;padding:0 6px;border-radius:3px;font-weight:700;font-size:0.76rem;background-color:#fdfbf7;color:#1e293b;border:1px solid #78716c;line-height:1;box-shadow:0 1px 2px rgba(0,0,0,0.06);font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;\">#{name}</span>" \
              "#{company_tooltip_html(c)}" \
              '</span>'
          end
        end

        def format_log_line(text, actor_names = [])
          clean_text = text.to_s

          Array(actor_names).each do |act|
            next if act.to_s.strip.empty?

            escaped = Regexp.escape(act.to_s)
            if clean_text.match?(/^#{escaped}'s\s+share\s+price\s+/i)
              clean_text = clean_text.sub(/^#{escaped}'s\s+share\s+price\s+/i, 'Share price ')
              break
            elsif clean_text.match?(/^#{escaped}'s\s+/i)
              clean_text = clean_text.sub(/^#{escaped}'s\s+/i, '')
              break
            elsif clean_text.match?(/^#{escaped}\s+/i)
              clean_text = clean_text.sub(/^#{escaped}\s+/i, '')
              break
            end
          end
          clean_text = clean_text[0].upcase + clean_text[1..-1] if clean_text.length.positive?

          tokens = {}
          tok_idx = 0

          clean_text = clean_text.gsub(/(#[A-Za-z0-9]+)/) do |m|
            token = "@@TOK_#{tok_idx}@@"
            tok_idx += 1
            tokens[token] = "<span style=\"color: #64748b; font-weight: 600;\">#{m}</span>"
            token
          end

          clean_text = clean_text.gsub(/([$£€¥]\d+(?:[.,]\d+)?)/) do |m|
            token = "@@TOK_#{tok_idx}@@"
            tok_idx += 1
            tokens[token] =
              "<strong style=\"color: #4c1d95; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 0.95em;\">#{m}</strong>"
            token
          end

          clean_text = clean_text.gsub(/(\b\d+%\b)/) do |m|
            token = "@@TOK_#{tok_idx}@@"
            tok_idx += 1
            tokens[token] = "<span style=\"color: #0f172a; font-weight: 700;\">#{m}</span>"
            token
          end

          clean_text = clean_text.gsub(/\b(\d+[A-Z]?)\s+train\b/i) do
            m = Regexp.last_match(1)
            token = "@@TOK_#{tok_idx}@@"
            tok_idx += 1
            tokens[token] =
              "<span class=\"game-card card-train\" style=\"display:inline-flex;align-items:center;justify-content:center;height:1.35rem;min-width:2.2rem;padding:0 6px;border-radius:12px;font-weight:800;font-size:0.8rem;background-color:#fdfbf7;color:#000000;border:2px solid #78716c;vertical-align:baseline;margin:0 3px;line-height:1;box-shadow:0 1px 2px rgba(0,0,0,0.06);font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;\">#{m}</span> train"
            token
          end

          clean_text = clean_text.gsub(/\b([A-Z]\d{1,2})\b/) do |m|
            token = "@@TOK_#{tok_idx}@@"
            tok_idx += 1
            tokens[token] =
              "<span class=\"history-hex-link\" style=\"color: #0284c7; cursor: pointer; font-weight: 700; text-decoration: underline; text-underline-offset: 2px;\" onmouseenter=\"if(window.highlightMapHexes) window.highlightMapHexes(['#{m}'])\" onmouseleave=\"if(window.clearMapHexHighlights) window.clearMapHexHighlights()\">#{m}</span>"
            token
          end

          entity_lookup.each do |item|
            name = item[:name]
            next if name.nil? || name.empty?
            next if %w[IN ON OR AT TO A AN BY OF FOR WITH].include?(name.upcase) && name.length <= 2

            flags = name.length <= 3 ? nil : 'i'
            pattern = Regexp.new('(?:\b)' + Regexp.escape(name) + '(?:\b)', flags)

            next unless clean_text.match?(pattern)

            clean_text = clean_text.gsub(pattern) do
              token = "@@TOK_#{tok_idx}@@"
              tok_idx += 1
              tokens[token] = entity_railcard_html(item)
              token
            end
          end

          html = clean_text.gsub(/&/, '&amp;').gsub(/</, '&lt;').gsub(/>/, '&gt;')
          tokens.each do |tok, replacement|
            html = html.gsub(tok, replacement)
          end

          is_boring = text.match?(/skips|passes|lays tile|does not run|places a token|places its destination/i)
          if is_boring
            "<span style=\"color: #64748b; font-size: 0.92em;\">#{html}</span>"
          else
            "<span style=\"color: #0f172a;\">#{html}</span>"
          end
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

          log = @game&.log || []
          log.each do |entry|
            info = extract_log_entry(entry)
            msg = info[:message]
            aid = entry.respond_to?(:action_id) ? entry.action_id : nil
            ts = time_map[aid.to_i] if aid
            time_str = format_timestamp(ts)

            is_divider = msg.start_with?('--') || msg.include?('-- Phase') || msg.include?('-- Event') || msg.include?('-- Stock') || msg.include?('-- Operating')

            is_chat = false
            if entry.is_a?(Engine::Action::Message)
              is_chat = true
            elsif msg.match?(/^[a-zA-Z0-9_\s]+: /) && !msg.match?(/pays out/i) && !msg.match?(/runs a/i)
              is_chat = true
            end

            if is_divider
              blocks << current_block if current_block && current_block[:lines]&.any?
              current_block = nil
              blocks << { type: :divider, text: msg }
              next
            end

            if is_chat
              blocks << current_block if current_block && current_block[:lines]&.any?
              current_block = nil

              if entry.is_a?(Engine::Action::Message)
                sender = entry.entity.name || 'Player'
                chat_msg = entry.message
              else
                sender, chat_msg = msg.split(': ', 2)
              end

              blocks << { type: :chat, sender: sender, text: chat_msg, time: time_str }
              next
            end

            if (op_match = msg.match(/^(.+?)\s+operates\s+(.+)$/i))
              blocks << current_block if current_block && current_block[:lines]&.any?
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
                lines: [],
              }
              next
            end

            entity = entity_map[aid] if aid
            if !entity && msg
              first_word = msg.split(' ').first
              entity = begin
                @game.corporation_by_id(first_word) || @game.minor_by_id(first_word) || @game.player_by_id(first_word) || @game.company_by_id(first_word)
              rescue StandardError
                nil
              end
            end

            group_key = entity || msg.split(' ').first

            if current_block && current_block[:group_key] == group_key
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
              clean_text = block[:text].gsub(/--/, '').strip
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
            elsif block[:type] == :chat
              time_str = block[:time] ? "[#{block[:time]}] " : ''
              h(:div, {
                  style: {
                    display: 'flex',
                    flexDirection: 'row',
                    justifyContent: 'flex-end',
                    marginBottom: '10px',
                    padding: '0 8px',
                  },
                }, [
                h(:div, {
                    style: {
                      backgroundColor: '#2563eb',
                      color: '#ffffff',
                      borderRadius: '14px 14px 0 14px',
                      padding: '8px 14px',
                      fontSize: '0.88rem',
                      maxWidth: '85%',
                      boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
                      lineHeight: '1.4',
                    },
                  }, [
                  h(:div,
                    { style: { fontSize: '0.65rem', color: '#bfdbfe', marginBottom: '3px', textAlign: 'right', fontWeight: 'bold' } }, "#{time_str}#{block[:sender]}"),
                  h(:div, {}, block[:text]),
                ]),
              ])
            else
              badge = entity_badge(block[:entity], block[:group_key])
              actor_label = (if block[:entity].respond_to?(:sym)
                               block[:entity].sym
                             else
                               (block[:entity].respond_to?(:name) ? block[:entity].name : block[:group_key])
                             end).to_s

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
              lines_html = lines.map do |line|
                time_str = line[:time] ? "<span style=\"color: #94a3b8; font-size: 0.75rem; margin-right: 6px; user-select: none; font-weight: 500;\">[#{line[:time]}]</span>" : ''
                formatted_body = format_log_line(line[:text], actor_names)
                "<div style=\"margin-bottom: 3px;\">#{time_str}#{formatted_body}</div>"
              end.join('')

              last_line = lines.last
              last_id = last_line ? last_line[:id] : nil
              id_str = last_id ? "##{last_id}" : ''

              header_title_nodes = [
                h(:strong, { style: { fontSize: '0.95rem', color: '#0f172a', marginRight: '6px' } }, actor_label),
              ]
              if operator
                p_color = player_color(operator)
                p_initials = operator[0..1].to_s.upcase
                header_title_nodes << h(:div, {
                                          style: {
                                            display: 'inline-flex',
                                            alignItems: 'center',
                                            gap: '5px',
                                            backgroundColor: '#f1f5f9',
                                            padding: '2px 6px',
                                            borderRadius: '4px',
                                            border: '1px solid #e2e8f0',
                                            marginLeft: '4px',
                                          },
                                        }, [
                  h(:div, {
                      style: {
                        width: '18px',
                        height: '18px',
                        borderRadius: '3px',
                        backgroundColor: p_color,
                        color: '#ffffff',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: '0.65rem',
                        fontWeight: '800',
                        lineHeight: '1',
                      },
                    }, p_initials),
                  h(:span, { style: { fontSize: '0.8rem', fontWeight: '600', color: '#334155' } }, operator),
                ])
              end

              h(:div, {
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
                h(:div, { style: { flexShrink: '0' } }, [badge]),
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
                    h(:span, { style: { fontSize: '0.72rem', color: '#94a3b8', fontWeight: 'bold' } }, id_str),
                  ]),
                  h(:div, {
                      props: { innerHTML: lines_html.empty? ? '<span style="color: #94a3b8; font-style: italic;">Operating...</span>' : lines_html },
                      style: { fontSize: '0.85rem', lineHeight: '1.45', wordBreak: 'break-word' },
                    }),
                ]),
              ])
            end
          end

          nodes << h(:div, { style: { height: '10px' } }, '')
          nodes
        end

        def render
          saved_pos = %x{
            (function() {
              try {
                var p = JSON.parse(localStorage.getItem('move_hist_overlay_pos'));
                if (p && typeof p.left === 'string' && typeof p.top === 'string' && p.left.indexOf('px') !== -1 && p.top.indexOf('px') !== -1) {
                  return p;
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

          moves_count = @game&.log&.size || 0

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

          h('div#move_history_floating_hud', {
              style: hud_style,
              hook: {
                insert: -> { scroll_to_latest },
                postpatch: -> { scroll_to_latest },
              },
              on: {
                mouseup: lambda {
                  %x{
                    var hud = document.getElementById('move_history_floating_hud');
                    if (hud && hud.style.width && hud.style.height) {
                      try {
                        localStorage.setItem('move_hist_overlay_size', JSON.stringify({ width: hud.style.width, height: hud.style.height }));
                      } catch(e) {}
                    }
                  }
                },
              },
            }, [
            h('div#move_history_hud_handle', {
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
                h(:h3, { style: { margin: '0', fontSize: '0.95rem', color: '#0f172a', fontWeight: '800' } }, 'Move Feed'),
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
                  attrs: { id: 'btn_close_move_history_overlay', type: 'button', title: 'Close Feed' },
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

            h('div#move_history_scroll_body', {
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

            h('div#move_history_resize_grip', {
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
          ])
        end
      end
    end
  end
end
