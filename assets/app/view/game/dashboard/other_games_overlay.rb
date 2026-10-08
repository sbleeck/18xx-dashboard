# frozen_string_literal: true

require 'lib/storage'

module View
  module Game
    module Dashboard
      class OtherGamesOverlay < Snabberb::Component
        needs :game
        needs :user, default: nil
        needs :user_id, default: nil
        needs :on_close, default: nil

        def render
          close_handler = lambda do |e|
            `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
            @on_close&.call
          end

          raw_games = `window._user_games_cache || []`
          games_list = Array(Native(raw_games)) if raw_games

          if games_list.empty?
            raw_ls = `localStorage.getItem('all_user_games') || '[]'`
            games_list = begin
              JSON.parse(raw_ls)
            rescue StandardError
              []
            end
          end

          curr_id = (@game.respond_to?(:id) ? @game.id : nil)&.to_s
          uid = @user_id.to_s

          active_games = games_list.select do |g|
            status = (g.is_a?(Hash) ? (g['status'] || g[:status]) : 'active').to_s
            status == 'active' || status.empty?
          end

          sorted_games = active_games.sort_by do |g|
            gid = (g.is_a?(Hash) ? (g['id'] || g[:id]) : g).to_s
            acting = g.is_a?(Hash) ? (g['acting'] || g[:acting]) : nil
            is_my_turn = acting.is_a?(Array) && acting.map(&:to_s).include?(uid)
            is_current = (gid == curr_id)

            if is_my_turn && !is_current
              0
            elsif is_my_turn && is_current
              1
            elsif is_current
              2
            else
              3
            end
          end

          game_content = if sorted_games.empty?
                           [
                             h(:div, {
                                 style: {
                                   padding: '2.5rem 1rem',
                                   textAlign: 'center',
                                   color: '#64748b',
                                   fontStyle: 'italic',
                                   fontSize: '0.95rem',
                                 },
                               }, 'No active games found or loading from server...'),
                           ]
                         else
                           sorted_games.map do |g|
                             gid = (g.is_a?(Hash) ? (g['id'] || g[:id]) : g).to_s
                             title = (g.is_a?(Hash) ? (g['title'] || g[:title]) : '18xx').to_s
                             round = (g.is_a?(Hash) ? (g['round'] || g[:round]) : '').to_s
                             desc = (g.is_a?(Hash) ? (g['description'] || g[:description]) : '').to_s
                             acting = g.is_a?(Hash) ? (g['acting'] || g[:acting]) : nil
                             is_my_turn = acting.is_a?(Array) && acting.map(&:to_s).include?(uid)
                             is_current = (gid == curr_id)

                             badge_bg = if is_my_turn
                                          '#16a34a'
                                        elsif is_current
                                          '#64748b'
                                        else
                                          '#e2e8f0'
                                        end

                             badge_color = if is_my_turn || is_current
                                             '#ffffff'
                                           else
                                             '#475569'
                                           end

                             badge_text = if is_my_turn && is_current
                                            '★ YOUR TURN (Here)'
                                          elsif is_my_turn
                                            '★ YOUR TURN'
                                          elsif is_current
                                            'Current Game'
                                          else
                                            'Waiting'
                                          end

                             border_style = if is_my_turn
                                              '2px solid #16a34a'
                                            elsif is_current
                                              '2px solid #94a3b8'
                                            else
                                              '1px solid #cbd5e1'
                                            end

                             card_bg = if is_my_turn
                                         '#f0fdf4'
                                       elsif is_current
                                         '#f8fafc'
                                       else
                                         '#ffffff'
                                       end

                             click_row = lambda do |e|
                               `if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();`
                               if is_current
                                 close_handler.call(e)
                               else
                                 `window.location.href = '/game/' + #{gid} + '#dashboard'`
                               end
                             end

                             h(:div, {
                                 attrs: { title: is_current ? 'Current match' : "Open Game ##{gid} Dashboard" },
                                 style: {
                                   display: 'flex',
                                   flexDirection: 'row',
                                   alignItems: 'center',
                                   justifyContent: 'space-between',
                                   padding: '0.7rem 0.9rem',
                                   border: border_style,
                                   borderRadius: '6px',
                                   backgroundColor: card_bg,
                                   cursor: is_current ? 'default' : 'pointer',
                                   boxShadow: '0 1px 3px rgba(0, 0, 0, 0.05)',
                                   transition: 'background-color 0.15s ease',
                                 },
                                 on: { click: click_row },
                               }, [
                                 h(:div, { style: { display: 'flex', flexDirection: 'column', gap: '0.2rem', minWidth: '0' } }, [
                                   h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', flexWrap: 'wrap' } }, [
                                     h(:strong, { style: { fontSize: '1.05rem', color: '#0f172a' } }, "#{title} (##{gid})"),
                                     (if !round.empty?
                                        h(:span,
                                          { style: { fontSize: '0.8rem', color: '#64748b', fontWeight: '600' } }, "• #{round}")
                                      else
                                        nil
                                      end),
                                   ].compact),
                                   (if !desc.empty?
                                      h(:span,
                                        { style: { fontSize: '0.78rem', color: '#64748b', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '340px' } }, desc)
                                    else
                                      nil
                                    end),
                                 ].compact),
                                 h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.6rem', flexShrink: '0' } }, [
                                   h(:span, {
                                       style: {
                                         fontSize: '0.74rem',
                                         fontWeight: 'bold',
                                         padding: '3px 8px',
                                         borderRadius: '12px',
                                         backgroundColor: badge_bg,
                                         color: badge_color,
                                         letterSpacing: '0.3px',
                                       },
                                     }, badge_text),
                                   (if !is_current
                                      h(:span,
                                        { style: { fontSize: '1.1rem', color: '#0284c7', fontWeight: 'bold' } }, '→')
                                    else
                                      nil
                                    end),
                                 ].compact),
                               ])
                           end
                         end

          header = h(:div, {
                       style: {
                         display: 'flex',
                         justifyContent: 'space-between',
                         alignItems: 'center',
                         borderBottom: '1px solid #e2e8f0',
                         paddingBottom: '0.75rem',
                         marginBottom: '0.3rem',
                       },
                     }, [
            h(:h2, { style: { margin: '0', fontSize: '1.3rem', fontWeight: '800', color: '#0f172a' } }, 'Other Games'),
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
          ])

          close_btn = h(:button, {
                          attrs: { type: 'button' },
                          style: {
                            width: '100%',
                            padding: '0.65rem',
                            fontSize: '0.95rem',
                            fontWeight: 'bold',
                            backgroundColor: '#f1f5f9',
                            color: '#334155',
                            border: '1px solid #cbd5e1',
                            borderRadius: '6px',
                            cursor: 'pointer',
                            marginTop: '0.4rem',
                          },
                          on: { click: close_handler },
                        }, 'Close')

          overlay_box = h(:div, {
                            style: {
                              position: 'fixed',
                              top: '50%',
                              left: '50%',
                              transform: 'translate(-50%, -50%)',
                              backgroundColor: '#ffffff',
                              padding: '1.5rem',
                              borderRadius: '8px',
                              boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(0, 0, 0, 0.1)',
                              zIndex: '100000',
                              width: '90%',
                              maxWidth: '560px',
                              maxHeight: '82vh',
                              color: '#0f172a',
                              fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
                              boxSizing: 'border-box',
                              display: 'flex',
                              flexDirection: 'column',
                              gap: '0.65rem',
                            },
                          }, [
            header,
            h(:div, {
                style: {
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '0.5rem',
                  overflowY: 'auto',
                  maxHeight: '58vh',
                  paddingRight: '3px',
                },
              }, game_content),
            close_btn,
          ])

          overlay_bg = h(:div, {
                           style: {
                             position: 'fixed',
                             top: '0',
                             left: '0',
                             width: '100vw',
                             height: '100vh',
                             backgroundColor: 'rgba(0, 0, 0, 0.65)',
                             zIndex: '99999',
                             cursor: 'pointer',
                           },
                           on: { click: close_handler },
                         })

          h(:div, [overlay_bg, overlay_box])
        end
      end
    end
  end
end
