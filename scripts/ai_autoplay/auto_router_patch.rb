# frozen_string_literal: true

# CRuby-only synchronous route-combination support for the autoplay harness.
#
# The normal Engine::AutoRouter performs its route-combination search in
# embedded JavaScript under Opal. The command-line autoplay harness runs under
# CRuby, where that JavaScript cannot execute.
#
# This file loads the standard engine AutoRouter and overrides only #route.
# Path discovery remains entirely engine-owned through AutoRouter#path.
#
# This patch is loaded only by scripts/ai_autoplay/autoplay.rb. It therefore
# does not alter browser/dashboard behaviour.

# The upstream AutoRouter contains Opal JavaScript in %x{...}.
# Under CRuby, %x invokes Kernel#` and would try to execute that JavaScript
# through the shell.
#
# Temporarily suppress backtick execution only while loading AutoRouter.
# The original Kernel#` implementation is restored immediately afterwards.
module Kernel
  alias ai_autoplay_original_backtick `

  def `(_command)
    ''
  end
end

begin
  require_relative '../../lib/engine/auto_router'
ensure
  module Kernel
    alias ` ai_autoplay_original_backtick
    remove_method :ai_autoplay_original_backtick
  end
end

module AiAutoplay
  module AutoRouterPatch
    def route(trains_to_routes, callback)
      return super if RUBY_ENGINE == 'opal'

      route_cruby(
        trains_to_routes,
        callback
      )
    end

    private

    def route_cruby(trains_to_routes, callback)
      timeout_seconds =
        if defined?(@route_timeout) && @route_timeout
          @route_timeout.to_f
        else
          10.0
        end

      timeout_seconds = 10.0 unless timeout_seconds.positive?

      deadline =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) + timeout_seconds

      train_entries =
        Array(trains_to_routes).map do |train, routes|
          valid_routes =
            Array(routes)
              .compact
              .select do |route|
                route.respond_to?(:revenue)
              end
              .sort_by do |route|
                -safe_route_revenue(route)
              end

          [
            train,
            valid_routes,
          ]
        end

      if train_entries.empty?
        self.running = false if respond_to?(:running=)

        callback&.call([])

        return []
      end

      train_groups =
        build_train_groups(
          train_entries
        )

      maximum_group =
        train_groups.values.max || 0

      empty_bitfields =
        Array.new(
          maximum_group + 1
        ) do
          []
        end

      maximum_remaining =
        build_maximum_remaining(
          train_entries
        )

      best_routes = []
      best_revenue = 0

      search = nil

      search =
        lambda do |index, chosen_routes, grouped_bitfields, estimated_revenue|
          return if route_search_expired?(deadline)

          if index >= train_entries.size
            revenue =
              real_revenue(
                chosen_routes
              )

            if revenue > best_revenue
              best_revenue = revenue

              best_routes =
                chosen_routes.map do |route|
                  route.clone
                end
            end

            return
          end

          optimistic_revenue =
            estimated_revenue +
            maximum_remaining[index]

          return if optimistic_revenue <= best_revenue

          train,
          routes =
            train_entries[index]

          group =
            train_groups.fetch(
              train,
              0
            )

          existing_bitfield =
            grouped_bitfields[group] || []

          routes.each do |candidate|
            break if route_search_expired?(deadline)

            candidate_bitfield =
              if candidate.respond_to?(:bitfield)
                Array(candidate.bitfield)
              else
                []
              end

            next if route_bitfields_conflict?(
              candidate_bitfield,
              existing_bitfield
            )

            merged_bitfield =
              route_bitfields_merge(
                candidate_bitfield,
                existing_bitfield
              )

            next_grouped_bitfields =
              grouped_bitfields.dup

            next_grouped_bitfields[group] =
              merged_bitfield

            chosen_routes << candidate

            search.call(
              index + 1,
              chosen_routes,
              next_grouped_bitfields,
              estimated_revenue +
                safe_route_revenue(candidate)
            )

            chosen_routes.pop
          end

          # A train may legally run no route.
          search.call(
            index + 1,
            chosen_routes,
            grouped_bitfields,
            estimated_revenue
          )
        end

      search.call(
        0,
        [],
        empty_bitfields,
        0
      )

      # Recalculate the final combination because route revenue may depend on
      # other simultaneously selected routes.
      unless best_routes.empty?
        real_revenue(
          best_routes
        )
      end

      self.running = false if respond_to?(:running=)

      callback&.call(
        best_routes
      )

      best_routes
    rescue StandardError => e
      self.running = false if respond_to?(:running=)

      warn(
        '[CRUBY AUTOROUTER] ' \
        "#{e.class}: #{e.message}"
      )

      callback&.call([])

      []
    ensure
      self.running = false if respond_to?(:running=)
    end

    def build_train_groups(train_entries)
      groups = {}
      next_separate_group = 0

      train_entries.each do |train, _routes|
        group =
          case @train_autoroute_group
          when :each_train_separate
            value = next_separate_group
            next_separate_group += 1
            value

          when Array
            index =
              @train_autoroute_group.find_index do |names|
                Array(names)
                  .map(&:to_s)
                  .include?(
                    train.name.to_s
                  )
              end

            index ? index + 1 : 0

          else
            0
          end

        groups[train] = group
      end

      groups
    end

    def build_maximum_remaining(train_entries)
      values =
        Array.new(
          train_entries.size + 1,
          0
        )

      (train_entries.size - 1).downto(0) do |index|
        routes =
          train_entries[index][1]

        maximum =
          routes.map do |route|
            safe_route_revenue(route)
          end.max || 0

        values[index] =
          values[index + 1] +
          maximum
      end

      values
    end

    def safe_route_revenue(route)
      route.revenue.to_i
    rescue StandardError
      0
    end

    def route_search_expired?(deadline)
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      ) >= deadline
    end

    def route_bitfields_conflict?(left, right)
      left = Array(left)
      right = Array(right)

      limit =
        [
          left.size,
          right.size,
        ].min

      (0...limit).any? do |index|
        (
          left[index].to_i &
          right[index].to_i
        ) != 0
      end
    end

    def route_bitfields_merge(left, right)
      left = Array(left)
      right = Array(right)

      length =
        [
          left.size,
          right.size,
        ].max

      Array.new(length) do |index|
        left[index].to_i |
          right[index].to_i
      end
    end
  end
end

unless Engine::AutoRouter.ancestors.include?(
  AiAutoplay::AutoRouterPatch
)
  Engine::AutoRouter.prepend(
    AiAutoplay::AutoRouterPatch
  )
end
