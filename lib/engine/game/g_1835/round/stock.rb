<<<<<<< HEAD
# lib/engine/game/g_1835/round/stock.rb
# frozen_string_literal: true

require_relative '../../../round/stock'

=======
# frozen_string_literal: true

require_relative '../../../round/stock'
>>>>>>> upstream/master
module Engine
  module Game
    module G1835
      module Round
        class Stock < Engine::Round::Stock
<<<<<<< HEAD
          def setup
            @game.conversion_choice_during_or = false
=======
          attr_accessor :turns_since_last_purchase

          def setup
            @turns_since_last_purchase = 0
            super
          end

          def finished?
            super || @turns_since_last_purchase > @entities.size
          end

          def next_entity_index!
            @turns_since_last_purchase += 1
>>>>>>> upstream/master
            super
          end
        end
      end
    end
  end
end
