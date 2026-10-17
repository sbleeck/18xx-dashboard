# frozen_string_literal: true

module View
  module Game
    module Dashboard
      class ResultsOverlay < Snabberb::Component
        needs :game

        def render
          sorted_players = @game.players.sort_by do |p|
            if @game.respond_to?(:player_value)
              @game.player_value(p)
            elsif @game.respond_to?(:result) && @game.result && @game.result[p]
              @game.result[p]
            else
              p.cash
            end
          end

          # Enforce starting at 0 for step-by-step reveal
          reveal_index = Lib::Storage['results_reveal_index']
          if reveal_index.nil?
            reveal_index = 0
            Lib::Storage['results_reveal_index'] = 0
          else
            reveal_index = reveal_index.to_i
          end

          total_players = sorted_players.size
          reveal_index = total_players if reveal_index > total_players

          # Take only the revealed slice (starting with the last place player)
          revealed_players = sorted_players.take(reveal_index).reverse

          children = []
          children << h(:h2, { style: { textAlign: 'center', margin: '0 0 1rem 0' } }, 'Final Results')

          revealed_players.each do |player|
            place = total_players - sorted_players.index(player)
            val = if @game.respond_to?(:player_value)
                    @game.player_value(player)
                  elsif @game.respond_to?(:result) && @game.result && @game.result[player]
                    @game.result[player]
                  else
                    player.cash
                  end
            formatted_val = @game.format_currency(val)

            is_winner = place == 1

            row_style = {
              display: 'flex',
              justifyContent: 'space-between',
              padding: is_winner ? '0.75rem 0.5rem' : '0.5rem',
              borderBottom: '1px solid #ccc',
              fontSize: is_winner ? '1.4rem' : '1.2rem',
              fontWeight: is_winner ? 'bold' : 'normal',
              backgroundColor: is_winner ? '#fef3c7' : 'transparent',
              color: is_winner ? '#92400e' : 'inherit',
              borderRadius: is_winner ? '4px' : '0',
            }

            row = h(:div, { style: row_style }, [
              h(:span, "#{place}. #{player.name}#{' 👑' if is_winner}"),
              h(:span, formatted_val),
            ])
            children << row
          end

          reveal_handler = lambda do |e|
            e.JS.stopPropagation if e
            if reveal_index < total_players
              Lib::Storage['results_reveal_index'] = reveal_index + 1
              update
            end
          end

          if reveal_index < total_players
            place_to_reveal = total_players - reveal_index
            place_str = place_to_reveal == 1 ? 'Winner 👑' : "#{place_to_reveal}#{ordinal_suffix(place_to_reveal)} Place"

            children << h(:button, {
                            style: {
                              width: '100%',
                              padding: '1rem',
                              marginTop: '1rem',
                              fontSize: '1.2rem',
                              backgroundColor: '#007bff',
                              color: 'white',
                              border: 'none',
                              borderRadius: '4px',
                              cursor: 'pointer',
                              fontWeight: 'bold',
                            },
                            on: { click: reveal_handler },
                          }, "Click to Reveal #{place_str}")
          else
            close_handler = lambda do |e|
              e.JS.stopPropagation if e
              Lib::Storage['show_results_overlay'] = false
              Lib::Storage['results_reveal_index'] = 0
              update
            end
            children << h(:button, {
                            style: { width: '100%', padding: '0.5rem', marginTop: '1rem', fontSize: '1rem', cursor: 'pointer' },
                            on: { click: close_handler },
                          }, 'Close')
          end

          overlay_click_handler = reveal_index < total_players ? reveal_handler : nil

          overlay_bg = h(:div, {
                           style: {
                             position: 'fixed',
                             top: '0',
                             left: '0',
                             width: '100vw',
                             height: '100vh',
                             backgroundColor: 'rgba(0,0,0,0.65)',
                             zIndex: '9999',
                             cursor: reveal_index < total_players ? 'pointer' : 'default',
                           },
                           on: overlay_click_handler ? { click: overlay_click_handler } : {},
                         })

          overlay_box = h(:div, {
                            style: {
                              position: 'fixed',
                              top: '50%',
                              left: '50%',
                              transform: 'translate(-50%, -50%)',
                              backgroundColor: 'white',
                              padding: '2rem',
                              borderRadius: '8px',
                              boxShadow: '0 4px 15px rgba(0,0,0,0.3)',
                              zIndex: '10000',
                              width: '80%',
                              maxWidth: '500px',
                              color: 'black',
                              cursor: reveal_index < total_players ? 'pointer' : 'default',
                            },
                            on: overlay_click_handler ? { click: overlay_click_handler } : {},
                          }, children)

          h(:div, [overlay_bg, overlay_box])
        end

        def ordinal_suffix(number)
          return 'th' if (11..13).cover?(number % 100)

          case number % 10
          when 1 then 'st'
          when 2 then 'nd'
          when 3 then 'rd'
          else; 'th'
          end
        end
      end
    end
  end
end
