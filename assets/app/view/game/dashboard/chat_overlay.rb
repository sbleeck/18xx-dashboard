# frozen_string_literal: true

# backtick_javascript: true

require 'native'
require 'lib/storage'
require 'view/game/actionable'

module View
  module Game
    module Dashboard
      class ChatOverlay < Snabberb::Component
        include Actionable

        needs :game, store: true
        needs :game_data, store: true
        needs :user, default: nil, store: true
        needs :on_close, default: nil
        needs :chat_input, default: '', store: true

        PLAYER_PALETTE = [
          '#0284c7',
          '#16a34a',
          '#d97706',
          '#dc2626',
          '#7c3aed',
          '#db2777',
          '#0d9488',
          '#ea580c',
        ].freeze

        def current_user_id
          return nil unless @user

          @user['id'] || @user[:id]
        end

        def current_player
          return nil unless current_user_id

          @game.player_by_id(current_user_id)
        rescue StandardError
          nil
        end

        def participant?
          !current_player.nil?
        end

        def player_color(entity)
          players = @game.respond_to?(:players) ? Array(@game.players) : []

          index = players.index do |player|
            player.id.to_s == entity&.id.to_s
          end

          return PLAYER_PALETTE[index % PLAYER_PALETTE.size] if index

          name = entity&.name.to_s
          hash = 0

          name.each_char do |character|
            hash = character.ord + ((hash << 5) - hash)
          end

          PLAYER_PALETTE[hash.abs % PLAYER_PALETTE.size]
        end

        def my_message?(message_action)
          entity = message_action.entity
          return false unless entity && current_user_id

          entity.id.to_s == current_user_id.to_s
        rescue StandardError
          false
        end

        def action_time_map
          actions =
            (@game_data['actions'] || @game_data[:actions] if @game_data)

          actions ||= if @game.respond_to?(:raw_actions)
                        @game.raw_actions
                      else
                        []
                      end

          Array(actions).each_with_object({}) do |action, map|
            action_id =
              if action.is_a?(Hash)
                action['id'] || action[:id]
              elsif action.respond_to?(:id)
                action.id
              end

            created_at =
              if action.is_a?(Hash)
                action['created_at'] || action[:created_at]
              elsif action.respond_to?(:created_at)
                action.created_at
              end

            map[action_id.to_i] = created_at if action_id && created_at
          end
        end

        def format_timestamp(timestamp)
          return '' unless timestamp

          formatted = %x{
            (function(value) {
              var date = null;

              if (typeof value === 'number') {
                date = new Date(value > 1e11 ? value : value * 1000);
              } else if (
                typeof value === 'string' &&
                !isNaN(Date.parse(value))
              ) {
                date = new Date(value);
              }

              if (!date || isNaN(date.getTime())) return '';

              var hours = String(date.getHours()).padStart(2, '0');
              var minutes = String(date.getMinutes()).padStart(2, '0');

              return hours + ':' + minutes;
            })(#{timestamp})
          }

          formatted.to_s
        end

        def chat_messages
          times = action_time_map

          Array(@game&.log).filter_map do |entry|
            raw_message =
              if entry.respond_to?(:message)
                entry.message
              else
                entry
              end

            next unless raw_message.is_a?(Engine::Action::Message)
            next if raw_message.message.to_s.strip.empty?

            action_id =
              if entry.respond_to?(:action_id)
                entry.action_id
              elsif raw_message.respond_to?(:id)
                raw_message.id
              end

            {
              action: raw_message,
              sender: raw_message.entity,
              text: raw_message.message.to_s,
              time: format_timestamp(times[action_id.to_i]),
              action_id: action_id,
            }
          end
        end

        def send_message
          text = @chat_input.to_s.strip
          return if text.empty?
          return unless participant?

          sender = current_player
          return unless sender

          process_action(
            Engine::Action::Message.new(
              sender,
              message: text
            )
          )

          store(:chat_input, '')

          scroll_to_latest

          %x{
            var input = document.getElementById('dashboard_chat_input');
            if (input) {
              input.value = '';
              input.focus();
            }
          }
        end

        def handle_input(event)
          value = `#{event}.target.value`
          store(:chat_input, value.to_s, skip: true)
        end

        def handle_keydown(event)
          native_event = Native(event)
          key = native_event['key']

          if key == 'Escape'
            native_event.preventDefault
            close_overlay
            return
          end

          return unless key == 'Enter'
          return if native_event['shiftKey']

          native_event.preventDefault
          send_message
        end

        def scroll_to_latest
          mark_all_read!
          %x{
            var body = document.getElementById('dashboard_chat_scroll_body');

            if (body) {
              var userScrolledUp =
                body.scrollTop <
                body.scrollHeight - body.offsetHeight - 45;

              if (
                !window.__dashboardChatUserScrolledUp ||
                !userScrolledUp
              ) {
                body.scrollTop = body.scrollHeight;
              }
            }
          }
        end

        def start_drag(event)
          %x{
            var ev = #{event} || window.event;
            if (!ev) return;

            var target = ev.target || ev.srcElement;

            if (target) {
              var tag = String(target.tagName || '').toUpperCase();

              if (
                tag === 'BUTTON' ||
                tag === 'INPUT' ||
                tag === 'TEXTAREA' ||
                (target.closest && target.closest('button'))
              ) {
                return;
              }
            }

            var header = ev.currentTarget;
            var overlay = header && header.parentElement;

            if (!overlay) return;

            if (ev.preventDefault) ev.preventDefault();

            header.style.cursor = 'grabbing';

            var rect = overlay.getBoundingClientRect();
            var shiftX = ev.clientX - rect.left;
            var shiftY = ev.clientY - rect.top;

            overlay.style.position = 'fixed';
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.right = 'auto';
            overlay.style.margin = '0';
            overlay.style.transform = 'none';

            function onMouseMove(moveEvent) {
              var newLeft = moveEvent.clientX - shiftX;
              var newTop = moveEvent.clientY - shiftY;

              var maxLeft = window.innerWidth - 80;
              var maxTop = window.innerHeight - 50;

              newLeft = Math.max(10, Math.min(maxLeft, newLeft));
              newTop = Math.max(10, Math.min(maxTop, newTop));

              overlay.style.left = newLeft + 'px';
              overlay.style.top = newTop + 'px';
            }

            function onMouseUp() {
              document.removeEventListener(
                'mousemove',
                onMouseMove,
                true
              );

              document.removeEventListener(
                'mouseup',
                onMouseUp,
                true
              );

              header.style.cursor = 'grab';

              try {
                localStorage.setItem(
                  'dashboard_chat_overlay_pos',
                  JSON.stringify({
                    left: overlay.style.left,
                    top: overlay.style.top
                  })
                );
              } catch (error) {}
            }

            document.addEventListener(
              'mousemove',
              onMouseMove,
              true
            );

            document.addEventListener(
              'mouseup',
              onMouseUp,
              true
            );
          }
        end

        def mark_all_read!
          gid = (@game.respond_to?(:id) ? @game.id : 'default').to_s
          count = chat_messages.size
          read_key = "chat_read_count_#{gid}"
          pop_key = "chat_pop_count_#{gid}"

          Lib::Storage[read_key] = count
          Lib::Storage[pop_key] = count
          %x{
            try {
              localStorage.setItem(#{read_key}, String(#{count}));
              localStorage.setItem(#{pop_key}, String(#{count}));
            } catch (e) {}
          }
        rescue StandardError
          nil
        end

        def close_overlay
          mark_all_read!
          Lib::Storage['dashboard_chat_overlay'] = nil
          @on_close&.call
        end

        def saved_position
          result = %x{
            (function() {
              try {
                var saved = JSON.parse(
                  localStorage.getItem(
                    'dashboard_chat_overlay_pos'
                  )
                );

                if (
                  saved &&
                  typeof saved.left === 'string' &&
                  typeof saved.top === 'string'
                ) {
                  var left = parseFloat(saved.left);
                  var top = parseFloat(saved.top);

                  if (
                    !isNaN(left) &&
                    !isNaN(top) &&
                    left >= 0 &&
                    left <= window.innerWidth - 80 &&
                    top >= 0 &&
                    top <= window.innerHeight - 50
                  ) {
                    return saved;
                  }
                }
              } catch (error) {}

              return null;
            })()
          }

          result ? Native(result) : nil
        end

        def sender_badge(entity)
          name = entity&.name.to_s
          initials = name.split(/\s+/).map { |part| part[0] }.join
          initials = name[0..1] if initials.empty?
          initials = initials[0..1].to_s.upcase

          h(:div, {
              attrs: {
                title: name,
              },
              style: {
                width: '30px',
                height: '30px',
                minWidth: '30px',
                borderRadius: '50%',
                backgroundColor: player_color(entity),
                color: '#ffffff',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: '0.7rem',
                fontWeight: '800',
                boxShadow: '0 1px 3px rgba(0, 0, 0, 0.22)',
              },
            }, initials)
        end

        def render_message(message)
          action = message[:action]
          sender = message[:sender]
          mine = my_message?(action)

          sender_name =
            if sender&.respond_to?(:name)
              sender.name.to_s
            else
              'Player'
            end

          meta = [sender_name, message[:time]]
                 .reject(&:empty?)
                 .join(' · ')

          bubble = h(:div, {
                       style: {
                         maxWidth: '78%',
                         minWidth: '70px',
                         padding: '8px 11px',
                         borderRadius: if mine
                                         '14px 14px 3px 14px'
                                       else
                                         '14px 14px 14px 3px'
                                       end,
                         backgroundColor: mine ? '#2563eb' : '#ffffff',
                         color: mine ? '#ffffff' : '#0f172a',
                         border: if mine
                                   '1px solid #1d4ed8'
                                 else
                                   '1px solid #cbd5e1'
                                 end,
                         boxShadow: '0 1px 3px rgba(0, 0, 0, 0.12)',
                         wordBreak: 'break-word',
                         whiteSpace: 'pre-wrap',
                       },
                     }, [
              h(:div, {
                  style: {
                    fontSize: '0.66rem',
                    lineHeight: '1.2',
                    marginBottom: '4px',
                    color: mine ? '#bfdbfe' : '#64748b',
                    fontWeight: '700',
                    textAlign: mine ? 'right' : 'left',
                  },
                }, meta),
              h(:div, {
                  style: {
                    fontSize: '0.88rem',
                    lineHeight: '1.4',
                  },
                }, message[:text]),
            ])

          children = []

          if mine
            children << bubble
          else
            children << sender_badge(sender)
            children << bubble
          end

          h(:div, {
              style: {
                display: 'flex',
                flexDirection: 'row',
                justifyContent: mine ? 'flex-end' : 'flex-start',
                alignItems: 'flex-end',
                gap: '7px',
                marginBottom: '10px',
                padding: '0 4px',
              },
            }, children)
        end

        def render_messages
          messages = chat_messages

          if messages.empty?
            return [
              h(:div, {
                  style: {
                    margin: 'auto',
                    padding: '2rem 1rem',
                    textAlign: 'center',
                    color: '#64748b',
                    fontSize: '0.86rem',
                    fontStyle: 'italic',
                  },
                }, 'No player messages yet.'),
            ]
          end

          messages.map { |message| render_message(message) }
        end

        def render_composer
          unless participant?
            return h(:div, {
                       style: {
                         padding: '0.75rem',
                         borderTop: '1px solid #cbd5e1',
                         backgroundColor: '#f8fafc',
                         color: '#64748b',
                         textAlign: 'center',
                         fontSize: '0.8rem',
                       },
                     }, 'Only game participants can send messages.')
          end

          h(:div, {
              style: {
                display: 'flex',
                flexDirection: 'row',
                alignItems: 'flex-end',
                gap: '7px',
                padding: '0.65rem',
                borderTop: '1px solid #cbd5e1',
                backgroundColor: '#ffffff',
                flexShrink: '0',
              },
            }, [
              h(:textarea, {
                  attrs: {
                    id: 'dashboard_chat_input',
                    placeholder: 'Message players…',
                    rows: 2,
                    value: @chat_input,
                  },
                  style: {
                    flex: '1',
                    minWidth: '0',
                    minHeight: '38px',
                    maxHeight: '110px',
                    resize: 'vertical',
                    boxSizing: 'border-box',
                    border: '1px solid #94a3b8',
                    borderRadius: '10px',
                    padding: '8px 10px',
                    fontFamily: 'inherit',
                    fontSize: '0.86rem',
                    lineHeight: '1.3',
                    outline: 'none',
                  },
                  on: {
                    input: ->(event) { handle_input(event) },
                    keydown: ->(event) { handle_keydown(event) },
                  },
                }),
              h(:button, {
                  attrs: {
                    id: 'dashboard_chat_send',
                    type: 'button',
                    title: 'Send message',
                  },
                  style: {
                    height: '38px',
                    minWidth: '64px',
                    border: '1px solid #1d4ed8',
                    borderRadius: '9px',
                    backgroundColor: '#2563eb',
                    color: '#ffffff',
                    fontWeight: '700',
                    cursor: 'pointer',
                    padding: '0 12px',
                    boxShadow: '0 1px 3px rgba(0, 0, 0, 0.15)',
                  },
                  on: {
                    click: -> { send_message },
                  },
                }, 'Send'),
            ])
        end

        def render
          position = saved_position

          left = position ? position['left'] : 'calc(100vw - 470px)'
          top = position ? position['top'] : '70px'

          h('div#dashboard_chat_overlay', {
              attrs: {
                role: 'dialog',
                'aria-label': 'Game chat',
              },
              style: {
                position: 'fixed',
                left: left,
                top: top,
                width: '440px',
                height: '560px',
                minWidth: '320px',
                minHeight: '300px',
                maxWidth: '96vw',
                maxHeight: '90vh',
                display: 'flex',
                flexDirection: 'column',
                backgroundColor: '#f1f5f9',
                border: '1px solid #94a3b8',
                borderRadius: '11px',
                boxShadow:
                  '0 16px 32px -8px rgba(0, 0, 0, 0.42)',
                zIndex: '999999',
                overflow: 'hidden',
                resize: 'both',
                pointerEvents: 'auto',
              },
              hook: {
                insert: lambda {
                  scroll_to_latest
                  %x{
            var input = document.getElementById('dashboard_chat_input');
            if (input) input.focus();
          }
                },
                postpatch: -> { scroll_to_latest },
              },
            }, [
              h('div#dashboard_chat_header', {
                  style: {
                    minHeight: '48px',
                    padding: '0 0.85rem',
                    backgroundColor: '#e2e8f0',
                    borderBottom: '1px solid #cbd5e1',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    cursor: 'grab',
                    userSelect: 'none',
                    flexShrink: '0',
                  },
                  on: {
                    mousedown: ->(event) { start_drag(event) },
                  },
                }, [
                  h(:div, {
                      style: {
                        display: 'flex',
                        alignItems: 'center',
                        gap: '0.5rem',
                        pointerEvents: 'none',
                      },
                    }, [
                      h(:span, {
                          style: {
                            fontSize: '1.25rem',
                          },
                        }, '💬'),
                      h(:div, [
                        h(:div, {
                            style: {
                              color: '#0f172a',
                              fontSize: '0.95rem',
                              fontWeight: '800',
                            },
                          }, 'Player Chat'),
                        h(:div, {
                            style: {
                              color: '#64748b',
                              fontSize: '0.66rem',
                              marginTop: '1px',
                            },
                          }, 'Messages only, no game actions'),
                      ]),
                    ]),
                  h(:button, {
                      attrs: {
                        id: 'btn_close_dashboard_chat',
                        type: 'button',
                        title: 'Close chat',
                      },
                      style: {
                        background: 'none',
                        border: 'none',
                        color: '#64748b',
                        fontSize: '1.3rem',
                        cursor: 'pointer',
                        padding: '3px 7px',
                        borderRadius: '4px',
                        lineHeight: '1',
                      },
                      on: {
                        click: lambda do |event|
                          %x{
                    if (
                      #{event} &&
                      #{event}.stopPropagation
                    ) {
                      #{event}.stopPropagation();
                    }
                  }

                          close_overlay
                        end,
                      },
                    }, '✕'),
                ]),
              h('div#dashboard_chat_scroll_body', {
                  style: {
                    flex: '1 1 auto',
                    minHeight: '0',
                    overflowY: 'auto',
                    padding: '12px 10px 4px 10px',
                    backgroundColor: '#f8fafc',
                    userSelect: 'text',
                  },
                  on: {
                    scroll: lambda do |event|
                      %x{
                var body = #{event}.target;

                if (body) {
                  window.__dashboardChatUserScrolledUp =
                    body.scrollTop <
                    body.scrollHeight -
                      body.offsetHeight -
                      45;
                }
              }
                    end,
                  },
                }, render_messages),
              render_composer,
            ])
        end
      end
    end
  end
end
