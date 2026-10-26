#!/usr/bin/env python3
"""
18xx.games Dashboard Forensic Game Scrubber
Connects to Google Chrome (with Requestly active) via CDP or Real Profile.
"""

import argparse
import os
import re
import sys
import time
from playwright.sync_api import sync_playwright

DEFAULT_DELAY_SECONDS = 1.0          # Seconds per step
DEFAULT_STEP_MODE     = "companies"  # "companies" or "all"
DEFAULT_BASE_URL      = "https://18xx.games"
DEFAULT_LOCAL_URL     = "http://localhost:9292"
CDP_URL               = "http://localhost:9222"

# Terminal ANSI Styling
C_BLUE   = "\033[94m"
C_CYAN   = "\033[96m"
C_GREEN  = "\033[92m"
C_YELLOW = "\033[93m"
C_RED    = "\033[91m"
C_BOLD   = "\033[1m"
C_DIM    = "\033[2m"
C_RESET  = "\033[0m"


def resolve_chrome_profile():
    mac_profile = os.path.expanduser("~/Library/Application Support/Google/Chrome")
    return mac_profile if os.path.isdir(mac_profile) else None


def extract_numeric_match_id(raw_input):
    target = str(raw_input).strip()
    match = re.search(r"(\d{4,8})", target)
    return match.group(1) if match else None


