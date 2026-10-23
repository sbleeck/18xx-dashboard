# frozen_string_literal: true

require 'lib/storage'

module View
  module Game
    module Dashboard
      class DashboardHelpOverlay < Snabberb::Component
        needs :game, default: nil
        needs :on_close, default: nil

        # --- VERSION & BUILD METADATA ---
        VERSION = '1.0.0'
        BUILD_TIME = '2026-10-23 20:45 BST'

        SECTIONS = [
          {
            id: 'overview',
            title: 'Spatial Architecture & Vision',
            icon: '🧭',
            content: [
              'Zero-Tab Continuity: Consolidates the entire game experience onto an immutable, three-quadrant command view: Map on the left, Corporate Ledger top-right, and Stock Market bottom-right.',
              'Pre-Attentive State Awareness: Train deliveries, dividend flows, and share acquisitions animate across physical coordinates, allowing you to track state deltas in peripheral vision without auditing textual logs.',
              'Relational Coupling: Hovering over any corporation, share certificate, or station token triggers a synchronous 1 Hz luminance pulse across all representations (Map tokens, Market markers, and Charter).',
            ],
          },
          {
            id: 'map_controls',
            title: 'Interactive Map Canvas',
            icon: '🗺️',
            content: [
              'Viewport Navigation: Hold Alt + Left Click and drag anywhere to pan the board. Hold Alt + Mouse Wheel (or use the top-right +, −, ⟲ controls) for focal zooming.',
              'Route Revenue ($): Overlays calculated route revenue numbers directly onto running track hexes and station nodes.',
              'Hex Identifiers (T): Toggles alphanumeric coordinate labels and town names across the board.',
              'Corporate Emblems (L): Switches between full-color historical corporate logos and high-contrast simplified tokens.',
              'Track Manifest: Click "Show Remaining Tiles" (top left) to inspect available tile inventory sorted by phase color and tile number.',
              'Phase Indicator: Physical-style hex badges in the upper-left indicate the tile colors (yellow, green, brown, grey) currently unlocked.',
            ],
          },
          {
            id: 'ledger_market',
            title: 'Corporate Ledger & Stock Market',
            icon: '📊',
            content: [
              'Financial Ledger (Top Right): Real-time breakdown of player liquidity, certificate counts, total portfolio worth, and priority deal, alongside operating treasuries, train inventories, and token reserves.',
              'Stock Market (Bottom Right): Live market grid tracking share values, ledge bounds, par values, and ownership token stacks with independent zoom and pan.',
              'Flexible Real Estate: Drag the horizontal and vertical dividing gutters to resize viewports to match your display aspect ratio.',
            ],
          },
          {
            id: 'temporal_hub',
            title: 'Action Hub & Turn Sequences',
            icon: '⚡',
            content: [
              'Sequential Action Drawer: Slides open automatically during your turn to guide track lays, token placements, route runs, train purchases, and share trading.',
              'Turn Sound & Visual Beacon: Synthesizes a pentatonic audio alert and ignites an emerald ambient frame when action is required on your turn.',
              'Auto-Stow: Automatically retracts when your turn passes, maximizing active board real estate.',
            ],
          },
          {
            id: 'utility_buttons',
            title: 'Utility Cluster & Tools',
            icon: '🛠️',
            content: [
              '📜 Game Transcript: Review chronological history, dividend declarations, and operating logs.',
              '🕘 Recent Actions: Quick popup summarizing the last several table actions.',
              '🎮 Multi-Game Switcher: Rapid toggle menu showing all your active matches with turn notification badges.',
              '🎵 Audio Alerts: Toggle pentatonic turn chime notifications on or off.',
              '💬 Tabletop Chat: In-game communications overlay with speech bubbles and unread counters.',
            ],
          },
          {
            id: 'hotkeys',
            title: 'Dispatch Hotkeys',
            icon: '⌨️',
            content: [
              'Alt + Mouse Wheel: Smooth zoom in/out on Map, Ledger, or Stock Market.',
              'Alt + Drag: Smooth pan across any viewport canvas.',
              'Esc: Dismiss active overlays, close menus, or exit this help screen.',
              'R: Trigger automated test action (sandbox and hotseat modes only).',
            ],
          },
        ].freeze

        def render
          close_handler = lambda do |e = nil|
            %x{
              if (#{e} && #{e}.stopPropagation) #{e}.stopPropagation();
              try {
                localStorage.removeItem('dashboard_show_help');
              } catch(err) {}
            }
            Lib::Storage['dashboard_show_help'] = nil
            @on_close&.call
          end

          open_kofi = lambda do
            %x{
              window.open('https://ko-fi.com/sbleeck', '_blank');
            }
          end

          open_youtube = lambda do
            %x{
              window.open('https://www.youtube.com/@18xxGamesAndRules', '_blank');
            }
          end

          send_email_report = lambda do
            %x{
              var currentUrl = window.location.href;
              var pathSegments = window.location.pathname.split('/');
              var gameId = pathSegments[pathSegments.length - 1] || 'Unknown';
              var userAgent = navigator.userAgent;

              var subject = encodeURIComponent('18xx Dashboard Error Report: Game #' + gameId);
              var body = encodeURIComponent(
                'Game URL: ' + currentUrl + '\n' +
                'Dashboard Version: v' + #{VERSION} + ' (Built: ' + #{BUILD_TIME} + ')\n' +
                'Browser / OS: ' + userAgent + '\n\n' +
                'Issue Description:\n' +
                '[Describe what happened on this turn]\n\n' +
                'Expected Behaviour:\n' +
                '[What should have happened instead]\n'
              );

              window.location.href = 'mailto:bleeck@gmail.com?subject=' + subject + '&body=' + body;
            }
          end

          saved_left = %x((function() {
            try {
              var l = sessionStorage.getItem('dashboard_help_left');
              return (l && l !== 'undefined' && l !== 'null' && !isNaN(parseFloat(l))) ? parseFloat(l) : null;
            } catch(e) { return null; }
          })())

          saved_top = %x((function() {
            try {
              var t = sessionStorage.getItem('dashboard_help_top');
              return (t && t !== 'undefined' && t !== 'null' && !isNaN(parseFloat(t))) ? parseFloat(t) : null;
            } catch(e) { return null; }
          })())

          on_header_mousedown = lambda do |event|
            %x{
              var ev = #{event} || window.event;
              if (!ev) return;

              var target = ev.target || ev.srcElement;
              if (target) {
                var tag = (target.tagName || '').toUpperCase();
                if (tag === 'BUTTON' || tag === 'INPUT' || (target.closest && target.closest('button, a'))) {
                  return;
                }
              }

              var header = ev.currentTarget;
              var modal = header && header.parentElement;
              if (!header || !modal) return;

              if (ev.preventDefault) ev.preventDefault();

              header.style.cursor = 'grabbing';

              var rect = modal.getBoundingClientRect();
              var shiftX = ev.clientX - rect.left;
              var shiftY = ev.clientY - rect.top;

              modal.style.position = 'fixed';
              modal.style.left = rect.left + 'px';
              modal.style.top = rect.top + 'px';
              modal.style.margin = '0';
              modal.style.transform = 'none';

              function onMouseMove(moveEv) {
                var mEv = moveEv || window.event;
                if (mEv.preventDefault) mEv.preventDefault();

                var newLeft = mEv.clientX - shiftX;
                var newTop = mEv.clientY - shiftY;
                var maxLeft = window.innerWidth - 60;
                var maxTop = window.innerHeight - 40;

                if (newLeft < 10) newLeft = 10;
                if (newLeft > maxLeft) newLeft = maxLeft;
                if (newTop < 0) newTop = 0;
                if (newTop > maxTop) newTop = maxTop;

                modal.style.left = newLeft + 'px';
                modal.style.top = newTop + 'px';
              }

              function onMouseUp() {
                document.removeEventListener('mousemove', onMouseMove, true);
                document.removeEventListener('mouseup', onMouseUp, true);
                window.removeEventListener('mousemove', onMouseMove, true);
                window.removeEventListener('mouseup', onMouseUp, true);

                header.style.cursor = 'grab';

                var finalRect = modal.getBoundingClientRect();
                if (finalRect && !isNaN(finalRect.left) && !isNaN(finalRect.top)) {
                  try {
                    sessionStorage.setItem('dashboard_help_left', finalRect.left);
                    sessionStorage.setItem('dashboard_help_top', finalRect.top);
                  } catch (err) {}
                }
              }

              document.addEventListener('mousemove', onMouseMove, true);
              document.addEventListener('mouseup', onMouseUp, true);
              window.addEventListener('mousemove', onMouseMove, true);
              window.addEventListener('mouseup', onMouseUp, true);
            }
          end

          reset_pos = lambda do
            %x{
              try {
                sessionStorage.removeItem('dashboard_help_left');
                sessionStorage.removeItem('dashboard_help_top');
              } catch(e) {}
              var modal = document.getElementById('dashboard-help-dialog');
              if (modal) {
                modal.style.left = '50%';
                modal.style.top = '70px';
                modal.style.transform = 'translateX(-50%)';
                modal.style.margin = '0';
              }
            }
          end

          dialog_style = {
            position: 'fixed',
            width: '640px',
            maxWidth: '95vw',
            height: '690px',
            maxHeight: '92vh',
            minWidth: '380px',
            minHeight: '300px',
            backgroundColor: '#ffffff',
            borderRadius: '10px',
            boxShadow: '0 25px 50px -12px rgba(15, 23, 42, 0.45), 0 0 0 1px rgba(15, 23, 42, 0.12)',
            zIndex: '10000050',
            display: 'flex',
            flexDirection: 'column',
            boxSizing: 'border-box',
            overflow: 'hidden',
            resize: 'both',
            fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
            color: '#0f172a',
            pointerEvents: 'auto',
            margin: '0',
          }

          if saved_left && saved_top
            dialog_style[:left] = "#{saved_left}px"
            dialog_style[:top] = "#{saved_top}px"
            dialog_style[:transform] = 'none'
          else
            dialog_style[:left] = '50%'
            dialog_style[:top] = '70px'
            dialog_style[:transform] = 'translateX(-50%)'
          end

          dialog_box = h(:div, {
                           attrs: { id: 'dashboard-help-dialog' },
                           style: dialog_style,
                         }, [
            # Draggable Header Bar
            h(:div, {
                attrs: { id: 'dashboard-help-header' },
                style: {
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '0.85rem 1.15rem',
                  backgroundColor: '#1e293b',
                  color: '#ffffff',
                  borderTopLeftRadius: '10px',
                  borderTopRightRadius: '10px',
                  cursor: 'grab',
                  userSelect: 'none',
                  flexShrink: '0',
                  borderBottom: '1px solid #334155',
                },
                on: {
                  mousedown: on_header_mousedown,
                  dblclick: reset_pos,
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.65rem', pointerEvents: 'none' } }, [
                h(:span, { style: { fontSize: '1.25rem', lineHeight: '1' } }, '🚂'),
                h(:span, { style: { fontWeight: '700', fontSize: '1.05rem', letterSpacing: '0.3px' } },
                  '18xx Desktop Dashboard Guide'),
              ]),
              h(:button, {
                  attrs: { type: 'button', title: 'Close Guide (Esc)' },
                  style: {
                    background: 'none',
                    border: 'none',
                    color: '#94a3b8',
                    fontSize: '1.3rem',
                    fontWeight: 'bold',
                    cursor: 'pointer',
                    padding: '2px 6px',
                    lineHeight: '1',
                    borderRadius: '4px',
                    pointerEvents: 'auto',
                    zIndex: '10',
                    transition: 'color 0.15s ease',
                  },
                  on: { click: close_handler },
                }, '✕'),
            ]),

            # Scrollable Body Content
            h(:div, {
                style: {
                  flex: '1 1 auto',
                  overflowY: 'auto',
                  padding: '1.1rem 1.35rem',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '1rem',
                  backgroundColor: '#f8fafc',
                },
              }, [
              # Top Dispatch Banner & Action Buttons
              h(:div, {
                  style: {
                    backgroundColor: '#0f172a',
                    color: '#f8fafc',
                    borderRadius: '8px',
                    padding: '1rem 1.15rem',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: '0.75rem',
                    boxShadow: '0 4px 6px -1px rgba(0, 0, 0, 0.2)',
                  },
                }, [
                h(:div, { style: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '0.6rem' } }, [
                  h(:div, [
                    h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', flexWrap: 'wrap' } }, [
                      h(:span, { style: { fontSize: '1.05rem', fontWeight: '800', letterSpacing: '0.2px', color: '#ffffff' } },
                        '18xx.games Desktop Dashboard'),
                      h(:span, {
                          style: {
                            fontSize: '0.72rem',
                            fontWeight: '700',
                            padding: '2px 6px',
                            borderRadius: '4px',
                            backgroundColor: '#0284c7',
                            color: '#ffffff',
                            letterSpacing: '0.3px',
                          },
                        }, "v#{VERSION}"),
                    ]),
                    h(:div, { style: { fontSize: '0.78rem', color: '#94a3b8', marginTop: '3px' } }, [
                      h(:span, { style: { color: '#38bdf8', fontWeight: '600' } }, "Build: #{BUILD_TIME}"),
                      h(:span, { style: { margin: '0 6px', color: '#64748b' } }, '•'),
                      h(:span, 'By Stefan Bleeck'),
                    ]),
                  ]),
                  h(:div, { style: { display: 'flex', gap: '0.5rem', flexWrap: 'wrap' } }, [
                    h(:button, {
                        attrs: {
                          type: 'button',
                          title: 'Support ongoing development on Ko-fi (https://ko-fi.com/sbleeck)',
                        },
                        style: {
                          display: 'inline-flex',
                          alignItems: 'center',
                          gap: '0.35rem',
                          backgroundColor: '#ff5f5f',
                          color: '#ffffff',
                          border: 'none',
                          padding: '0.45rem 0.85rem',
                          borderRadius: '5px',
                          fontWeight: '700',
                          fontSize: '0.82rem',
                          cursor: 'pointer',
                          boxShadow: '0 2px 4px rgba(0,0,0,0.2)',
                        },
                        on: { click: open_kofi },
                      }, [
                      h(:span, '☕'),
                      h(:span, 'Support on Ko-fi'),
                    ]),
                    # // --- START FIX ---
                    h(:button, {
                        attrs: {
                          type: 'button',
                          title: 'Watch strategy masterclasses and guides on YouTube (@Rails-Evolution-18xx)',
                        },
                        style: {
                          display: 'inline-flex',
                          alignItems: 'center',
                          gap: '0.35rem',
                          backgroundColor: '#dc2626',
                          color: '#ffffff',
                          border: 'none',
                          padding: '0.45rem 0.85rem',
                          borderRadius: '5px',
                          fontWeight: '700',
                          fontSize: '0.82rem',
                          cursor: 'pointer',
                          boxShadow: '0 2px 4px rgba(0,0,0,0.2)',
                        },
                        on: { click: open_youtube },
                      }, [
                      h(:span, '📺'),
                      h(:span, 'YouTube Channel'),
                    ]),
                    # // --- END FIX ---
                    h(:button, {
                        attrs: {
                          type: 'button',
                          title: 'Send an email error report with current game diagnostics to bleeck@gmail.com',
                        },
                        style: {
                          display: 'inline-flex',
                          alignItems: 'center',
                          gap: '0.35rem',
                          backgroundColor: '#1e293b',
                          color: '#38bdf8',
                          border: '1px solid #0284c7',
                          padding: '0.45rem 0.85rem',
                          borderRadius: '5px',
                          fontWeight: '700',
                          fontSize: '0.82rem',
                          cursor: 'pointer',
                        },
                        on: { click: send_email_report },
                      }, [
                      h(:span, '✉️'),
                      h(:span, 'Email Error Report'),
                    ]),
                  ]),
                ]),
                h(:p, {
                    style: {
                      margin: '0',
                      fontSize: '0.83rem',
                      lineHeight: '1.4',
                      color: '#cbd5e1',
                    },
                  },
                  'An alternative, persistent spatial interface for 18xx.games. Eliminates tab navigation friction by anchoring the Map, Corporate Ledgers, and Stock Market simultaneously on screen.'),
              ]),

              # Guide Sections
              *SECTIONS.map do |section|
                h(:div, {
                    style: {
                      backgroundColor: '#ffffff',
                      border: '1px solid #e2e8f0',
                      borderRadius: '8px',
                      padding: '0.9rem 1.1rem',
                      boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                    },
                  }, [
                  h(:div, {
                      style: {
                        display: 'flex',
                        alignItems: 'center',
                        gap: '0.5rem',
                        marginBottom: '0.55rem',
                        borderBottom: '1px solid #f1f5f9',
                        paddingBottom: '0.4rem',
                      },
                    }, [
                    h(:span, { style: { fontSize: '1.1rem' } }, section[:icon]),
                    h(:h3, {
                        style: {
                          margin: '0',
                          fontSize: '0.92rem',
                          fontWeight: '700',
                          color: '#1e3a8a',
                          textTransform: 'uppercase',
                          letterSpacing: '0.4px',
                        },
                      }, section[:title]),
                  ]),
                  h(:div, {
                      style: {
                        display: 'flex',
                        flexDirection: 'column',
                        gap: '0.4rem',
                        fontSize: '0.85rem',
                        lineHeight: '1.45',
                        color: '#334155',
                      },
                    }, section[:content].map do |text|
                         h(:div, { style: { display: 'flex', gap: '0.5rem', alignItems: 'flex-start' } }, [
                           h(:span, { style: { color: '#2563eb', fontWeight: 'bold' } }, '•'),
                           h(:span, text),
                         ])
                       end),
                ])
              end,
            ]),

            # Footer
            h(:div, {
                style: {
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  padding: '0.75rem 1.25rem',
                  borderTop: '1px solid #cbd5e1',
                  backgroundColor: '#ffffff',
                  flexShrink: '0',
                  gap: '0.5rem',
                  flexWrap: 'wrap',
                },
              }, [
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem', flexWrap: 'wrap' } }, [
                h(:button, {
                    attrs: {
                      type: 'button',
                      title: 'Support on Ko-fi (https://ko-fi.com/sbleeck)',
                    },
                    style: {
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: '0.3rem',
                      backgroundColor: '#ff5f5f',
                      color: '#ffffff',
                      border: 'none',
                      padding: '0.35rem 0.65rem',
                      borderRadius: '5px',
                      fontWeight: '700',
                      fontSize: '0.78rem',
                      cursor: 'pointer',
                    },
                    on: { click: open_kofi },
                  }, [
                  h(:span, '☕'),
                  h(:span, 'Ko-fi Tip Jar'),
                ]),
                # // --- START FIX ---
                h(:button, {
                    attrs: {
                      type: 'button',
                      title: 'Watch strategy masterclasses and guides on YouTube (@Rails-Evolution-18xx)',
                    },
                    style: {
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: '0.3rem',
                      backgroundColor: '#dc2626',
                      color: '#ffffff',
                      border: 'none',
                      padding: '0.35rem 0.65rem',
                      borderRadius: '5px',
                      fontWeight: '700',
                      fontSize: '0.78rem',
                      cursor: 'pointer',
                    },
                    on: { click: open_youtube },
                  }, [
                  h(:span, '📺'),
                  h(:span, 'YouTube Channel'),
                ]),
                # // --- END FIX ---
                h(:button, {
                    attrs: {
                      type: 'button',
                      title: 'Email error report to bleeck@gmail.com',
                    },
                    style: {
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: '0.3rem',
                      backgroundColor: '#f1f5f9',
                      color: '#0369a1',
                      border: '1px solid #bae6fd',
                      padding: '0.35rem 0.65rem',
                      borderRadius: '5px',
                      fontWeight: '700',
                      fontSize: '0.78rem',
                      cursor: 'pointer',
                    },
                    on: { click: send_email_report },
                  }, [
                  h(:span, '✉️'),
                  h(:span, 'Email Error Report'),
                ]),
              ]),
              h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.75rem' } }, [
                h(:span, { style: { fontSize: '0.73rem', color: '#64748b' } },
                  "v#{VERSION} (#{BUILD_TIME}) • Drag bar to move"),
                h(:button, {
                    attrs: { type: 'button' },
                    style: {
                      padding: '0.45rem 1.15rem',
                      fontSize: '0.85rem',
                      fontWeight: '700',
                      backgroundColor: '#2563eb',
                      color: '#ffffff',
                      border: 'none',
                      borderRadius: '6px',
                      cursor: 'pointer',
                      transition: 'background-color 0.15s ease',
                    },
                    on: { click: close_handler },
                  }, 'Done'),
              ]),
            ]),
          ])

          h(:div, {
              attrs: { id: 'dashboard-help-container' },
              style: {
                position: 'fixed',
                top: '0',
                left: '0',
                right: '0',
                bottom: '0',
                backgroundColor: 'transparent',
                pointerEvents: 'none',
                zIndex: '10000050',
              },
            }, [dialog_box])
        end
      end
    end
  end
end
