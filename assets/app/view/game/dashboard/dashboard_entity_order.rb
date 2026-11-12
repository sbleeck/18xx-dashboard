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
          return h(:div, { style: { display: 'flex', alignItems: 'center', padding: '0.5rem', fontWeight: 'bold', fontSize: '1.2rem', color: '#dc3545' } }, 'Game Over / Match Finished')
        end

        current_round = @round || @game.round
        header_el = render_round_timeline(current_round)
        round_name = current_round.class.name.to_s
        is_text_only = (current_round.respond_to?(:stock?) && current_round.stock?) ||
                       (current_round.respond_to?(:draft?) && current_round.draft?) ||
                       round_name.match?(/Stock|Draft|Auction/i)

        marker_elements = []
        if !is_text_only && @round
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
          marker_elements = build_marker_list(list_entities, acting_entity) unless is_player_list
        end
        tokens_track = h(:div, {
                           attrs: { class: 'entity-tokens-track' },
                           style: {
                             display: 'flex', flexDirection: 'row', alignItems: 'center', flexWrap: 'nowrap',
                             overflowX: 'auto', overflowY: 'hidden', flex: '1 1 auto', minWidth: '0',
                             height: '2.85rem', gap: '0.3rem', padding: '0.2rem 0.5rem 0.2rem 0.85rem', boxSizing: 'border-box',
                           },
                         }, marker_elements)

        h(:div, {
            style: { display: 'flex', flexDirection: 'row', alignItems: 'center', width: '100%', height: '100%', minWidth: '0', overflow: 'hidden', boxSizing: 'border-box' },
          }, [header_el, tokens_track])
      end
      private

      def render_round_timeline(current_round)
        phase_bg = current_phase_color || '#f6e652'
        phase_fg = auto_font_color(phase_bg)
        active_or = [@game.respond_to?(:operating_rounds) ? @game.operating_rounds.to_i : 1, 1].max
        phases_list = @game&.phase.respond_to?(:phases) ? @game.phase.phases : []
        max_or = [phases_list.map { |ph| (ph.is_a?(Hash) ? ph[:operating_rounds] : ph.operating_rounds).to_i }.max || 1, active_or].max
        has_ma = @game.respond_to?(:merge_rounds)
        is_stock = current_round&.respond_to?(:stock?) && current_round.stock?
        is_operating = current_round&.respond_to?(:operating?) && current_round.operating?
        rc = current_round ? current_round.class.name.split('::').last : ''
        is_auc = !is_stock && !is_operating && rc.match?(/Auction|Draft|Waterfall|Initial/i)
        is_spec = !is_stock && !is_operating && !is_auc && !current_round.nil?
        curr_or = current_round.respond_to?(:round_num) ? current_round.round_num.to_i : 0
        nodes = []
        if is_auc
          nodes << { label: rc.include?('Draft') ? 'Draft' : 'Auction', title: @game.round_description(rc), state: :active }
        end
        (1..max_or).each do |i|
          unused = i > active_or
          st = if unused then :unused
               elsif is_auc then :upcoming
               elsif is_operating then (i < curr_or ? :done : (i == curr_or ? :active : :upcoming))
               elsif is_stock then :done
               else (i <= curr_or ? :done : :upcoming)
               end
          nodes << { label: "OR#{i}", title: unused ? "OR #{i} (Later phase)" : "Operating Round #{i}/#{active_or}", state: st }
          next unless has_ma && !unused

          ma_st = if is_auc then :upcoming
                  elsif is_operating then (i < curr_or ? :done : :upcoming)
                  elsif is_stock then :done
                  elsif is_spec then (i < curr_or ? :done : (i == curr_or ? :active : :upcoming))
                  else :upcoming
                  end
          nodes << { label: 'MA', title: 'Merger and Acquisition Round', state: ma_st }
        end
        if is_spec && !has_ma
          desc = begin; @game.round_description(rc); rescue StandardError; rc; end
          lbl = rc.include?('Merger') || desc.match?(/Merger|Formation|Prussian|CGR/i) ? 'M' : rc[0..2].upcase
          idx = nodes.rindex { |n| n[:state] == :done }
          nodes.insert(idx ? idx + 1 : nodes.size, { label: lbl, title: desc, state: :active })
        end
        nodes << { label: 'SR', title: 'Stock Round', state: is_stock ? :active : :upcoming }
        items = []
        nodes.each_with_index do |nd, idx|
          st = nd[:state]
          bg = st == :active ? phase_bg : (st == :done ? '#e2e8f0' : (st == :unused ? '#f1f5f9' : '#ffffff'))
          fg = st == :active ? phase_fg : (st == :done ? '#64748b' : (st == :unused ? '#94a3b8' : '#1e293b'))
          bd = st == :active ? '2px solid #0f172a' : (st == :done ? '1px solid #cbd5e1' : (st == :unused ? '1px dashed #cbd5e1' : '1.5px solid #94a3b8'))
          sty = { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', height: '1.85rem', minWidth: '2.35rem', padding: '0 0.45rem', borderRadius: '5px', backgroundColor: bg, color: fg, border: bd, fontSize: '0.78rem', fontWeight: st == :active ? '800' : '600', opacity: st == :done ? '0.65' : '1.0', boxSizing: 'border-box', whiteSpace: 'nowrap' }
          items << h(:div, { attrs: { title: nd[:title] }, style: sty }, nd[:label])
          items << h(:div, { style: { width: '10px', borderTop: st == :done ? '2px solid #64748b' : '2px dashed #cbd5e1', flexShrink: '0' } }) if idx < nodes.size - 1
        end
        h(:div, { attrs: { id: 'round-phase-timeline' }, style: { display: 'inline-flex', alignItems: 'center', height: '100%', padding: '0 0.85rem', backgroundColor: '#ffffff', borderRight: '2px solid #cbd5e1', boxSizing: 'border-box', flexShrink: '0' } }, items)
      end

      def current_phase_color
        return nil unless @game&.phase
        ph = @game.phase
        sym = ph.respond_to?(:color) && ph.color ? ph.color : (ph.respond_to?(:tiles) && ph.tiles&.last)
        return nil unless sym
        color_for(sym.to_s.downcase.to_sym, @game) || color_for(sym.to_s.downcase.to_sym)
      rescue StandardError
        nil
      end
      def auto_font_color(bg_color)
        c = contrast_on(bg_color)
        return c if c
      rescue StandardError
        hex = bg_color.to_s.sub('#', '')
        return '#ffffff' unless hex.length == 6

        r, g, b = hex[0..1].to_i(16), hex[2..3].to_i(16), hex[4..5].to_i(16)
        ((0.299 * r) + (0.587 * g) + (0.114 * b)) > 160 ? '#000000' : '#ffffff'
      end

      def build_marker_list(entities, acting_entity)
        out = []
        fin = @round.respond_to?(:finished_entities) ? @round.finished_entities : []
        entities.each_with_index do |ent, idx|
          next unless ent

          act = ent == acting_entity
          done = fin.include?(ent) || (entities.index(acting_entity) && idx < entities.index(acting_entity) && !act)
          src = begin; setting_for(:simple_logos, @game) ? ent.simple_logo : ent.logo; rescue StandardError; nil; end
          bg = ent.respond_to?(:color) && ent.color ? ent.color : '#ffffff'
          fg = ent.respond_to?(:text_color) && ent.text_color ? ent.text_color : '#000000'
          ms = { width: '24px', height: '24px', borderRadius: '50%', boxSizing: 'border-box', display: 'inline-block', border: '1px solid #333', backgroundColor: bg, color: fg, textAlign: 'center', lineHeight: '22px', fontSize: '0.65rem', fontWeight: 'bold', overflow: 'hidden', cursor: 'pointer', pointerEvents: 'auto' }
          cid = (ent.respond_to?(:id) ? ent.id : ent).to_s
          cnt = src ? h(:img, { attrs: { src: src }, style: { width: '100%', height: '100%', display: 'block' } }) : h(:span, cid[0..2])
          is = { display: 'inline-flex', alignItems: 'center', justifyContent: 'center', borderRadius: '50%', padding: '4px' }
          if act
            is[:backgroundColor] = '#f8d7da'
            is[:border] = '2px solid #dc3545'
          elsif done
            is[:opacity] = '0.4'
          end
          out << h(:div, { style: is }, [h(:div, { attrs: { class: 'entity-order-token', 'data-corp': cid }, style: ms }, [cnt])])
          out << h(:span, { style: { margin: '0 0.1rem', color: '#868e96', fontWeight: 'bold', fontSize: '1rem', alignSelf: 'center' } }, '→') if idx < entities.size - 1
        end
        out
      end
    end
  end
end
