# frozen_string_literal: true

require 'lib/storage'

module View
  module Game
    module Dashboard
      class OtherGamesOverlay < Snabberb::Component
        needs :game
        needs :user_id, default: nil
        needs :on_close, default: nil

        def render
          close_handler = lambda do |e|
            `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
            @on_close&.call
          end

          curr_id = (@game.respond_to?(:id) ? @game.id : nil)&.to_s
          uid = @user_id.to_s

          games_data = %x((function() {
            var raw = window._user_games_cache;
            if (!raw || !Array.isArray(raw)) {
              try { raw = JSON.parse(localStorage.getItem('all_user_games') || '[]'); } catch(e) { raw = []; }
            }
            if (!Array.isArray(raw)) return [];

            var myId = parseInt(#{uid}, 10);
            var curId = parseInt(#{curr_id}, 10);

            return raw.map(function(g) {
              var isMyTurn = g.acting && Array.isArray(g.acting) && g.acting.indexOf(myId) !== -1;
              var isCurrent = (g.id === curId);
              return [
                String(g.id),
                String(g.title || '18xx'),
                String(g.round || ''),
                String(g.description || ''),
                isMyTurn ? 1 : 0,
                isCurrent ? 1 : 0
              ];
            }).sort(function(a, b) {
              var orderA = (a[4] === 1 && a[5] === 0) ? 0 : (a[4] === 1 ? 1 : (a[5] === 1 ? 2 : 3));
              var orderB = (b[4] === 1 && b[5] === 0) ? 0 : (b[4] === 1 ? 1 : (b[5] === 1 ? 2 : 3));
              return orderA - orderB;
            });
          })())

          game_rows = if games_data.nil? || games_data.empty?
                        [
                          h(:div, {
                              style: {
                                padding: '2rem 1rem',
                                textAlign: 'center',
                                color: '#64748b',
                                fontStyle: 'italic',
                                fontSize: '0.9rem',
                              },
                            }, 'Loading your active games...'),
                        ]
                      else
                        games_data.map do |item|
                          gid = item[0]
                          title = item[1]
                          round = item[2]
                          desc = item[3]
                          is_turn = (item[4] == 1)
                          is_cur = (item[5] == 1)

                          card_bg = if is_turn
                                      '#f0fdf4'
                                    else
                                      (is_cur ? '#f8fafc' : '#ffffff')
                                    end
                          border_style = if is_turn
                                           '2px solid #16a34a'
                                         else
                                           (is_cur ? '2px solid #94a3b8' : '1px solid #cbd5e1')
                                         end
                          badge_bg = if is_turn
                                       '#16a34a'
                                     else
                                       (is_cur ? '#64748b' : '#e2e8f0')
                                     end
                          badge_color = is_turn || is_cur ? '#ffffff' : '#475569'
                          badge_text = if is_turn && is_cur
                                         '★ YOUR TURN (Here)'
                                       elsif is_turn
                                         '★ YOUR TURN'
                                       elsif is_cur
                                         'Current'
                                       else
                                         'Waiting'
                                       end

                          click_row = lambda do |e|
                            `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
                            if is_cur
                              close_handler.call(nil)
                            else
                              `window.location.href = '/game/' + #{gid} + '#dashboard'`
                            end
                          end

                          h(:div, {
                              attrs: { title: is_cur ? 'Current game' : "Open Game ##{gid} Dashboard" },
                              style: {
                                display: 'flex',
                                flexDirection: 'row',
                                alignItems: 'center',
                                justifyContent: 'space-between',
                                padding: '0.65rem 0.85rem',
                                borderRadius: '6px',
                                cursor: is_cur ? 'default' : 'pointer',
                                backgroundColor: card_bg,
                                border: border_style,
                                boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                                transition: 'background-color 0.15s ease',
                              },
                              on: { click: click_row },
                            }, [
                              h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', minWidth: '0' } }, [
                                h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.45rem', flexWrap: 'wrap' } }, [
                                  h(:strong, { style: { fontSize: '1rem', color: '#0f172a' } }, "#{title} (##{gid})"),
                                  (if !round.empty?
                                     h(:span,
                                       { style: { fontSize: '0.78rem', color: '#64748b', fontWeight: '600' } }, "• #{round}")
                                   else
                                     nil
                                   end),
                                ].compact),
                                (if !desc.empty?
                                   h(:span,
                                     { style: { fontSize: '0.75rem', color: '#64748b', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '320px' } }, desc)
                                 else
                                   nil
                                 end),
                              ].compact),
                              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', flexShrink: '0' } }, [
                                h(:span, {
                                    style: {
                                      fontSize: '0.72rem',
                                      fontWeight: 'bold',
                                      padding: '2px 8px',
                                      borderRadius: '10px',
                                      backgroundColor: badge_bg,
                                      color: badge_color,
                                    },
                                  }, badge_text),
                                (if !is_cur
                                   h(:span, { style: { fontSize: '1rem', color: '#0284c7', fontWeight: 'bold' } },
                                     '→')
                                 else
                                   nil
                                 end),
                              ].compact),
                            ])
                        end
                      end

          overlay_bg = h(:div, {
                           style: {
                             position: 'fixed',
                             top: '0',
                             left: '0',
                             width: '100vw',
                             height: '100vh',
                             backgroundColor: 'rgba(0,0,0,0.65)',
                             zIndex: '99999',
                             cursor: 'pointer',
                           },
                           on: { click: close_handler },
                         })

          overlay_box = h(:div, {
                            style: {
                              position: 'fixed',
                              top: '50%',
                              left: '50%',
                              transform: 'translate(-50%, -50%)',
                              backgroundColor: '#ffffff',
                              padding: '1.5rem',
                              borderRadius: '8px',
                              boxShadow: '0 20px 25px -5px rgba(0,0,0,0.4)',
                              zIndex: '100000',
                              width: '90%',
                              maxWidth: '540px',
                              maxHeight: '80vh',
                              color: '#0f172a',
                              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
                              boxSizing: 'border-box',
                              display: 'flex',
                              flexDirection: 'column',
                              gap: '0.65rem',
                            },
                          }, [
            h(:div, {
                style: {
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  borderBottom: '1px solid #e2e8f0',
                  paddingBottom: '0.6rem',
                },
              }, [
              h(:h2, { style: { margin: '0', fontSize: '1.25rem', fontWeight: '800' } }, 'Other Games'),
              h(:button, {
                  attrs: { type: 'button', title: 'Close' },
                  style: {
                    background: 'none',
                    border: 'none',
                    fontSize: '1.3rem',
                    color: '#64748b',
                    cursor: 'pointer',
                    padding: '2px 6px',
                    lineHeight: '1',
                  },
                  on: { click: close_handler },
                }, '✕'),
            ]),
            h(:div, {
                style: {
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '0.45rem',
                  overflowY: 'auto',
                  maxHeight: '56vh',
                  paddingRight: '2px',
                },
              }, game_rows),
            h(:button, {
                attrs: { type: 'button' },
                style: {
                  width: '100%',
                  padding: '0.6rem',
                  fontSize: '0.9rem',
                  fontWeight: 'bold',
                  backgroundColor: '#f1f5f9',
                  color: '#334155',
                  border: '1px solid #cbd5e1',
                  borderRadius: '5px',
                  cursor: 'pointer',
                  marginTop: '0.35rem',
                },
                on: { click: close_handler },
              }, 'Close'),
          ])

          h(:div, [overlay_bg, overlay_box])
        end
      end
    end
  end
end
