# 18xx Zero-Tab Dashboard

> *"The interface should disappear into the game."*

An alternative, unified, single-screen spatial interface for [18xx.games](https://18xx.games). 

This project re-engineers digital 18xx interaction from the ground up: moving away from multi-tab spreadsheet navigation and text-log auditing back to the persistent, tactile, and spatially stable mental model of an authentic tabletop board game.

---

## 📺 Video Demonstrations

* **[2-Minute Quick Demo](https://www.youtube.com/watch?v=F9EsonE6uOM)** — A rapid visual tour of the zero-tab spatial layout in action.
* **[Full Walkthrough & Design Architecture (1846)](https://www.youtube.com/watch?v=p6TUtUSi_AM)** — Complete match walkthrough covering Stock Rounds, Operating Rounds, tile and token lays, route calculation, and interface telemetry.
* **[YouTube Channel: @Rails-Evolution-18xx](https://www.youtube.com/@Rails-Evolution-18xx)** — Strategy guides, rule deltas, and live gameplay analysis using the dashboard.

---

## 🧭 Why This Exists

Modern digital 18xx implementations run on rock-solid game engines, but their presentation defaults to asynchronous spreadsheet tables:
* Key information is fragmented across disconnected browser tabs (*Game, Map, Market, Tiles, Spreadsheet, Tools*).
* Tracking what opponents did during your absence requires reading through dozens of lines of text logs.
* Switching tabs continuously breaks spatial memory. On a physical table, players never fold up the board just to inspect the stock market or check the bank pool.

The **Zero-Tab Dashboard** integrates the entire game state into a single, immutable, non-collapsing viewport while enforcing a strict distinction between clerical automation and player agency:

1. **Automate Bookkeeping:** Graph traversal, tile validity, legal route arithmetic, and asset accounting are fully handled by the software.
2. **Preserve Strategic Integrity:** The interface strictly refuses to automate derived strategic decisions. It does not calculate optimal route combinations, forecast opponent cash flows, or display real-time net-worth leaderboards during play. Strategic calculation remains entirely the player's responsibility.

---

## 📐 The Five Visual Laws

Visual encoding across the dashboard is governed strictly by five orthogonal channels:

| Visual Channel | Function | System Behavior |
| :--- | :--- | :--- |
| **1. Shape** | **Domain Ontology** | Components retain their real-world physical geometry and never mutate into generic web buttons. Tokens are circles; train cards are rounded pills; share certificates are rectangular cards; private companies feature asymmetric silhouettes. |
| **2. Colour & Typography** | **Semantic Meaning** | Colour communicates system status, not decoration. **Green** indicates asset acquisition/ingress; **Red** indicates asset disposal/egress; **Cyan** is strictly reserved for spatial map affordances; **Blue** is locked to state progression. All monetary values share invariant typography. |
| **3. Movement** | **Positional Change** | Animation is restricted to spatial deltas representing physical asset transfer (e.g., certificates sliding from the IPO into a player portfolio, or tiles dropping onto hexes). |
| **4. Breathing** | **Connection & Affordance** | Low-frequency luminance/scale oscillation (~1 Hz) visually links distributed entities. Hovering over a corporation pulses its map tokens, market marker, and charter simultaneously. Valid placement targets pulse in cyan. |
| **5. Visual Weight** | **Decision Consequence** | Visual emphasis, scale, and contrast scale proportionally with the irreversibility and impact of an action (e.g., bankruptcy, emergency train purchases). |

---

## 🖥️ Layout & Interaction Engine

<pre>
┌────────────────────────────────────────────────────────────────────────┐
│                        TOP NAVIGATION / TAB BAR                        │
│ [Game] [Map] [Market] [Tiles] [Spreadsheet] [Tools] | [DASHBOARD]      │
│                                           [⚡] [🧵] [⏱] [🌐] [♫]       │
├───────────────────────────────────┬────────────────────────────────────┤
│                                   │ ACTIVE PLAYER & OPERATING ORDER    │
│                                   ├────────────────────────────────────┤
│                                   │                                    │
│             THE MAP               │         THE STATUS MATRIX          │
│      (Persistent Geometry)        │  (Players, Companies, Bank, Depot) │
│                                   │                                    │
│                                   ├────────────────────────────────────┤
│                                   │         THE STOCK MARKET           │
│                                   │      (2D Spatial Valuation)        │
└───────────────────────────────────┴────────────────────────────────────┘
</pre>

* **The Map (Left):** High-resolution topological canvas with cyan placement affordances, manual or automated route overlays, and large-format toggleable revenue centers.
* **The Status Matrix (Top-Right):** Replaces the spreadsheet with semantic groupings:
  * *Muted Purple:* Corporate charters, treasuries, trains, and token reserves.
  * *Muted Green:* The Bank, IPO, Bank Pool, and Train Depot.
  * *Clear White / Grey:* Player portfolios, cash balances, certificate limits, and privates.
* **The Stock Market (Bottom-Right):** The persistent 2D market grid showing exact share coordinates, ledges, and capitalization zones.
* **The Action Hub (`⚡`):** A dockable, resizable tactical control panel that manages turn actions sequentially:
  * Displays round-specific direct-manipulation controls.
  * Bottom-left quick **Undo / Redo** controls.
  * **Invariant Progress Control:** The bottom-right corner is permanently anchored for committing choices and advancing state (`Pass`, `Done`, `Submit`, `Pay Out`).
* **Turn Telemetry:**
  * Active player row illuminated in pure white.
  * Subtle 1 Hz soft green peripheral border pulse.
  * Psychoacoustic turn chime engineered to avoid microphone bleed during voice calls.
* **Multi-Game Switcher (`🌐`):** Displays all concurrent active games with immediate green status indicators when your turn is pending.
* **Game History Thread (`🧵`):** A scrubbable timeline slider allowing move-by-move historical audit without disrupting active board coordinates.

---

## 🛠️ Architecture & Sandboxing

The dashboard is built to drop cleanly into `18xx.games` without destabilizing upstream logic:

* **Hermetic Directory Isolation:** 100% of the code, styles, state adapters, and DOM mutations live inside the `view/dashboard/` directory.
* **Zero Core Engine Mutation:** State is consumed strictly read-only. Upstream rules, models, and calculation routines are never altered or monkey-patched.
* **Zero Global CSS Pollution:** All styling is encapsulated; native tabs (`Game`, `Map`, `Market`, `Spreadsheet`) and platform themes (including Night Shift) operate independently.
* **Native Fallback Pipeline:** Tested across ~30 titles. If an obscure title presents an action branch or unique mechanic that lacks a bespoke dashboard component, the Action Hub displays a notice and mounts the native, unstyled engine control inline. Play is never blocked.

---
## 🚀 Installation

### Option 1: Chrome Web Store (One-Click)
*Automated background updates for Chrome, Brave, Edge, and Opera.*

* **Status:** ⏳ *Currently under review by Google. Direct store link will be posted here upon approval.*

---

### Option 2: Direct Install (Available Now)
*Works immediately on any Chromium browser (takes 60 seconds).*

1. Download the latest build: [**18xx-dashboard-v1.0.0.zip**](https://github.com/sbleeck/18xx-dashboard/releases/latest)
2. Unzip the file on your computer.
3. In your browser, open `chrome://extensions/`.
4. Toggle **Developer mode** ON (top-right switch).
5. Click **Load unpacked** (top-left) and select the unzipped `18xx-extension` directory.
6. Open [18xx.games](https://18xx.games)—the **Dashboard** tab will appear in the navigation bar.


---

---

## 🐛 Feedback & Bug Reports

The dashboard is currently in active beta. Testing across uncommon titles, multi-entity mergers, complex auctions, and non-standard capitalization models is particularly valuable.

If you encounter an issue or strange behavior, please report it via [GitHub Issues](https://github.com/sbleeck/18xx-dashboard/issues) or email **`bleeck@gmail.com`** with:

1. **Title:** Which 18xx game were you playing?
2. **Context:** What round and specific action was being taken?
3. **Expected vs. Actual:** What did you expect to happen, and what occurred?
4. **Environment:** Browser and operating system.
5. **Game Link:** The game number or URL (if public).
6. **Visuals:** A screenshot or short screen recording if possible.

---



## ☕ Support the Project

If the Zero-Tab Dashboard improves your matches, consider supporting ongoing development, hosting, and title expansion:

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/stefanbleeck)

*One-off tips and monthly memberships help fund bespoke visual components across new 18xx titles.*


---

## 📜 License & Credits

* Built by **Stefan Bleeck**.
* Dedicated to the [18xx.games](https://18xx.games) community, built upon the foundation created by Toby Mao and contributors.
* Derived from 25 years of 18xx tabletop play, DOS simulations, and the open-source *Rails* Java project.