def run_scrubber(
    raw_match_input,
    delay_s=DEFAULT_DELAY_SECONDS,
    step_mode=DEFAULT_STEP_MODE,
    base_url=DEFAULT_BASE_URL,
    use_cdp=False,
    use_local=False
):
    match_id = extract_numeric_match_id(raw_match_input)
    if not match_id:
        print(f"{C_RED}Error: '{raw_match_input}' does not contain a valid numeric match ID.{C_RESET}")
        sys.exit(1)

    delay_ms = int(delay_s * 1000)
    game_url = f"{base_url.rstrip('/')}/game/{match_id}#dashboard"

    print(f"\n{C_BOLD}{C_BLUE}======================================================{C_RESET}")
    print(f"{C_BOLD} 18xx.games Dashboard Automated Game Scrubber{C_RESET}")
    print(f"{C_DIM} Target Match : {C_RESET}{C_CYAN}{game_url}{C_RESET}")
    print(f"{C_DIM} Pacing       : {C_RESET}{C_BOLD}{delay_s}s per move ({delay_ms} ms){C_RESET}")
    print(f"{C_DIM} Step Mode    : {C_RESET}{step_mode}")

    captured_errors = []

    with sync_playwright() as p:
        browser_owner = False
        context = None

        if use_cdp:
            print(f"{C_DIM} Environment  : {C_RESET}{C_GREEN}Connecting to live Chrome via CDP ({CDP_URL})...{C_RESET}")
            try:
                browser = p.chromium.connect_over_cdp(CDP_URL)
                context = browser.contexts[0] if browser.contexts else browser.new_context()
            except Exception as e:
                print(f"{C_RED}Failed to connect to Chrome on port 9222:{C_RESET} {e}")
                print(f"{C_YELLOW}Start Chrome with debugging enabled first:{C_RESET}")
                print(f"  /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --remote-debugging-port=9222 &")
                return
        elif use_local:
            print(f"{C_DIM} Environment  : {C_RESET}{C_GREEN}Local Docker Instance (No Requestly needed){C_RESET}")
            context = p.chromium.launch_persistent_context(
                user_data_dir="/tmp/18xx_docker_test_profile",
                headless=False,
                args=["--window-size=1680,1050"]
            )
            browser_owner = True
        else:
            sys_profile = resolve_chrome_profile()
            print(f"{C_DIM} Environment  : {C_RESET}{C_GREEN}Google Chrome Real Profile (Requestly Active){C_RESET}")
            try:
                context = p.chromium.launch_persistent_context(
                    user_data_dir=sys_profile,
                    channel="chrome",
                    headless=False,
                    args=["--window-size=1680,1050"]
                )
                browser_owner = True
            except Exception as e:
                if "Target page, context or browser has been closed" in str(e) or "lock" in str(e).lower():
                    print(f"\n{C_RED}{C_BOLD}Chrome is currently open!{C_RESET}")
                    print(f"{C_YELLOW}Either:{C_RESET}")
                    print(f"  1. Press {C_BOLD}Cmd + Q{C_RESET} to quit Google Chrome, then rerun this command.")
                    print(f"  2. OR launch Chrome with debugging and use {C_BOLD}--cdp{C_RESET}:")
                    print(f"     {C_DIM}/Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --remote-debugging-port=9222 &{C_RESET}")
                    print(f"     {C_DIM}python3 ./scripts/scrub_game.py {match_id} --cdp --delay {delay_s}{C_RESET}\n")
                    return
                print(f"{C_RED}Error launching Chrome:{C_RESET} {e}")
                return

        print(f"{C_BOLD}{C_BLUE}======================================================{C_RESET}\n")

        page = context.new_page()

        def handle_console(msg):
            if msg.type in ["error", "warning"]:
                text = msg.text
                if any(x in text for x in ["favicon", "analytics", "socket", "WebSocket", "preconnect"]):
                    return
                try:
                    act_num = page.evaluate("window.__currentScrubAction || '1'")
                except Exception:
                    act_num = "?"
                captured_errors.append({"action": act_num, "type": msg.type.upper(), "message": text})
                prefix = f"{C_RED}[ERROR]{C_RESET}" if msg.type == "error" else f"{C_YELLOW}[WARN]{C_RESET}"
                print(f"  {prefix} {C_BOLD}Action #{act_num}:{C_RESET} {text[:110]}")

        def handle_pageerror(err):
            try:
                act_num = page.evaluate("window.__currentScrubAction || '1'")
            except Exception:
                act_num = "?"
            captured_errors.append({"action": act_num, "type": "CRASH", "message": str(err)})
            print(f"\n  {C_RED}{C_BOLD}[CRASH at Action #{act_num}]:{C_RESET} {err}\n")

        page.on("console", handle_console)
        page.on("pageerror", handle_pageerror)

        print(f"{C_CYAN}Loading match #{match_id}...{C_RESET}")
        try:
            page.goto(game_url, wait_until="domcontentloaded", timeout=45000)
        except Exception as e:
            print(f"{C_RED}Failed to load game URL: {e}{C_RESET}")
            if browser_owner: context.close()
            return

        # Fetch match metadata
        meta = page.evaluate(f"""
            (async function() {{
                try {{
                    var res = await fetch('/api/game/{match_id}');
                    if (!res.ok) return {{ error: 'HTTP ' + res.status }};
                    var data = await res.json();
                    var acts = data.actions || [];
                    return {{
                        title: data.title || 'Unknown',
                        status: data.status || 'Unknown',
                        totalActions: acts.length
                    }};
                }} catch(e) {{
                    return {{ error: String(e) }};
                }}
            }})()
        """)

        total_actions = 0
        if meta and not meta.get("error"):
            title = meta.get("title")
            status = meta.get("status")
            total_actions = meta.get("totalActions", 0)
            print(f"{C_GREEN}Verified match #{match_id}: {title} ({status}, {total_actions} actions){C_RESET}")

        # Check if Requestly injected the Dashboard tab
        time.sleep(1.0)
        has_dashboard_tab = page.evaluate("""
            document.querySelector('nav#game_menu a[href="#dashboard"]') !== null
        """)

        if not has_dashboard_tab:
            print(f"\n{C_RED}{C_BOLD}Error: The Dashboard tab was not found in the navigation menu.{C_RESET}")
            print(f"{C_YELLOW}Requestly is not redirecting files in this browser window.{C_RESET}")
            print(f"Make sure Requestly is enabled and your rule for 18xx.games is turned ON.\n")
            if browser_owner: context.close()
            return

        print(f"{C_CYAN}Waiting for dashboard master frame to mount...{C_RESET}")
        try:
            page.wait_for_selector("#viz-master-frame", timeout=30000)
        except Exception:
            print(f"{C_RED}Timeout: Dashboard (#viz-master-frame) did not mount within 30 seconds.{C_RESET}")
            if browser_owner: context.close()
            return

        # Open the History HUD if closed
        slider = page.query_selector("#hist_slider_input")
        if not slider:
            btn_hist = page.query_selector("#btn-history-overlay")
            if btn_hist:
                btn_hist.click()
            try:
                page.wait_for_selector("#hist_slider_input", timeout=8000)
            except Exception:
                pass

        if total_actions <= 1:
            total_actions = page.evaluate("""
                (function() {
                    var slider = document.getElementById('hist_slider_input');
                    if (slider && slider.max) return parseInt(slider.max, 10);
                    return 0;
                })()
            """)

        runner_js = f"""
        (async function() {{
            window.__currentScrubAction = 1;
            const slider = document.getElementById('hist_slider_input');
            const maxActions = slider && slider.max ? parseInt(slider.max, 10) : {total_actions};

            const btnStart = document.querySelector('button[title*="Beginning of Game"]');
            if (btnStart) btnStart.click();

            await new Promise(r => setTimeout(r, 800));

            const mode = "{step_mode}";
            const delay = {delay_ms};

            while (true) {{
                const label = document.getElementById('hist_viewing_text');
                if (label) {{
                    const m = label.textContent.match(/#(\\d+)/);
                    if (m) window.__currentScrubAction = parseInt(m[1], 10);
                }}

                let targetBtn = null;
                if (mode === 'companies') {{
                    const nextCorp = document.querySelector('button[title*="Next Company Turn"]');
                    const nextRound = document.querySelector('button[title*="Next Round"]');
                    const nextAction = document.querySelector('button[title*="Step Forward 1 Action"]');

                    if (nextCorp && !nextCorp.disabled) {{
                        targetBtn = nextCorp;
                    }} else if (nextRound && !nextRound.disabled) {{
                        targetBtn = nextRound;
                    }} else if (nextAction && !nextAction.disabled) {{
                        targetBtn = nextAction;
                    }}
                }} else {{
                    targetBtn = document.querySelector('button[title*="Step Forward 1 Action"]');
                }}

                if (!targetBtn || targetBtn.disabled) {{
                    break;
                }}

                targetBtn.click();
                await new Promise(r => setTimeout(r, delay));
            }}

            return {{
                total: maxActions,
                finalAction: window.__currentScrubAction
            }};
        }})();
        """

        print(f"{C_GREEN}Beginning playback scrub ({delay_s}s per move across {total_actions} actions)...{C_RESET}\n")
        start_time = time.time()
        result = page.evaluate(runner_js)
        elapsed = time.time() - start_time
        print(f"\n{C_GREEN}Playback finished in {elapsed:.1f}s (Scrubbed to Action #{result.get('finalAction')}/{result.get('total')}){C_RESET}")

        time.sleep(1.0)
        if browser_owner:
            context.close()

    # Summary Report
    print(f"\n{C_BOLD}{C_BLUE}======================================================{C_RESET}")
    print(f"{C_BOLD} COMPATIBILITY AUDIT REPORT — MATCH #{match_id}{C_RESET}")
    print(f"{C_BOLD}{C_BLUE}======================================================{C_RESET}")

    crashes = [e for e in captured_errors if e["type"] in ["CRASH", "ERROR"] and "cx=" not in e["message"] and "cy=" not in e["message"]]
    svg_quirks = [e for e in captured_errors if "cx=" in e["message"] or "cy=" in e["message"] or "r=" in e["message"]]

    print(f"Total Actions Evaluated : {result.get('total') if result else total_actions}")
    print(f"Fatal Exceptions        : {len(crashes)}")
    print(f"SVG / Geometry Quirks   : {len(svg_quirks)}")

    if crashes:
        print(f"\n{C_RED}{C_BOLD}FATAL EXCEPTION BREAKDOWN:{C_RESET}")
        for idx, err in enumerate(crashes, 1):
            print(f"  {idx}. [Action #{err['action']}] {err['message']}")
        print(f"\n{C_RED}{C_BOLD}VERDICT: ❌ BROKEN / CRASH ENCOUNTERED{C_RESET}")
    elif svg_quirks:
        print(f"\n{C_YELLOW}{C_BOLD}VERDICT: ⚠️ PLAYABLE (Minor SVG Quirks Present){C_RESET}")
    else:
        print(f"\n{C_GREEN}{C_BOLD}VERDICT: ✅ PASS (100% Certified Clean){C_RESET}")
    print(f"{C_BOLD}{C_BLUE}======================================================{C_RESET}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Scrub an exact 18xx.games match ID and audit for dashboard errors.")
    parser.add_argument("match_id", nargs="?", default=None, help="The numeric match ID (e.g. 273389) or full match URL.")
    parser.add_argument("--delay", type=float, default=DEFAULT_DELAY_SECONDS, help="Delay in seconds between moves (default: 1.0s).")
    parser.add_argument("--mode", choices=["companies", "all"], default=DEFAULT_STEP_MODE, help="Step mode: 'companies' or 'all'.")
    parser.add_argument("--cdp", action="store_true", help="Connect to an open Chrome instance via port 9222.")
    parser.add_argument("--local", action="store_true", help="Test against local Docker instance (http://localhost:9292).")

    args = parser.parse_args()

    raw_target = args.match_id
    if not raw_target:
        raw_target = input(f"{C_BOLD}Enter 18xx.games Match ID or URL: {C_RESET}").strip()

    if not raw_target:
        print("No match ID provided. Exiting.")
        sys.exit(1)

    base = DEFAULT_LOCAL_URL if args.local else DEFAULT_BASE_URL
    run_scrubber(
        raw_target,
        delay_s=args.delay,
        step_mode=args.mode,
        base_url=base,
        use_cdp=args.cdp,
        use_local=args.local
    )