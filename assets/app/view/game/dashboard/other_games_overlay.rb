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
          close_handler = lambda do |e = nil|
            %x{
              if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();
              try {
                localStorage.removeItem('show_other_games_overlay');
              } catch(err) {}
            }
            Lib::Storage['show_other_games_overlay'] = nil
            @on_close&.call
          end

          curr_id = (@game.respond_to?(:id) ? @game.id : nil).to_s
          uid = @user_id.to_s

          raw_games = %x{
            (function() {
              var raw = window._user_games_cache;
              if (!raw || !Array.isArray(raw)) {
                try {
                  raw = JSON.parse(localStorage.getItem('all_user_games') || '[]');
                } catch(e) {
                  raw = [];
                }
              }
              if (!Array.isArray(raw)) return [];

              var myId = parseInt(#{uid}, 10);
              var curId = parseInt(#{curr_id}, 10);

              var filtered = raw.filter(function(g) {
                if (!g) return false;

                // 1. Exclude finished or archived games
                var status = String(g.status || '').toLowerCase();
                if (status && status !== 'active') return false;
                if (g.finished_at || g.finished) return false;

                // 2. Only include games where you are an active player
                if (g.players && Array.isArray(g.players)) {
                  return g.players.some(function(p) {
                    if (!p) return false;
                    var pid = p.id !== undefined ? p.id : (p.user ? p.user.id : null);
                    return parseInt(pid, 10) === myId;
                  });
                }
                return false;
              });

              return filtered.map(function(g) {
                var isMyTurn = Boolean(g.acting && Array.isArray(g.acting) && g.acting.some(function(actId) {
                  return parseInt(actId, 10) === myId;
                }));
                var isCurrent = (parseInt(g.id, 10) === curId);

                return {
                  id: String(g.id || ''),
                  title: String(g.title || '18xx'),
                  round: String(g.round || ''),
                  desc: String(g.description || ''),
                  is_my_turn: isMyTurn ? 1 : 0,
                  is_current: isCurrent ? 1 : 0
                };
              }).sort(function(a, b) {
                var orderA = (a.is_my_turn === 1 && a.is_current === 0) ? 0 : (a.is_my_turn === 1 ? 1 : (a.is_current === 1 ? 2 : 3));
                var orderB = (b.is_my_turn === 1 && b.is_current === 0) ? 0 : (b.is_my_turn === 1 ? 1 : (b.is_current === 1 ? 2 : 3));
                return orderA - orderB;
              });
            })()
          }

          game_rows = []
          %x{
            if (Array.isArray(raw_games)) {
              for (var i = 0; i < raw_games.length; i++) {
                (function(item) {
                  var gid = item.id;
                  var title = item.title;
                  var round = item.round;
                  var desc = item.desc;
                  var isTurn = (item.is_my_turn === 1);
                  var isCur = (item.is_current === 1);

                  var cardBg = isTurn ? '#f0fdf4' : (isCur ? '#f8fafc' : '#ffffff');
                  var borderStyle = isTurn ? '2px solid #16a34a' : (isCur ? '2px solid #94a3b8' : '1px solid #cbd5e1');
                  var badgeBg = isTurn ? '#16a34a' : (isCur ? '#64748b' : '#e2e8f0');
                  var badgeColor = (isTurn || isCur) ? '#ffffff' : '#475569';
                  var badgeText = (isTurn && isCur) ? '★ YOUR TURN (Here)' : (isTurn ? '★ YOUR TURN' : (isCur ? 'Current' : 'Waiting'));

                 var clickRow = function(e) {
                    if (e && e.stopPropagation) e.stopPropagation();
                    #{close_handler.call};
                    if (!isCur) {
                      window.location.href = '/game/' + gid + '#dashboard';
                    }
                  };

                  var descNode = desc ? #{h(:span,
                                            { style: { fontSize: '0.75rem', color: '#64748b', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '320px' } }, `desc`)} : null;
                  var roundNode = round ? #{h(:span, { style: { fontSize: '0.78rem', color: '#64748b', fontWeight: '600' } },
                                              `('• ' + round)`)} : null;

                  var rowNode = #{
                    h(:div, {
                        attrs: { title: `isCur ? 'Current game' : ('Open Game #' + gid + ' Dashboard')` },
                        style: {
                          display: 'flex',
                          flexDirection: 'row',
                          alignItems: 'center',
                          justifyContent: 'space-between',
                          padding: '0.65rem 0.85rem',
                          borderRadius: '6px',
                          cursor: `isCur ? 'default' : 'pointer'`,
                          backgroundColor: `cardBg`,
                          border: `borderStyle`,
                          boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                          transition: 'background-color 0.15s ease',
                        },
                        on: { click: ->(e) { `clickRow(#{e})` } },
                      }, [
                        h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.15rem', minWidth: '0' } }, [
                          h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.45rem', flexWrap: 'wrap' } }, [
                            h(:strong, { style: { fontSize: '1rem', color: '#0f172a' } }, `title + ' (#' + gid + ')'`),
                            `roundNode`,
                          ].compact),
                          `descNode`,
                        ].compact),
                        h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', flexShrink: '0' } }, [
                          h(:span, {
                              style: {
                                fontSize: '0.72rem',
                                fontWeight: 'bold',
                                padding: '2px 8px',
                                borderRadius: '10px',
                                backgroundColor: `badgeBg`,
                                color: `badgeColor`,
                              },
                            }, `badgeText`),
                          (!`isCur` ? h(:span, { style: { fontSize: '1rem', color: '#0284c7', fontWeight: 'bold' } }, '→') : nil),
                        ].compact),
                      ])
                  };
                  #{game_rows << `rowNode`};
                })(raw_games[i]);
              }
            }
          }

          if game_rows.empty?
            game_rows << h(:div, {
                             style: {
                               padding: '2rem 1rem',
                               textAlign: 'center',
                               color: '#64748b',
                               fontStyle: 'italic',
                               fontSize: '0.9rem',
                             },
                           }, 'No active games found where you are a player.')
          end

          overlay_bg = h(:div, {
                           attrs: { id: 'other-games-overlay-backdrop' },
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
                            attrs: { id: 'other-games-overlay-dialog' },
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
