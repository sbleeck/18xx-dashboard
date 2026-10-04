# frozen_string_literal: true

require 'lib/truncate'
require 'lib/settings'

module View
  module Game
    class DashboardEntityOrder < Snabberb::Component
      needs :round
      needs :game, store: true

      include Lib::Settings

      def render
        if @game.respond_to?(:finished?) && @game.finished?
          return h(:div,
                   { style: { display: 'flex', alignItems: 'center', padding: '0.5rem', fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif', fontWeight: 'bold', fontSize: '1.5rem', color: '#dc3545' } }, 'Game Over / Match Finished')
        end

        current_round = @round || @game.round
        header_text = if current_round.nil?
                        'Round'
                      elsif current_round.respond_to?(:stock?) && current_round.stock?
                        'Stock Round'
                      elsif current_round.respond_to?(:operating?) && current_round.operating?
                        curr_or = current_round.respond_to?(:round_num) ? current_round.round_num : 1
                        total_or = @game.respond_to?(:operating_rounds) ? @game.operating_rounds : 1
                        "Operating Round #{curr_or}/#{total_or}"
                      else
                        round_class_name = current_round.class.name.split('::').last
                        @game.round_description(round_class_name)
                      end

        is_or = (current_round.respond_to?(:operating?) && current_round.operating?) ||
                header_text.to_s.downcase.include?('operating')
        bg_color = is_or ? (current_phase_color || '#e0e0e0') : '#e0e0e0'
        text_color = auto_font_color(bg_color)

        header_el = h(:div, {
                        style: {
                          fontSize: '1.1rem',
                          padding: '0 0.85rem',
                          borderRadius: '4px',
                          backgroundColor: bg_color,
                          fontWeight: 'bold',
                          color: text_color,
                          fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
                          letterSpacing: '0.5px',
                          marginRight: '0.9rem',
                          display: 'inline-flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          alignSelf: 'stretch',
                          height: '100%',
                          minHeight: '2.5rem',
                          lineHeight: '1',
                          boxSizing: 'border-box',
                          flexShrink: '0',
                        },
                      }, header_text)

        row_children = [header_el]
        round_name = current_round.class.name.to_s
        is_text_only_round = (current_round.respond_to?(:stock?) && current_round.stock?) ||
                             (current_round.respond_to?(:draft?) && current_round.draft?) ||
                             round_name.include?('Stock') ||
                             round_name.include?('Draft') ||
                             round_name.include?('Auction')

        if !is_text_only_round && @round
          if @round.respond_to?(:context_entities)
            context_entities = @round.context_entities.dup
            active_context_entity = @round.active_context_entity
          elsif @round.respond_to?(:active_step) && @round.active_step.respond_to?(:context_entities)
            context_entities = @round.active_step.context_entities.dup
            active_context_entity = @round.active_step.active_context_entity
          end

          entities = if @round.respond_to?(:active_step) && @round.active_step.respond_to?(:override_entities)
                       @round.active_step.override_entities
                     elsif @round.respond_to?(:entities)
                       @round.entities
                     else
                       []
                     end.dup

          current_operating = @round.respond_to?(:current_entity) ? @round.current_entity : nil
          entities.unshift(current_operating) if current_operating && !entities.include?(current_operating)

          list_entities = context_entities || entities
          acting_entity = context_entities ? active_context_entity : current_operating

          is_player_list = list_entities.first.respond_to?(:player?) && list_entities.first.player?
          row_children.concat(build_marker_list(list_entities, acting_entity)) unless is_player_list
        end

        h(:div, {
            style: {
              display: 'flex',
              flexDirection: 'row',
              alignItems: 'center',
              flexWrap: 'nowrap',
              overflowX: 'auto',
              overflowY: 'hidden',
              gap: '0.3rem',
              padding: '0.2rem 0.5rem',
              height: '100%',
              minHeight: '2.5rem',
              boxSizing: 'border-box',
            },
          }, row_children)
      end

      private

      def current_phase_color
        return nil unless @game&.phase

        phase = @game.phase
        color_sym = if phase.respond_to?(:color) && phase.color
                      phase.color.to_s.downcase.to_sym
                    elsif phase.respond_to?(:tiles) && phase.tiles&.any?
                      phase.tiles.last.to_s.downcase.to_sym
                    elsif phase.respond_to?(:name)
                      name = phase.name.to_s.downcase
                      if name.include?('yellow') || name == '2'
                        :yellow
                      elsif name.include?('green') || %w[3 3.5 4].include?(name)
                        :green
                      elsif name.include?('brown') || %w[5 6].include?(name)
                        :brown
                      elsif name.include?('gray') || name.include?('grey') || %w[7 8 d e].include?(name)
                        :gray
                      end
                    end

        return nil unless color_sym

        begin
          color_for(color_sym, @game) || color_for(color_sym)
        rescue StandardError
          nil
        end
      end

      def auto_font_color(bg_color)
        begin
          c = contrast_on(bg_color)
          return c if c
        rescue StandardError
        end

        hex = bg_color.to_s.sub('#', '')
        return '#ffffff' unless hex.length == 6

        r = hex[0..1].to_i(16)
        g = hex[2..3].to_i(16)
        b = hex[4..5].to_i(16)
        luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
        luminance > 160 ? '#000000' : '#ffffff'
      end

      def build_marker_list(entities, acting_entity)
        elements = []
        finished_entities = @round.respond_to?(:finished_entities) ? @round.finished_entities : []

        entities.each_with_index do |entity, index|
          next unless entity

          is_active = entity == acting_entity
          has_operated = finished_entities.include?(entity) ||
                         (entities.index(acting_entity) && index < entities.index(acting_entity) && !is_active)

          logo_src = begin
            setting_for(:simple_logos, @game) ? entity.simple_logo : entity.logo
          rescue StandardError
            nil
          end

          corp_color = entity.respond_to?(:color) && entity.color ? entity.color : '#ffffff'
          text_color = entity.respond_to?(:text_color) && entity.text_color ? entity.text_color : '#000000'

          marker_style = {
            width: '24px',
            height: '24px',
            borderRadius: '50%',
            boxSizing: 'border-box',
            display: 'inline-block',
            border: '1px solid #333333',
            backgroundColor: corp_color,
            color: text_color,
            textAlign: 'center',
            lineHeight: '22px',
            fontSize: '0.65rem',
            fontWeight: 'bold',
            verticalAlign: 'middle',
            overflow: 'hidden',
          }

          marker_content = if logo_src
                             h(:img, {
                                 attrs: { src: logo_src },
                                 style: {
                                   width: '100%',
                                   height: '100%',
                                   display: 'block',
                                 },
                               })
                           else
                             display_text = entity.respond_to?(:id) ? entity.id.to_s[0..2] : entity.to_s[0..2]
                             h(:span, display_text)
                           end

          item_style = {
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            borderRadius: '50%',
            padding: '4px',
            transition: 'all 0.2s ease',
          }

          if is_active
            item_style[:backgroundColor] = '#f8d7da'
            item_style[:border] = '2px solid #dc3545'
          elsif has_operated
            item_style[:opacity] = '0.4'
          end

          elements << h(:div, { style: item_style }, [h(:div, { style: marker_style }, [marker_content])])

          next unless index < entities.size - 1

          elements << h(:span, {
                          style: {
                            margin: '0 0.1rem',
                            color: '#868e96',
                            fontWeight: 'bold',
                            fontSize: '1rem',
                            alignSelf: 'center',
                          },
                        }, '→')
        end

        elements
      end
    end
  end
end
