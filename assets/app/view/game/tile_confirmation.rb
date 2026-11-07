# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'

module View
  module Game
    class TileConfirmation < Snabberb::Component
      include Actionable
      include Lib::Settings

      needs :tile_selector, store: true
      needs :zoom, default: 1
      needs :large, default: false

      def render
        if @large
          button_style = {
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: 'pointer',

            width: '76px',
            height: '76px',
            minWidth: '76px',
            minHeight: '76px',

            padding: '0',
            margin: '0',

            border: '4px solid #111827',
            borderRadius: '12px',

            fontSize: '44px',
            lineHeight: '1',
            fontWeight: '900',

            color: '#FFFFFF',

            boxShadow:
              '0 0 0 3px #ffffff, ' \
              '0 6px 12px rgba(0, 0, 0, 0.65)',
          }

          panel_style = {
            display: 'grid',
            gridAutoFlow: 'column',
            gridGap: '18px',

            position: 'absolute',
            left: '-92px',
            top: "#{-116 * @zoom}px",

            padding: '15px',

            backgroundColor: '#fffdf5',
            border: '4px solid #111827',
            borderRadius: '18px',

            boxShadow:
              '0 0 0 4px rgba(255, 255, 255, 0.95), ' \
              '0 8px 18px rgba(0, 0, 0, 0.65)',

            zIndex: '250',
          }
        else
          button_style = {
            display: 'inline-block',
            cursor: 'pointer',
            fontSize: '35px',
            color: '#FFFFFF',
            filter: 'drop-shadow(3px 3px 2px #888)',
            padding: '6px 2px 8px 2px',
          }

          panel_style = {
            display: 'grid',
            gridAutoFlow: 'column',
            gridGap: '5px',
            position: 'absolute',
            left: '-38px',
            top: "#{-68 * @zoom}px",
          }
        end

        confirm = {
          props: {
            innerHTML: '&#10004;',
            title: 'Confirm tile placement',
          },
          attrs: {
            'aria-label': 'Confirm tile placement',
          },
          style: {
            backgroundColor: default_for(:green),
            **button_style,
          },
          on: {
            click: confirm_click,
          },
        }

        cancel = {
          props: {
            innerHTML: '&#10006;',
            title: 'Cancel tile placement',
          },
          attrs: {
            'aria-label': 'Cancel tile placement',
          },
          style: {
            backgroundColor: default_for(:red),
            **button_style,
          },
          on: {
            click: -> { store(:tile_selector, nil) },
          },
        }

        h(
          :div,
          {
            attrs: {
              class: @large ?
                'dashboard-tile-confirmation' :
                'tile-confirmation',
            },
            style: panel_style,
          },
          [
            h('button.no_margin', cancel),
            h('button.no_margin', confirm),
          ]
        )
      end

      def confirm_click
        entity = @tile_selector.entity
        tile = @tile_selector.tile
        hex = @tile_selector.hex

        lay_tile_lambda = -> { lay_tile(entity, tile, hex) }

        # If there are 1+ "blocks_hexes_consent" abilities on this hex, get
        # consent from one of the players
        blocking_players = (@game.companies + @game.minors + @game.corporations).each_with_object([]) do |company, players|
          next if company.closed?
          next unless (ability = @game.abilities(company, :blocks_hexes_consent))
          next unless @game.hex_blocked_by_ability?(entity, ability, hex, tile)

          players << company.owner
        end

        if blocking_players.empty?
          lay_tile_lambda
        else
          -> { check_consent(entity, blocking_players, lay_tile_lambda) }
        end
      end

      def lay_tile(entity, tile, hex)
        action = Engine::Action::LayTile.new(
          entity,
          tile: tile,
          hex: hex,
          rotation: tile.rotation,
          combo_entities: @selected_combos.map { |id| @game.company_by_id(id) },
        )
        store(:tile_selector, nil, skip: true)
        store(:selected_combos, [], skip: true)
        process_action(action)
      end
    end
  end
end
