# frozen_string_literal: true

# rubocop:disable Layout/LineLength
require 'view/game/corporation'
require 'lib/trains_data'

module View
  module Game
    module Dashboard
      module RailcardHelper
        FONT_MONEY = '"Courier New", Courier, monospace'
        COLOR_MONEY = '#4c1d95'

        TOOLTIP_CSS = '
          .cmd-company-tooltip,
          .status-company-tooltip,
          .cmd-corp-tooltip,
          .status-corp-tooltip {
            display: none !important;
          }
        '

        def minor_entity?(entity)
          return false unless entity

          (entity.respond_to?(:minor?) && entity.minor?) ||
            (defined?(Engine::Minor) && entity.is_a?(Engine::Minor)) ||
            (entity.respond_to?(:type) && entity.type.to_s == 'minor') ||
            (@game.respond_to?(:minors) && @game.minors&.include?(entity))
        end

        def resolve_target_hexes(target)
          return [] unless target
          return [] if target.is_a?(Engine::Train) || target.respond_to?(:rusts_on)

          # If the entity already has physical tokens placed on the board,
          # return no hexes so the hex itself is not highlighted (pulsing token handles location).
          if (target.respond_to?(:corporation?) && target.corporation?) || (target.respond_to?(:minor?) && target.minor?)
            has_placed = false
            if target.respond_to?(:tokens) && target.tokens
              has_placed = target.tokens.any? do |t|
                (t.respond_to?(:placed?) && t.placed?) || (t.respond_to?(:city) && t.city&.hex) || (t.respond_to?(:hex) && t.hex)
              end
            end
            return [] if has_placed
          end

          hexes = []
          abilities = []
          abilities.concat(target.all_abilities) if target.respond_to?(:all_abilities) && target.all_abilities
          abilities.concat(Array(target.abilities)) if target.respond_to?(:abilities) && target.abilities

          if @game.respond_to?(:abilities) && target.respond_to?(:all_abilities)
            %i[blocks_hexes teleport tile_lay hex_bonus assign_hexes reservation close].each do |type|
              ab = begin
                @game.abilities(target, type)
              rescue StandardError, NoMethodError
                nil
              end
              abilities.concat(Array(ab)) if ab
            end
          end

          if @game && @game.class.const_defined?(:COMPANIES)
            t_sym = target.respond_to?(:sym) ? target.sym.to_s : target.to_s
            t_name = target.respond_to?(:name) ? target.name.to_s : target.to_s
            raw_def = @game.class::COMPANIES.find { |c_def| c_def[:sym].to_s == t_sym || c_def[:name].to_s == t_name }
            if raw_def && raw_def[:abilities]
              raw_def[:abilities].each do |raw_ab|
                hexes.concat(Array(raw_ab[:hexes])) if raw_ab[:hexes]
                hexes << raw_ab[:hex] if raw_ab[:hex]
              end
            end
          end

          abilities.compact.uniq.each do |a|
            if a.respond_to?(:hexes) && a.hexes
              hexes.concat(Array(a.hexes))
            elsif a.respond_to?(:hex) && a.hex
              hex_id = a.hex.respond_to?(:id) ? a.hex.id : a.hex
              hexes << hex_id
            elsif a.respond_to?(:coordinates) && a.coordinates
              hexes.concat(Array(a.coordinates))
            end

            target_corp = nil
            if a.respond_to?(:corporation) && a.corporation
              target_corp = @game.corporation_by_id(a.corporation) || a.corporation
            elsif a.respond_to?(:minor) && a.minor
              target_corp = (@game.respond_to?(:minor_by_id) ? @game.minor_by_id(a.minor) : nil) || a.minor
            end

            if target_corp && target_corp.respond_to?(:coordinates) && target_corp.coordinates
              hexes.concat(Array(target_corp.coordinates))
            end
          end

          hexes.concat(Array(target.coordinates)) if target.respond_to?(:coordinates) && target.coordinates

          hexes << target.city.hex.id if target.respond_to?(:city) && target.city&.respond_to?(:hex) && target.city&.hex

          if (target.respond_to?(:corporation?) && target.corporation?) || (target.respond_to?(:minor?) && target.minor?)
            placed_tokens = []
            if target.respond_to?(:tokens) && target.tokens
              placed_tokens = target.tokens.map { |t| t.city&.hex&.id || (t.respond_to?(:hex) && t.hex&.id) }.compact
            end

            if placed_tokens.any?
              hexes.concat(placed_tokens)
            elsif target.respond_to?(:coordinates) && target.coordinates
              hexes.concat(Array(target.coordinates))
            end
          end

          if target.respond_to?(:desc) && target.desc && @game.respond_to?(:hex_by_id)
            target.desc.scan(/\b[A-Za-z]\d{1,2}\b/).each do |h_id|
              hexes << h_id.upcase if @game.hex_by_id(h_id) || @game.hex_by_id(h_id.upcase)
            end
          end

          hexes.compact.map(&:to_s).uniq
        end

        def render_tooltip_style
          h(:style, {}, '
            .cmd-company-wrapper:hover .cmd-company-tooltip,
            .cmd-company-wrapper:hover .status-company-tooltip,
            .status-company-wrapper:hover .status-company-tooltip,
            .status-company-wrapper:hover .cmd-company-tooltip,
            .cmd-corp-wrapper:hover .cmd-corp-tooltip,
            .cmd-corp-wrapper:hover .status-corp-tooltip,
            .status-corp-wrapper:hover .status-corp-tooltip,
            .status-corp-wrapper:hover .cmd-corp-tooltip,
            .cmd-company-tooltip,
            .status-company-tooltip,
            .cmd-corp-tooltip,
            .status-corp-tooltip {
              display: none !important;
            }
          ')
        end

        def render_company_tooltip(title, subtitle, desc, val, rev, owner, hexes = [], price = nil)
          bottom_row = [
            h(:span, ['Value: ', h(:span, { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY } }, val)]),
          ]
          if price && !price.to_s.strip.empty?
            bottom_row << h(:span, ['Price: ', h(:span, { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY } }, price)])
          end
          bottom_row << h(:span, ['Revenue: ', h(:span, { style: { fontFamily: FONT_MONEY, fontWeight: 'bold', color: COLOR_MONEY } }, rev)])

          h(:div, {
              attrs: {
                class: 'status-company-tooltip cmd-company-tooltip',
                'data-hexes': Array(hexes).join(','),
              },
              style: {
                display: 'none',
                position: 'fixed',
                top: '50%',
                left: '50%',
                transform: 'translate(-50%, -50%)',
                width: '300px',
                backgroundColor: '#ffffff',
                border: '2px solid #333333',
                borderRadius: '6px',
                padding: '8px',
                boxShadow: '0 8px 24px rgba(0,0,0,0.35)',
                zIndex: '99999',
                pointerEvents: 'none',
                color: '#000000',
                textAlign: 'left',
                boxSizing: 'border-box',
                whiteSpace: 'normal',
                wordBreak: 'break-word',
              },
            }, [
            h(:div, {
                style: {
                  backgroundColor: '#ffff00',
                  border: '1px solid #000000',
                  fontWeight: 'bold',
                  fontSize: '0.8rem',
                  textAlign: 'center',
                  padding: '2px 4px',
                  marginBottom: '4px',
                  textTransform: 'uppercase',
                  borderRadius: '3px',
                },
              }, title),
            h(:div, { style: { fontWeight: 'bold', fontSize: '0.9rem', textAlign: 'center', marginBottom: '4px' } }, subtitle),
            h(:div, { style: { fontSize: '0.78rem', lineHeight: '1.25', marginBottom: '6px', color: '#222222', whiteSpace: 'normal', wordBreak: 'break-word' } }, desc),
            h(:div, { style: { display: 'flex', justifyContent: 'space-between', fontSize: '0.78rem', fontWeight: 'bold', borderTop: '1px solid #ddd', paddingTop: '4px', marginBottom: '2px' } }, bottom_row),
            h(:div, { style: { fontSize: '0.78rem', fontWeight: 'bold', textAlign: 'center', color: '#555555' } }, "Owner: #{owner}"),
          ])
        end

        def build_company_tooltip(c, price: nil)
          owner_name = c.owner&.name || 'Bank'
          desc_text = if c.respond_to?(:desc) && c.desc && !c.desc.to_s.strip.empty?
                        c.desc
                      elsif c.respond_to?(:abilities) && c.abilities&.any?
                        ability_descs = c.abilities.map do |a|
                          desc = nil
                          if a.respond_to?(:description)
                            begin
                              desc = a.description
                            rescue NotImplementedError, ScriptError, StandardError
                              desc = nil
                            end
                          end
                          desc ||= a.type.to_s.tr('_', ' ').capitalize if a.respond_to?(:type) && a.type
                          desc
                        end.compact
                        ability_descs.any? ? ability_descs.join(' ') : 'No special abilities.'
                      else
                        'No special abilities.'
                      end

          value_str = @game.format_currency(c.value || 0)
          revenue_str = @game.format_currency(c.revenue || 0)
          target_hexes = resolve_target_hexes(c)

          price_val = price
          if price_val.nil?
            if c.respond_to?(:discount) && c.discount && !c.discount.zero?
              price_val = c.respond_to?(:min_bid) ? c.min_bid : (c.value - c.discount)
            elsif c.respond_to?(:min_bid) && c.min_bid && c.respond_to?(:value) && c.min_bid != c.value
              price_val = c.min_bid
            elsif c.respond_to?(:min_price) && c.min_price && c.respond_to?(:value) && c.min_price != c.value
              price_val = c.min_price
            end
          end
          price_str = if price_val
                        price_val.is_a?(Numeric) ? @game.format_currency(price_val) : price_val.to_s
                      end

          render_company_tooltip('Private Company', c.name, desc_text, value_str, revenue_str, owner_name, target_hexes, price_str)
        end

        def render_price_dialog(title, storage_key, min_price, max_price, on_confirm, on_cancel)
          stored = Lib::Storage[storage_key]
          val_i = stored ? stored.to_i : min_price
          val_i = min_price if val_i < min_price
          val_i = max_price if val_i > max_price
          current_val = val_i.to_s

          modal_box = h(:div, {
                          style: {
                            backgroundColor: '#ffffff',
                            border: '2px solid #333333',
                            borderRadius: '8px',
                            padding: '1.5rem',
                            boxShadow: '0px 10px 30px rgba(0,0,0,0.5)',
                            color: '#000000',
                            minWidth: '260px',
                            textAlign: 'center',
                            boxSizing: 'border-box',
                          },
                        }, [
            h(:div, { style: { fontSize: '0.85rem', fontWeight: 'bold', marginBottom: '0.8rem', whiteSpace: 'nowrap' } }, title),
            h(:input, {
                key: storage_key,
                style: {
                  display: 'block',
                  width: '100%',
                  marginBottom: '0.8rem',
                  boxSizing: 'border-box',
                  padding: '5px 8px',
                  fontSize: '1rem',
                  fontFamily: FONT_MONEY,
                  fontWeight: 'bold',
                  color: COLOR_MONEY,
                },
                props: {
                  value: current_val,
                },
                attrs: {
                  type: 'number',
                  min: min_price.to_s,
                  max: max_price.to_s,
                },
                on: {
                  input: lambda { |event|
                    Lib::Storage[storage_key] = `#{event}.target.value`
                    update
                  },
                },
              }),
            h(:button, {
                style: {
                  display: 'block',
                  width: '100%',
                  marginBottom: '0.2rem',
                  cursor: 'pointer',
                  fontSize: '0.75rem',
                  fontWeight: 'bold',
                  padding: '3px 6px',
                  backgroundColor: '#007bff',
                  border: '1px solid #0056b3',
                  color: '#ffffff',
                  borderRadius: '3px',
                },
                on: {
                  click: lambda {
                    price_value = Lib::Storage[storage_key].to_i
                    price_value = min_price if price_value < min_price
                    price_value = max_price if price_value > max_price

                    Lib::Storage[storage_key] = nil
                    on_confirm.call(price_value)
                  },
                },
              }, 'Confirm'),
            h(:button, {
                style: {
                  display: 'block',
                  width: '100%',
                  cursor: 'pointer',
                  fontSize: '0.75rem',
                  padding: '3px 6px',
                  backgroundColor: '#e0e0e0',
                  border: '1px solid #999',
                  borderRadius: '3px',
                },
                on: {
                  click: lambda {
                    Lib::Storage[storage_key] = nil
                    on_cancel.call
                  },
                },
              }, 'Cancel'),
          ])

          h(:div, {
              attrs: { id: "dialog_#{storage_key}" },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                width: '100vw',
                height: '100vh',
                backgroundColor: 'rgba(0, 0, 0, 0.4)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                zIndex: '2147483647',
              },
            }, [modal_box])
        end

        def show_price_dialog(title, min_price, max_price, default_val, on_confirm, on_cancel = nil)
          %x{
            var existing = document.getElementById('railcard-dialog-portal');
            if (existing) { existing.remove(); }

            var overlay = document.createElement('div');
            overlay.id = 'railcard-dialog-portal';
            overlay.style.cssText = 'position:fixed;top:0;left:0;width:100vw;height:100vh;background:transparent;display:flex;align-items:center;justify-content:center;z-index:2147483647;box-sizing:border-box;';

            var box = document.createElement('div');
            box.style.cssText = 'background:#ffffff;border:2px solid #333333;border-radius:8px;padding:1.5rem;box-shadow:0px 12px 36px rgba(0,0,0,0.6);color:#000000;min-width:280px;max-width:90vw;text-align:center;box-sizing:border-box;';

            var titleEl = document.createElement('div');
            titleEl.style.cssText = 'font-size:0.95rem;font-weight:bold;margin-bottom:0.8rem;color:#111;word-break:break-word;cursor:move;user-select:none;';
            titleEl.title = 'Drag to move';
            titleEl.innerText = #{title};
            box.appendChild(titleEl);

            var inputEl = document.createElement('input');
            inputEl.type = 'number';
            inputEl.min = String(#{min_price});
            inputEl.max = String(#{max_price});
            inputEl.value = String(#{default_val});
            inputEl.style.cssText = 'display:block;width:100%;margin-bottom:0.8rem;box-sizing:border-box;padding:6px 10px;font-size:1.1rem;font-family:"Courier New",Courier,monospace;font-weight:bold;color:#4c1d95;text-align:center;border:1px solid #999;border-radius:4px;';
            box.appendChild(inputEl);

            var confirmBtn = document.createElement('button');
            confirmBtn.innerText = 'Confirm';
            confirmBtn.style.cssText = 'display:block;width:100%;margin-bottom:0.4rem;cursor:pointer;font-size:0.85rem;font-weight:bold;padding:6px 12px;background-color:#007bff;border:1px solid #0056b3;color:#ffffff;border-radius:4px;';
            confirmBtn.onclick = function() {
              var val = parseInt(inputEl.value, 10);
              if (isNaN(val) || val < #{min_price}) val = #{min_price};
              if (val > #{max_price}) val = #{max_price};
              overlay.remove();
              if (#{on_confirm}) {
                if (typeof #{on_confirm} === 'function') {
                  #{on_confirm}(val);
                } else if (#{on_confirm}['$call']) {
                  #{on_confirm}['$call'](val);
                }
              }
            };
            box.appendChild(confirmBtn);

            var cancelBtn = document.createElement('button');
            cancelBtn.innerText = 'Cancel';
            cancelBtn.style.cssText = 'display:block;width:100%;cursor:pointer;font-size:0.85rem;padding:6px 12px;background-color:#e0e0e0;border:1px solid #999;border-radius:4px;color:#333;';
            cancelBtn.onclick = function() {
              overlay.remove();
              if (#{on_cancel}) {
                if (typeof #{on_cancel} === 'function') {
                  #{on_cancel}();
                } else if (#{on_cancel}['$call']) {
                  #{on_cancel}['$call']();
                }
              }
            };
            box.appendChild(cancelBtn);

            inputEl.onkeydown = function(e) {
              if (e.key === 'Enter') { confirmBtn.click(); }
              else if (e.key === 'Escape') { cancelBtn.click(); }
            };

            overlay.onclick = function(e) {
              if (e.target === overlay) { cancelBtn.click(); }
            };

            box.onmousedown = function(e) {
              if (e.target === inputEl || e.target === confirmBtn || e.target === cancelBtn) return;
              e.preventDefault();

              var rect = box.getBoundingClientRect();
              box.style.position = 'fixed';
              box.style.left = rect.left + 'px';
              box.style.top = rect.top + 'px';
              box.style.transform = 'none';
              box.style.margin = '0';
              overlay.style.display = 'block';

              var startX = e.clientX;
              var startY = e.clientY;
              var initialLeft = rect.left;
              var initialTop = rect.top;

              var onMouseMove = function(moveEvent) {
                var dx = moveEvent.clientX - startX;
                var dy = moveEvent.clientY - startY;
                var newLeft = initialLeft + dx;
                var newTop = initialTop + dy;

                newLeft = Math.max(10, Math.min(window.innerWidth - box.offsetWidth - 10, newLeft));
                newTop = Math.max(10, Math.min(window.innerHeight - box.offsetHeight - 10, newTop));

                box.style.left = newLeft + 'px';
                box.style.top = newTop + 'px';
              };

              var onMouseUp = function() {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
              };

              document.addEventListener('mousemove', onMouseMove);
              document.addEventListener('mouseup', onMouseUp);
            };

            overlay.appendChild(box);
            document.body.appendChild(overlay);

            setTimeout(function() {
              inputEl.focus();
              inputEl.select();
            }, 50);
          }
          nil
        end

        def major_corporation?(entity)
          return false unless entity

          is_corporation = (entity.respond_to?(:corporation?) && entity.corporation?) ||
                           (defined?(Engine::Corporation) && entity.is_a?(Engine::Corporation))
          return false unless is_corporation

          # If the entity has an explicit logo or operates as a corporation (like 1846 minors),
          # retain major display status so logos and status cards render correctly.
          has_logo = entity.respond_to?(:logo) && entity.logo && !entity.logo.to_s.empty?
          return true if has_logo

          # Otherwise exclude entities explicitly tagged as pure minors without corporate logos
          !minor_entity?(entity)
        end

        def build_entity_tooltip(entity, price: nil)
          return nil unless entity

          is_company =
            (entity.respond_to?(:company?) && entity.company?) ||
            (defined?(Engine::Company) && entity.is_a?(Engine::Company))

          if is_company
            build_company_tooltip(entity, price: price)
          elsif minor_entity?(entity) || major_corporation?(entity)
            render_corp_tooltip(entity)
          else
            nil
          end
        end

        def render_corp_tooltip(entity)
          return nil unless entity

          is_corporation =
            (entity.respond_to?(:corporation?) && entity.corporation?) ||
            (defined?(Engine::Corporation) && entity.is_a?(Engine::Corporation))

          is_minor =
            (entity.respond_to?(:minor?) && entity.minor?) ||
            (defined?(Engine::Minor) && entity.is_a?(Engine::Minor))

          return nil unless is_corporation || is_minor

          target_hexes = resolve_target_hexes(entity)

          h(:div, {
              attrs: {
                class: 'status-corp-tooltip cmd-corp-tooltip',
                'data-hexes': target_hexes.join(','),
              },
              style: {
                display: 'none',
              },
            }, [
              h(Corporation,
                corporation: entity,
                game: @game,
                display: 'block',
                selectable: false,
                interactive: false),
            ])
        end

        # // --- START FIX ---
        TRAIN_QUIRKS = {
          # 1849 Gauge & Express Quirks
          '1849_4h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_6h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_8h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_10h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_12h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_16h' => 'Standard/dual gauge = 1 edge; narrow gauge = 2 edges.',
          '1849_r6h' => 'Restricted gauge: Narrow gauge = 1 edge; standard gauge = 2 edges.',
          '1849_e' => 'Standard gauge only (no narrow); 2x revenue on B14, C5, H12, M13.',

          # 1835 Plus-Train Quirks
          '1835_2p2' => 'Towns count toward the +2 limit and pay revenue.',
          '1835_3p3' => 'Towns count toward the +3 limit and pay revenue.',
          '1835_4p4' => 'Towns count toward the +4 limit and pay revenue.',
          '1835_5p5' => 'Towns count toward the +5 limit and pay revenue.',
          '1835_6p6' => 'Towns count toward the +6 limit and pay revenue.',

          # 18USA Quirks
          '18usa_p' => 'Pullman car: Attaches to another train; increases passenger revenue without adding stops.',
        }.freeze

        def game_id_str
          return @game.title.to_s.downcase if @game.respond_to?(:title) && @game.title

          mod = @game.class.name.split('::')[2]
          mod ? mod.sub(/^G/, '').downcase : ''
        end

        def train_hover_text(train_or_name)
          return nil unless train_or_name && @game

          train = nil
          raw_name = nil

          if train_or_name.respond_to?(:distance) || train_or_name.respond_to?(:rusts_on)
            train = train_or_name
            raw_name = train.name.to_s
          else
            raw_name = train_or_name.to_s.tr('()', '').strip
            if @game.respond_to?(:depot) && @game.depot&.respond_to?(:trains)
              train = @game.depot.trains.find { |t| t.name == raw_name }
            end
            if !train && @game.respond_to?(:all_corporations)
              train = @game.all_corporations.flat_map { |c| c.trains || [] }.find { |t| t.name == raw_name }
            end
          end

          return nil if raw_name.empty?

          clean_name = raw_name.tr('()', '').strip
          has_warranty = clean_name.end_with?('*')
          clean_code = clean_name.sub(/\*+$/, '').strip
          slug = clean_code.downcase.tr('+/ ', 'p__').gsub(/[^a-z0-9_]/, '')

          gid = game_id_str

          # 1. Agnostic lookup from compiled in-memory data store
          store = (Engine::TRAINS_DATA if defined?(Engine::TRAINS_DATA)) || {}
          direct_key = "#{gid}_#{slug}"
          train_def = store[direct_key] || store[direct_key.to_sym]
          parent_name = train_def ? (train_def['parent_name'] || train_def[:parent_name]) : nil

          # 2. Generic scan for nested variants if not keyed directly
          if !train_def && !store.empty?
            store.each_value do |entry|
              entry_gid = (entry['game_id'] || entry[:game_id]).to_s.downcase
              next unless entry_gid == gid.downcase

              entry_name = (entry['name'] || entry[:name]).to_s
              if entry_name.casecmp?(clean_code)
                train_def = entry
                break
              end

              variants = entry['variants'] || entry[:variants]
              if variants.is_a?(Hash)
                variants.each do |v_key, v_def|
                  v_name = (v_def['name'] || v_def[:name] || v_key).to_s
                  next unless v_name.casecmp?(clean_code) || v_key.to_s.casecmp?(clean_code)

                  train_def = entry.merge(v_def)
                  parent_name = entry_name
                  break
                end
              end
              break if train_def
            end
          end

          # 3. Fallback to engine TRAINS array if missing from JSON
          if !train_def && @game.class.const_defined?(:TRAINS)
            raw_trains = @game.class::TRAINS
            train_def = raw_trains.find { |td| [clean_code, raw_name].include?(td[:name].to_s) } if raw_trains.is_a?(Array)
          end

          price = if train
                    train.price
                  elsif train_def
                    train_def['price'] || train_def[:price]
                  end

          distance = if train
                       train.distance
                     elsif train_def
                       train_def['distance'] || train_def[:distance]
                     end

          rusts_on = if train
                       train.rusts_on
                     elsif train_def
                       train_def['rusts_on'] || train_def[:rusts_on] || train_def['rusts_on_id'] || train_def[:rusts_on_id]
                     end
          rusts_on = rusts_on.to_s.sub(/^.*_/, '').capitalize if rusts_on

          obsolete_on = if train&.respond_to?(:obsolete_on)
                          train.obsolete_on
                        elsif train_def
                          train_def['obsolete_on'] || train_def[:obsolete_on] || train_def['obsolete_on_id'] || train_def[:obsolete_on_id]
                        end
          obsolete_on = obsolete_on.to_s.sub(/^.*_/, '').capitalize if obsolete_on

          available_on = if train&.respond_to?(:available_on)
                           train.available_on
                         elsif train_def
                           train_def['available_on'] || train_def[:available_on] || train_def['available_on_id'] || train_def[:available_on_id]
                         end
          available_on = available_on.to_s.sub(/^.*_/, '').capitalize if available_on

          is_obsolete = train&.respond_to?(:obsolete) && train.obsolete

          lines = []

          cost_str = price && price.positive? ? " (#{@game.format_currency(price)})" : ''
          status_tag = is_obsolete ? ' [Obsolete]' : ''
          parent_tag = parent_name ? " (Band #{parent_name}#{cost_str})" : cost_str
          lines << "#{clean_name} Train#{parent_tag}#{status_tag}"

          if has_warranty
            lines << 'Status: Warrantied (Immune to rust; consumes 1 warranty token/OR)'
          elsif train_def && train_def['rusts_on'].nil? && train_def[:rusts_on].nil? && train_def['rusts_on_id'].nil? && train_def[:rusts_on_id].nil? && rusts_on.nil? && !is_obsolete
            lines << 'Status: Permanent'
          end

          permit = train_def ? (train_def['permit_required'] || train_def[:permit_required]) : nil
          lines << "Permit: Requires #{permit} Permit" if permit

          summary = train_def ? (train_def['summary'] || train_def[:summary]) : nil
          if summary
            lines << "Route: #{summary}"
          else
            dist_str = distance.to_s.strip
            hex_based = clean_name.end_with?('H') || @game.respond_to?(:hex_edge_cost)

            if dist_str == '999' || %w[D 2D 3D 4D].include?(clean_name.upcase)
              lines << 'Route: Unlimited revenue stops (Diesel)'
            elsif clean_name.upcase == 'E' && (dist_str == '99' || dist_str.empty?)
              lines << 'Route: Unlimited route distance (Express)'
            elsif dist_str == '0' || clean_name.upcase == 'P'
              lines << 'Route: Auxiliary car (attaches to train for bonus revenue)'
            elsif hex_based
              count = clean_name.gsub(/[^0-9]/, '')
              count = dist_str if count.empty? && dist_str =~ /^\d+$/
              lines << "Route: Up to #{count} hex edges"
            elsif clean_name.include?('+') || dist_str.include?('plus_train_distance')
              m = dist_str.match(/plus_train_distance\((\d+)\)/)
              val = m ? m[1] : clean_name.split('+').first
              lines << "Route: Up to #{val} major stops and #{val} towns"
            elsif distance.is_a?(Array)
              pay_counts = distance.map { |node| node['pay'] || node[:pay] }.compact
              lines << (pay_counts.any? ? "Route: Up to #{pay_counts.max} revenue stops" : 'Route: Special stop restrictions')
            elsif /^\d+$/.match?(dist_str)
              lines << "Route: Up to #{dist_str} revenue stops"
            elsif /^\d+$/.match?(clean_name)
              lines << "Route: Up to #{clean_name} revenue stops"
            end
          end

          rules = train_def ? (train_def['rules'] || train_def[:rules]) : nil
          rules.each { |r| lines << "• #{r}" } if rules.is_a?(Array)

          notes = train_def ? (train_def['notes'] || train_def[:notes]) : nil
          lines << "Note: #{notes}" if notes && !notes.empty?

          if rusts_on
            rust_label = has_warranty ? "Rusts on: #{rusts_on} (Delayed by Warranty)" : "Rusts on: #{rusts_on}"
            lines << rust_label
          elsif obsolete_on
            lines << "Obsoletes on: #{obsolete_on}"
          end

          lines << "Available on: #{available_on}" if available_on

          lines.join("\n")
        end

        def train_data_store
          @train_data_store ||= begin
            raw = nil
            %x{
              if (typeof window !== 'undefined' && window.TRAINS_DATA) {
                raw = window.TRAINS_DATA;
              } else if (typeof window !== 'undefined' && window._trains) {
                raw = window._trains;
              } else if (typeof require !== 'undefined') {
                try { raw = require('./trains.json'); } catch(e1) {
                  try { raw = require('../trains.json'); } catch(e2) {
                    try { raw = require('../../trains.json'); } catch(e3) {
                      try { raw = require('../../../trains.json'); } catch(e4) { raw = null; }
                    }
                  }
                }
              }
            }
            if raw.nil? && defined?(File) && File.exist?('trains.json')
              require 'json' unless defined?(JSON)
              raw = JSON.parse(File.read('trains.json'))
            end
            raw || {}
          end
        end

        def lookup_train_def(gid, clean_name)
          store = train_data_store
          return [nil, nil] if store.empty?

          clean_code = clean_name.sub(/\*+$/, '').strip
          slug = clean_code.downcase.tr('+/ ', 'p__').gsub(/[^a-z0-9_]/, '')

          # 1. Direct O(1) match by game_id + slug (e.g., 1862_1f, 1849_e, 1835_2p2)
          direct_key = "#{gid}_#{slug}"
          direct_def = store[direct_key] || store[direct_key.to_sym]
          return [direct_def, direct_def[:parent_name] || direct_def['parent_name']] if direct_def

          # 2. Match parent trains or nested variants across the active game
          store.each_value do |entry|
            entry_gid = (entry[:game_id] || entry['game_id']).to_s.downcase
            next unless entry_gid == gid.downcase

            entry_name = (entry[:name] || entry['name']).to_s
            return [entry, nil] if entry_name.casecmp?(clean_code)

            # Search nested variants dictionary if present
            variants = entry[:variants] || entry['variants']
            next unless variants.is_a?(Hash)

            variants.each do |v_key, v_def|
              v_name = (v_def[:name] || v_def['name'] || v_key).to_s
              if v_name.casecmp?(clean_code) || v_key.to_s.casecmp?(clean_code)
                merged = entry.merge(v_def)
                return [merged, entry_name]
              end
            end
          end

          [nil, nil]
        end

        def render_major_railcard(corporation, click_handler = nil, card_classes = ['major-railcard'], wrapper_id = nil)
          return nil unless major_corporation?(corporation) || minor_entity?(corporation)

          classes = Array(card_classes).compact.map(&:to_s)
          classes << 'major-railcard' unless classes.include?('major-railcard')
          classes << 'clickable' if click_handler && !classes.include?('clickable')

          tooltip = render_corp_tooltip(corporation)

          text = if corporation.respond_to?(:sym) && corporation.sym && !corporation.sym.to_s.empty?
                   corporation.sym.to_s
                 else
                   corporation.id.to_s
                 end

          bg_color = corporation.respond_to?(:color) && corporation.color ? corporation.color : '#4169e1'
          text_color = corporation.respond_to?(:text_color) && corporation.text_color ? corporation.text_color : '#ffffff'
          is_buy = classes.include?('action-buy')
          is_sell = classes.include?('action-sell')
          edge_color = if is_buy
                         '#16a34a'
                       elsif is_sell
                         '#dc2626'
                       else
                         '#333333'
                       end

          card_props = {
            attrs: {
              class: classes.join(' '),
              title: corporation.respond_to?(:name) ? corporation.name.to_s : text,
              'data-corp': corporation.id,
            },
            style: {
              minWidth: '3.2rem',
              height: '1.45rem',
              padding: '0 5px',
              margin: '0',
              boxSizing: 'border-box',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              borderRadius: '0',
              fontSize: '0.85rem',
              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
              fontWeight: '800',
              lineHeight: '1',
              letterSpacing: '0',
              color: text_color,
              backgroundColor: bg_color,
              border: "2px solid #{edge_color}",
              boxShadow: is_buy || is_sell ? "0 0 0 1px #{edge_color}" : 'none',
              cursor: click_handler ? 'pointer' : 'help',
              whiteSpace: 'nowrap',
            },
          }

          card_props[:on] = { click: click_handler } if click_handler

          wrapper_attrs = {
            class: 'major-railcard-wrapper status-corp-wrapper cmd-corp-wrapper',
            # --- START FIX ---
            'data-corp': corporation.id,
            # --- END FIX ---
          }
          wrapper_attrs[:id] = wrapper_id if wrapper_id && !wrapper_id.to_s.empty?

          h(:div, {
              attrs: wrapper_attrs,
              style: {
                display: 'inline-flex',
                position: 'relative',
                alignItems: 'center',
                justifyContent: 'center',
                verticalAlign: 'middle',
              },
            }, [
              tooltip,
              h(:div, card_props, text),
            ].compact)
        end

        # Canonical short-share card. Formatted as a distinct reddish liability share
        # with an explicit minus symbol and action borders:
        # - Green (.action-buy): Covers the short position (pays cash to clear debt).
        # - Red (.action-sell): Expands the short position (sells borrowed stock).
        def render_short_railcard(corporation, percent: nil, shorted: nil, maximum: nil, click_handler: nil, dropdown: nil, wrapper_id: nil, card_classes: nil, **_unused)
          short_percent = if percent.nil?
                            share_percent = if corporation.respond_to?(:share_percent) && corporation.share_percent
                                              corporation.share_percent.to_i
                                            else
                                              10
                                            end
                            shorted.to_i.abs * share_percent
                          else
                            percent.to_i.abs
                          end
          return nil unless short_percent.positive? || click_handler

          classes = %w[game-card short-railcard]
          if card_classes
            Array(card_classes).each do |cls|
              classes << cls.to_s unless classes.include?(cls.to_s)
            end
          end
          classes << 'clickable' if click_handler && !classes.include?('clickable')

          is_buy = classes.include?('action-buy')
          is_sell = classes.include?('action-sell')

          border_color = if is_buy
                           '#16a34a'
                         elsif is_sell
                           '#dc2626'
                         elsif click_handler
                           '#dc2626'
                         else
                           '#f87171'
                         end

          box_shadow = if is_buy
                         '0 0 0 1px #16a34a'
                       elsif is_sell || (click_handler && is_sell)
                         '0 0 0 1px #dc2626'
                       else
                         'none'
                       end

          corp_label = corporation.respond_to?(:name) ? corporation.name.to_s : corporation.id.to_s
          card_props = {
            attrs: {
              class: classes.join(' '),
              title: "#{corp_label} Short Liability: −#{short_percent}%",
              # --- START FIX ---
              'data-corp': corporation.id,
              # --- END FIX ---
            },
            style: {
              minWidth: '3.5rem',
              height: '1.45rem',
              padding: '0 6px',
              margin: '2px',
              boxSizing: 'border-box',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              borderRadius: '4px',
              fontSize: '0.85rem',
              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
              fontWeight: 'bold',
              lineHeight: '1',
              color: '#991b1b',
              backgroundColor: '#fee2e2',
              border: "2px solid #{border_color}",
              boxShadow: box_shadow,
              cursor: click_handler ? 'pointer' : 'default',
              whiteSpace: 'nowrap',
            },
          }
          card_props[:on] = { click: click_handler } if click_handler

          card = h(:div, card_props, "−#{short_percent}%")
          dropdown_items = Array(dropdown).compact
          return card if !wrapper_id && dropdown_items.empty?

          # --- DELETE ---
          # wrapper_attrs = { class: 'short-railcard-wrapper' }
          # --- START FIX ---
          wrapper_attrs = { class: 'short-railcard-wrapper', 'data-corp': corporation.id }
          # --- END FIX ---
          wrapper_attrs[:id] = wrapper_id if wrapper_id && !wrapper_id.to_s.empty?

          h(:div, {
              attrs: wrapper_attrs,
              style: {
                display: 'inline-flex',
                position: 'relative',
                alignItems: 'center',
                justifyContent: 'center',
                verticalAlign: 'middle',
              },
            }, [card, *dropdown_items])
        end

        # Player-cell short convenience wrapper.
        def render_short_position_railcard(corporation, percent:, click_handler: nil, dropdown: nil, wrapper_id: nil, card_classes: nil)
          render_short_railcard(
            corporation,
            percent: percent,
            click_handler: click_handler,
            dropdown: dropdown,
            wrapper_id: wrapper_id,
            card_classes: card_classes
          )
        end

        def render_railcard(text, card_classes = ['game-card'], click_handler = nil, tooltip = nil, dropdown = nil, wrapper_id = nil, wrapper_classes = nil, entity: nil)
          classes = []
          if card_classes
            `if (Array.isArray(#{card_classes})) {`
            classes = card_classes
            `} else {`
            classes = [card_classes]
            `}`
          else
            classes = ['game-card']
          end

          classes_str = classes.join(' ')
          is_buy = classes.include?('action-buy')
          is_sell = classes.include?('action-sell')
          is_clickable = click_handler ? true : false

          border_color = if is_buy
                           '#16a34a'
                         elsif is_sell
                           '#dc2626'
                         else
                           '#888888'
                         end

          bg_color = if is_buy
                       '#e6f4ea'
                     elsif is_sell
                       '#fef2f2'
                     else
                       '#fdfbf7'
                     end

          %x(
          if (typeof window !== 'undefined') {
          // Single source of truth for synchronized 3-way corporate breathing animation
            var ensureTokenPulseStyle = function() {
              if (!document.getElementById('corp-token-pulse-style')) {
                var s = document.createElement('style');
                s.id = 'corp-token-pulse-style';
                s.innerHTML = '@keyframes corp-breathing-sync { ' +
                  '0% { transform: scale(1); } ' +
                  '50% { transform: scale(1.45); } ' +
                  '100% { transform: scale(1); } ' +
                  '} ' +
                  '@keyframes corp-status-card-breathing-sync { ' +
                  '0% { transform: scale(1); } ' +
                  '50% { transform: scale(1.15); } ' +
                  '100% { transform: scale(1); } ' +
                  '} ' +
                  '.stock-market-token-highlight { ' +
                  'animation: corp-breathing-sync 0.85s ease-in-out infinite !important; ' +
                  'transform-origin: center center !important; ' +
                  'transform-box: fill-box !important; ' +
                  'z-index: 999999 !important; ' +
                  'filter: drop-shadow(0 0 6px rgba(0, 0, 0, 0.85)) drop-shadow(0 0 3px #00ffff) !important; ' +
                  '} ' +
                  '.map-token.stock-market-token-highlight { ' +
                  'animation: corp-breathing-sync 0.85s ease-in-out infinite !important; ' +
                  'transform-origin: center center !important; ' +
                  'transform-box: fill-box !important; ' +
                  'filter: drop-shadow(0 0 8px rgba(0, 0, 0, 0.9)) drop-shadow(0 0 4px #00ffff) !important; ' +
                  '} ' +
                  '.status-corp-highlight { ' +
                  'animation: corp-status-card-breathing-sync 0.85s ease-in-out infinite !important; ' +
                  'transform-origin: center center !important; ' +
                  'z-index: 99999 !important; ' +
                  'filter: drop-shadow(0 0 6px rgba(0, 255, 255, 0.8)) !important; ' +
                  '} ' +
                  ':has(> .stock-market-token-highlight), :has(.stock-market-token-highlight) { z-index: 99999 !important; }';
                document.head.appendChild(s);
              }
            };
            ensureTokenPulseStyle();

          window.highlightStockMarketToken = function(corpId) {
              if (!corpId) return;
              if (window._highlightedMarketCorp === corpId) return;
              window.clearStockMarketTokenHighlight();
              window._highlightedMarketCorp = corpId;

              var safeCorpAttr = (typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(corpId) : String(corpId).replace(/["\\]/g, '\\$&');

              // 1. Highlight stock market tokens
              var stockTokens = document.querySelectorAll(
                '.stock-market-token[data-corp="' + safeCorpAttr + '"], [id="stock-token-' + safeCorpAttr + '"]'
              );
              for (var i = 0; i < stockTokens.length; i++) {
                var st = stockTokens[i];
                st.classList.add('stock-market-token-highlight');
                var cell = st.closest('div');
                if (cell) {
                  cell.style.zIndex = '99999';
                  window._elevatedMarketCell = cell;
                }
              }

              // 2. Highlight map tokens (use data-corp attribute only to avoid invalid CSS class identifiers like B&O)
              var mapTokens = document.querySelectorAll(
                '.map-token[data-corp="' + safeCorpAttr + '"], [data-corp="' + safeCorpAttr + '"].map-token'
              );
              for (var j = 0; j < mapTokens.length; j++) {
                var mt = mapTokens[j];
                mt.classList.add('stock-market-token-highlight');
                var hexContainer = mt.closest('.map-hex-container');
                if (hexContainer && hexContainer.parentNode && hexContainer.parentNode.lastElementChild !== hexContainer) {
                  hexContainer.parentNode.appendChild(hexContainer);
                }
              }

              // 3. Highlight status panel major railcard
              var statusCards = document.querySelectorAll(
                '.major-railcard[data-corp="' + safeCorpAttr + '"], .status-corp-wrapper[data-corp="' + safeCorpAttr + '"], [data-corp="' + safeCorpAttr + '"] .major-railcard'
              );
              for (var k = 0; k < statusCards.length; k++) {
                statusCards[k].classList.add('status-corp-highlight');
              }
            };

            window.clearStockMarketTokenHighlight = function() {
              window._highlightedMarketCorp = null;
              if (window._elevatedMarketCell) {
                window._elevatedMarketCell.style.zIndex = '';
                window._elevatedMarketCell = null;
              }
              var highlightedTokens = document.querySelectorAll('.stock-market-token-highlight');
              for (var i = 0; i < highlightedTokens.length; i++) {
                highlightedTokens[i].classList.remove('stock-market-token-highlight');
              }
              var highlightedCards = document.querySelectorAll('.status-corp-highlight');
              for (var j = 0; j < highlightedCards.length; j++) {
                highlightedCards[j].classList.remove('status-corp-highlight');
              }
            };

            if (!window._railcard_portal_installed) {
              var portal = document.getElementById('railcard-portal');
              if (!portal) {
                portal = document.createElement('div');
                portal.id = 'railcard-portal';
                document.body.appendChild(portal);
              }
              portal.style.cssText = 'position:fixed;top:0;left:0;pointer-events:none !important;z-index:2147483647;display:none;width:320px;max-width:90vw;background:#ffffff;border:2px solid #333333;border-radius:6px;padding:8px;box-shadow:0 12px 36px rgba(0,0,0,0.5);color:#000000;text-align:left;box-sizing:border-box;white-space:normal;word-break:break-word;';

              var styleEl = document.createElement('style');
              styleEl.innerHTML = '.short-railcard { background-color: #fee2e2 !important; color: #991b1b !important; } .ghost-short-card { opacity: 0.35 !important; border: 1.5px dotted #dc2626 !important; background-color: transparent !important; box-shadow: none !important; color: #dc2626 !important; } .ghost-short-card:hover { opacity: 0.85 !important; background-color: rgba(254, 226, 226, 0.35) !important; transform: translateY(-1px); }';
              document.head.appendChild(styleEl);

              window._railcard_portal_installed = true;

              var hidePortal = function() {
                var p = document.getElementById('railcard-portal');
                if (p && p.style.display !== 'none') {
                  p.style.display = 'none';
                  p.innerHTML = '';
                }
                if (typeof window !== 'undefined' && window.clearMapHexHighlights) {
                  window.clearMapHexHighlights();
                }
              };

              var positionPortal = function(e, p) {
                if (!p || p.style.display === 'none') return;
                var marginX = 14;
                var marginY = 14;
                var rect = p.getBoundingClientRect();
                var w = rect.width || 320;
                var h = rect.height || 180;
                var vw = window.innerWidth;
                var vh = window.innerHeight;

                var x = e.clientX + marginX;
                var y = e.clientY + marginY;

                if (x + w > vw - 10) {
                  x = e.clientX - w - marginX;
                }
                if (x < 10) {
                  x = Math.max(10, vw - w - 10);
                }

                if (y + h > vh - 10) {
                  y = e.clientY - h - marginY;
                }
                if (y < 10) {
                  y = Math.max(10, vh - h - 10);
                }

                p.style.left = x + 'px';
                p.style.top = y + 'px';
                p.style.transform = 'none';
              };

              document.addEventListener('mouseover', function(e) {
                var wrapper = e.target.closest && e.target.closest('.cmd-company-wrapper, .status-company-wrapper, .cmd-corp-wrapper, .status-corp-wrapper');
                if (wrapper) {
                  var tt = wrapper.querySelector('.cmd-company-tooltip, .status-company-tooltip, .cmd-corp-tooltip, .status-corp-tooltip');
                  if (tt) {
                    var p = document.getElementById('railcard-portal');
                    if (p) {
                      p.innerHTML = tt.innerHTML;
                      p.style.display = 'block';
                      positionPortal(e, p);
                    }
                    var hexAttr = tt.getAttribute('data-hexes');
                    if (hexAttr && typeof window !== 'undefined' && window.highlightMapHexes) {
                      var hexList = hexAttr.split(',').filter(Boolean);
                      if (hexList.length > 0) {
                        window.highlightMapHexes(hexList);
                      }
                    }
                  }
                } else {
                  hidePortal();
                }
              });

              document.addEventListener('mousemove', function(e) {
                var p = document.getElementById('railcard-portal');
                if (p && p.style.display !== 'none') {
                  var wrapper = e.target.closest && e.target.closest('.cmd-company-wrapper, .status-company-wrapper, .cmd-corp-wrapper, .status-corp-wrapper');
                  if (wrapper) {
                    positionPortal(e, p);
                  } else {
                    hidePortal();
                  }
                }
              });

              document.addEventListener('mouseout', function(e) {
                var wrapper = e.target.closest && e.target.closest('.cmd-company-wrapper, .status-company-wrapper, .cmd-corp-wrapper, .status-corp-wrapper');
                if (wrapper) {
                  var related = e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest('.cmd-company-wrapper, .status-company-wrapper, .cmd-corp-wrapper, .status-corp-wrapper');
                  if (related !== wrapper) {
                    hidePortal();
                  }
                }
              });

              window.addEventListener('scroll', hidePortal, true);
              window.addEventListener('click', hidePortal, true);
            }

            if (!window._market_token_hover_installed) {
              window._market_token_hover_installed = true;

            var getCorpFromElement = function(el) {
                if (!el || !el.closest) return null;

                // 1. Stock market token or container
                var stockToken = el.closest('.stock-market-token');
                if (stockToken) {
                  var stCorp = stockToken.getAttribute('data-corp');
                  if (stCorp) return stCorp;
                  if (stockToken.id && stockToken.id.indexOf('stock-token-') === 0) {
                    return stockToken.id.substring(12);
                  }
                }

                // 2. Map token
                var mapToken = el.closest('.map-token');
                if (mapToken) {
                  var mtCorp = mapToken.getAttribute('data-corp');
                  if (mtCorp) return mtCorp;
                }

                // 3. Operational columns: ignore cash/trains/empty slots
                if (el.closest('.corporation-trains, .corporation-cash, .empty-train-slot, [id^="trains_"], [id^="tokens_"]')) {
                  return null;
                }

                // 4. Certificates and status cards
                var certEl = el.closest('.cert-share-card, .game-card, .major-railcard, .short-card, .ghost-short-card, .major-railcard-wrapper');
                if (!certEl) return null;

                var explicitCorpEl = certEl.closest('[data-corp]');
                if (explicitCorpEl && !explicitCorpEl.matches('tr')) {
                  var c = explicitCorpEl.getAttribute('data-corp');
                  if (c && c !== '') return c;
                }

                var cell = certEl.closest('td[id], th[id]');
                if (cell && cell.id) {
                  var id = cell.id;
                  if (id.indexOf('pool_shares_') === 0) return id.substring(12);
                  if (id.indexOf('ipo_shares_') === 0) return id.substring(11);
                  if (id.indexOf('treasury_shares_') === 0) return id.substring(16);
                  if (id.indexOf('status_major_') === 0) return id.substring(13);
                  if (id.indexOf('player_shares_') === 0) {
                    var parts = id.split('_');
                    return parts[parts.length - 1];
                  }
                }

                var row = certEl.closest('tr');
                if (row && row.getAttribute('data-corp')) {
                  return row.getAttribute('data-corp');
                }

                return null;
              };

              document.addEventListener('mouseover', function(e) {
                var corpId = getCorpFromElement(e.target);
                if (corpId) {
                  if (window.highlightStockMarketToken) {
                    window.highlightStockMarketToken(corpId);
                  }
                } else if (!e.target.closest || !e.target.closest('.stock-market-token, .map-token, .cert-share-card, .major-railcard')) {
                  if (window.clearStockMarketTokenHighlight) {
                    window.clearStockMarketTokenHighlight();
                  }
                }
              });

              document.addEventListener('mouseout', function(e) {
                var fromCorp = getCorpFromElement(e.target);
                if (fromCorp) {
                  var toCorp = getCorpFromElement(e.relatedTarget);
                  if (toCorp !== fromCorp && window.clearStockMarketTokenHighlight) {
                    window.clearStockMarketTokenHighlight();
                  }
                }
              });

              window.addEventListener('scroll', function() {
                if (window.clearStockMarketTokenHighlight) window.clearStockMarketTokenHighlight();
              }, true);
              window.addEventListener('click', function() {
                if (window.clearStockMarketTokenHighlight) window.clearStockMarketTokenHighlight();
              }, true);
            }
          }
          )
          resolved_entity = entity
          if !resolved_entity && @game && text && !text.to_s.strip.empty?
            t_str = text.to_s
            first_part = t_str.split('(').first
            t_clean = first_part ? first_part.strip : ''
            t_clean = t_clean.sub(/\s+[$£€\d].*$/, '').strip

            resolved_entity = (@game.respond_to?(:companies) ? @game.companies.find { |c| c.id.to_s == t_clean || (c.respond_to?(:sym) && c.sym.to_s == t_clean) || c.name.to_s == t_clean } : nil) ||
                              (@game.respond_to?(:corporations) ? @game.corporations.find { |c| c.id.to_s == t_clean || (c.respond_to?(:sym) && c.sym.to_s == t_clean) || c.name.to_s == t_clean } : nil) ||
                              (@game.respond_to?(:minors) ? @game.minors.find { |m| m.id.to_s == t_clean || (m.respond_to?(:sym) && m.sym.to_s == t_clean) || m.name.to_s == t_clean } : nil)
          end

          target_hexes = resolved_entity ? resolve_target_hexes(resolved_entity) : []

          hover_events = {}
          if target_hexes.any?
            hover_events[:mouseenter] = lambda {
              %x{
                if (typeof window !== 'undefined' && window.highlightMapHexes) {
                  window.highlightMapHexes(#{target_hexes});
                }
              }
              nil
            }
            hover_events[:mouseleave] = lambda {
              %x{
                if (typeof window !== 'undefined' && window.clearMapHexHighlights) {
                  window.clearMapHexHighlights();
                }
              }
              nil
            }
          end

          has_tooltip = tooltip ? true : false
          valid_classes = []
          valid_classes.concat(%w[cmd-company-wrapper status-company-wrapper cmd-corp-wrapper status-corp-wrapper]) if has_tooltip

          if wrapper_classes
            `if (Array.isArray(#{wrapper_classes})) {`
            wrapper_classes.each do |cls|
              if cls
                c_str = `String(#{cls})`
                valid_classes << c_str unless valid_classes.include?(c_str)
              end
            end
            `} else {`
            c_str = `String(#{wrapper_classes})`
            valid_classes << c_str unless valid_classes.include?(c_str)
            `}`
          end

          has_wrapper_classes = !valid_classes.empty?
          clean_wrapper_classes = valid_classes.join(' ')

          has_wrapper_id = wrapper_id && !wrapper_id.to_s.empty?
          clean_wrapper_id = wrapper_id.to_s if has_wrapper_id

          dropdown_items = []
          if dropdown
            `if (Array.isArray(#{dropdown})) {`
            dropdown_items = dropdown
            `} else {`
            dropdown_items = [dropdown]
            `}`
          end
          has_dropdown = !dropdown_items.empty?

          # // --- START FIX ---
          is_train = classes.include?('card-train') || wrapper_id.to_s.include?('train') || entity&.respond_to?(:rusts_on)
          if is_train && !classes.include?('card-train')
            classes << 'card-train'
            classes_str = classes.join(' ')
          end

          train_title = nil
          if is_train
            train_target = entity
            if !train_target && wrapper_id.to_s =~ /train_wrapper_([^_]+)_(.+)/
              corp_id = Regexp.last_match(1)
              train_id = Regexp.last_match(2)
              corp = (@game.respond_to?(:corporation_by_id) ? @game.corporation_by_id(corp_id) : nil) ||
                     (@game.respond_to?(:all_corporations) ? @game.all_corporations.find { |c| c.id.to_s == corp_id } : nil)
              train_target = corp&.trains&.find { |tr| tr.id.to_s == train_id }
            end
            train_target ||= text
            train_title = train_hover_text(train_target)
          end
          # // --- END FIX ---

          style_props = {
            minWidth: '3.2rem',
            height: '1.45rem',
            padding: '0 4px',
            margin: '2px',
            boxSizing: 'border-box',
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            borderRadius: is_train ? '12px' : '4px',
            fontSize: '0.85rem',
            fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
            color: '#000000',
            backgroundColor: bg_color,
            border: "2px solid #{border_color}",
            cursor: is_clickable ? 'pointer' : 'default',
            whiteSpace: 'nowrap',
          }

          card_props = {
            attrs: { class: classes_str },
            style: style_props,
          }
          card_props[:attrs][:id] = clean_wrapper_id if has_wrapper_id
          # // --- START FIX ---
          card_props[:attrs][:title] = train_title if train_title
          if is_train
            t_slug = (entity&.respond_to?(:name) ? entity.name : text).to_s.tr('()', '').strip.downcase.tr('+', 'p').gsub(/[^a-z0-9_]/, '')
            card_props[:attrs]['data-train'] = t_slug unless t_slug.empty?
          end
          # // --- END FIX ---
          card_props[:on] = { click: click_handler } if is_clickable

          corp_id_str = nil
          if resolved_entity && ((resolved_entity.respond_to?(:corporation?) && resolved_entity.corporation?) || (resolved_entity.respond_to?(:minor?) && resolved_entity.minor?))
            corp_id_str = resolved_entity.id.to_s
            card_props[:attrs]['data-corp'] = corp_id_str
          end

          needs_wrapper = has_tooltip || has_dropdown || (!is_train && has_wrapper_id) || has_wrapper_classes

          if needs_wrapper
            w_attrs = {}
            w_attrs[:id] = clean_wrapper_id if has_wrapper_id && !is_train
            w_attrs[:class] = clean_wrapper_classes if has_wrapper_classes
            w_attrs['data-corp'] = corp_id_str if corp_id_str
            # // --- START FIX ---
            w_attrs[:title] = train_title if is_train && train_title
            # // --- END FIX ---

            children = []
            children << tooltip if has_tooltip
            children << h(:div, card_props, text.to_s)
            children.concat(dropdown_items) if has_dropdown

            h(:div, {
                attrs: w_attrs,
                style: { display: 'inline-block', position: 'relative' },
                on: hover_events,
              }, children.compact)
          else
            card_props[:on] ||= {}
            card_props[:on].merge!(hover_events)
            h(:div, card_props, text.to_s)
          end
        end

        # Contextual affordance in eligible empty cells.
        # Dotted edge, low opacity (0.35), transparent background, no action-sell class collision.
        def render_ghost_short_railcard(corporation, percent: nil, click_handler: nil, dropdown: nil, wrapper_id: nil)
          return nil unless corporation

          share_percent = if percent
                            percent.to_i.abs
                          else
                            (corporation.respond_to?(:share_percent) && corporation.share_percent ? corporation.share_percent.to_i : 10)
                          end

          classes = %w[game-card ghost-short-card]
          classes << 'clickable' if click_handler

          card_props = {
            attrs: {
              class: classes.join(' '),
              title: "Sell Short #{corporation.name} (−#{share_percent}%)",
              # --- START FIX ---
              'data-corp': corporation.id,
              # --- END FIX ---
            },
            style: {
              minWidth: '3.5rem',
              height: '1.45rem',
              padding: '0 6px',
              margin: '2px',
              boxSizing: 'border-box',
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              borderRadius: '4px',
              fontSize: '0.85rem',
              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
              fontWeight: 'bold',
              lineHeight: '1',
              color: '#dc2626',
              backgroundColor: 'transparent',
              border: '1.5px dotted #dc2626',
              boxShadow: 'none',
              cursor: click_handler ? 'pointer' : 'default',
              whiteSpace: 'nowrap',
              opacity: '0.35',
              transition: 'opacity 0.15s ease, background-color 0.15s ease, transform 0.15s ease',
            },
          }
          card_props[:on] = { click: click_handler } if click_handler

          card = h(:div, card_props, "−#{share_percent}%")
          dropdown_items = Array(dropdown).compact
          return card if !wrapper_id && dropdown_items.empty?

          h(:div, {
              # --- DELETE ---
              # attrs: { id: wrapper_id, class: 'ghost-short-card-wrapper' },
              # --- START FIX ---
              attrs: { id: wrapper_id, class: 'ghost-short-card-wrapper', 'data-corp': corporation.id },
              # --- END FIX ---
              style: {
                display: 'inline-flex',
                position: 'relative',
                alignItems: 'center',
                justifyContent: 'center',
                verticalAlign: 'middle',
              },
            }, [card, *dropdown_items])
        end

        alias render_ghost_short_card render_ghost_short_railcard
      end
    end
  end
end

# rubocop:enable Layout/LineLength
