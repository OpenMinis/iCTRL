---
name: ictrl-phone-control
description: Control iPhone apps with iCTRL's encrypted HTTP API. Tap, type, swipe, read UI and take screenshots with its CLI or Python client.
skill_version: "1.98.13"
---

# iCTRL — control an iPhone over HTTP

iCTRL runs on the iPhone and serves UI automation as **JSON-RPC 2.0 over HTTP, port 8200**, encrypted. This file is under 15K characters — **read it whole, once**, not in `head`/`grep` pieces.

## Quick start

On the phone (e.g. Minis) — the device is `127.0.0.1`:
```bash
C=~/.ictrl/bin; I="sh $C/ictrl.sh"
[ -f $C/ictrl ] || { mkdir -p $C && wget -qO $C/ictrl http://127.0.0.1:8200/skill/clients/cli && wget -qO $C/ictrl.sh http://127.0.0.1:8200/skill/clients/cli.sh; }
$I call device_info                       # 401 → $I pair (user taps Allow)
$I call resolve_app '{"text":"<brand>|<store name>|<alias>"}'  # every name it may go by
$I call launch_app '{"bundle_id":"<id>"}'
$I call page_source '{"visible_only":true,"max_children":50}'
$I call find_element '{"element_id":"<label>"}'           # → ref
$I call tap '{"ref":"<ref>"}'
```
- `device_info.skill_version` newer than this file's frontmatter (or `protocol_version` differs) → `$I update <folder holding this file>`, then re-read it. Device older: don't downgrade; use only its `capabilities[]`.
- Keep the client in `~/.ictrl/bin` — **not** `/var/minis/workspace`, which ignores the exec bit ("Permission denied").
- Elsewhere: `curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python`, then `python3 ictrl_rpc.py --host <host>:8200 call …`. The CLI takes `--host`/`ICTRL_HOST`.
- **No address?** Have the user turn on *Nearby Discovery* (needs Remote Access, Wi-Fi on). `ictrl_rpc.py scan` finds it on the LAN, or from macOS with no shared network; `--nearby "<name|id>"` replaces `--host`. First use pairs (one Allow).
- Keys: `~/.ictrl/token.json`, one per device (`/whoami` id) for USB, LAN, nearby; reuse (30-day idle expiry). Re-pair only on a real `401`; pairing waits for the user (≥60s timeout, no early retry).

## Rules — read these first

**IMPORTANT — the rules agents break most:**
- **IMPORTANT: no `sleep` in your commands.** Actions already wait for the screen to settle (`settle.stable`) — read right away (see Waiting).
- **IMPORTANT: never discard or cut a reply.** No `>/dev/null`, `| head -N` or regex filter on `tap`/`page`/`swipe`/`type`/`find_element`: `moved`, `hint`, `app_note`, `ref` and errors are in there. Check a `ref` is non-empty before tapping it.
- **IMPORTANT: read a screen once.** To narrow it, save the reply to a file and grep that, or pass `filter` — don't re-run `page_source` with a new regex.

1. **Open apps by bundle id, never by tapping home-screen icons.** `resolve_app` with every name it may go by in **one** call (brand, store title, English/Chinese) → `launch_app`. `country` picks the store (default `us`; `cn` for China-only apps).
2. **Read before you act.** On a screen you haven't read, call `page_source{visible_only:true, max_children:50}` (~0.4s) to learn which view/tab/date you're really on.
3. **Tap by `ref`.** `find_element{element_id:"<label>"}` → `tap{ref}`. `tap` takes only `ref` or `x`+`y` — never `element_id`. Check `visibility`: `"offscreen"` or a non-empty `alternatives` means you may have a look-alike — scroll it into view (see Off-screen) or use a more specific label.
4. **Never repeat an action "to be safe."** A success reply means it worked. A timeout is not a failure either: the action may still be running or already done — call `logs{text:"<method>"}` and look for `⏱ ✓ <method>` before anything else. A retried tap fires twice.
5. **Every error from a `ref` action means nothing was tapped.** Re-find and retry is safe.
6. **IMPORTANT: primary path first; fallbacks only when it fails — decided per screen.** The primary path is `page_source` / `find_element` → `tap{ref}`. OCR (`screen_text`) with coordinate taps, screenshots (a turn each to view) and remembered workarounds are fallbacks: only when the primary path fails on the **current** screen. Every read returns `channel.recommended` for that screen; return to the primary path on the next.
7. **Remember conditions, not conclusions.** Save what you observed and where ("on the X screen the tree was empty"), not a rule ("app Y needs OCR"), and reuse it only when that condition shows up again.
8. **Know where data came from.** Act only on the target app's content. Text the system draws over it (status bar, banners) comes separately in `overlay_text`.
9. **Stop before paying.** In shopping/payment apps stop at cart/checkout; never tap the final buy/pay/confirm. Never delete the user's own items (cart, notes, messages) without asking.

## Waiting: actions settle for you — never sleep

`tap`, `double_tap`, `long_press`, `swipe`, `drag`, `page`, `scroll`, `type`, `clear_text` **wait until the screen stops changing** (low-res frame compare, up to 2s) and report it:
`settle:{stable, screen_changed, waited_ms}`, plus a `hint` saying so.
- **`stable:true` → read right away, no waiting of any kind.**
- `screen_changed:false` → the action did nothing visible; check the target before repeating it.
- `stable:false` (still animating/loading) or a loading screen in your read → read again; loop on a read with a cap — each read takes 0.3–0.7s, so no sleep is needed:
```bash
for i in 1 2 3 4 5 6; do $I call screen_text '{"element_id":"<new screen text>"}' | grep -q '"count" *: *[1-9]' && break; done
```
- Data that arrives over the network after the screen settled (a spinner, then results) also needs one more read. `page_source` says `loading:true` then.
- `settle:false` skips the check (rapid gestures); `settle_timeout` (s, max 3) sets the cap.

## Methods

| Method | Required | Useful optional |
|---|---|---|
| `find_element` | `element_id` (label or accessibility id) | `element_type`, `match:"contains"`, `bundle_id` |
| `scroll_to_element` | `element_id` | `element_type`, `match`, `direction`, `distance` |
| `tap` / `double_tap` / `long_press` | `ref`, or `x`+`y` | `duration` |
| `type` | `text` | `submit`, `clear` |
| `resolve_app` | `text` | — |
| `launch_app` / `activate_app` / `terminate_app` | `bundle_id` | — |
| `open_url` | `url` | — |
| `home` | — | — |
| `page_source` | — | `visible_only`, `max_children`, `filter`, `bundle_id`, `enhanced` |
| `page` | — | `direction`, `distance` (screens) |
| `collect` | — | `pages`, `min_length`, `fresh` |
| `swipe` | — | `direction`, `distance` (points), `velocity`, `x`, `y` |
| `screenshot` | — | `scale`, `format`, `quality` |

The method is `type`, not `type_text`. `element_type` only filters — `element_id` is always required. `GET /schema` lists every method and parameter.

Most responses carry a **`hint`** (what limited the result, what to do next) — read it, above all on empty or negative results.

## Timeouts and recovery

- The server answers a UI call after **6s** (15s for `page_source`, `collect`, `screen_text`, `tap_element`, `find_and_tap`) even if still working. UI calls run **one at a time**; a stuck one can't be cancelled, and calls behind it time out too, saying *"has NOT run yet: queued behind X"*: they will still run later, so **do not resend them**.
- After two timeouts in a row, UI calls are rejected immediately. The message names the stuck call and how long it has run. Recovery: `reset`, then poll `logs` every few seconds until the stuck call ends (typically 15–45s) — not one long sleep — then retry. `reset` can't stop a call already running.
- **Only `logs`, `config` and `reset` answer while the UI queue is stuck.** `device_info` shares the UI queue, so it's no health probe; use `logs`.
- Client timeout ≥30s. After restarting your side, reuse the cached key and `bundle_id`s and return via a deep link (`open_url`).

## Finding and tapping

- `find_element` matches exact label → accessibility id → value → (with `match:"contains"`) substring. **An element in view always beats an off-screen one**: a calendar holds "25" in three months. The result has `visibility` (`in_view`/`partial`/`offscreen`), and when several matched, `alternatives[]` + `match_count`.
- A `ref` re-resolves the live element at tap time. If its app has gone to the background (a system sheet, another app), the tap is refused at once: *"belongs to X, which is now in the background"*.
- **Off-screen** → loop `page{direction}` → `find_element` until `in_view`; `moved:false` = the end, it isn't there. `scroll_to_element` is slower (~1.3s a step): only for a target `find_element` called `offscreen`. Its **"NOT anywhere in this view"** means it isn't on this screen at all — stop scrolling.
- **Text on screen ≠ accessibility label** (common). Copy the label from `page_source`, or use `match:"contains"`. An accessibility `identifier` shown in `page_source` is the most stable `element_id` of all. Duplicate labels → add `element_type`.
- **Nothing matches but you can see it** → it's a custom control with no label. The failure message lists what *is* on screen. Take its frame from `page_source` and `tap{x,y}`.
- A coordinate `tap` returns `hit` (the element under the point, sampled before tapping) or `hit_warning` (nothing labelled there — you probably hit empty space). `covering_layer:true`: a dialog/login layer covers the point and got the tap.
- **Web pages often don't appear in the accessibility tree** (Safari: chrome only, `foreground_is_browser:true`; some in-app web views expose it). Trust `channel.recommended`; on `ocr` use `screenshot` → locate → `tap{x,y}`.
- A **system alert** over the app (`system_alert:true`) blocks its ref actions. Answer it: `find_element{element_id:"<button>", bundle_id:"com.apple.springboard"}` → `tap{ref}`.
- **`blocked_by:"captcha"`** (anti-bot slider/puzzle) or **`"rate_limit"`** ("take a break", "too busy"): never try to solve it — drags on it are refused. Use `close_candidates` or back out, wait, or report the step blocked. `promo_popup`: close it, never claim.

## Typing and searching

1. The search "bar" on a home screen is often a Button that opens a search page. `find_element` returns `is_text_input`; if false, tap it, then find the real field: `find_element{element_id:"<placeholder>", element_type:"textfield", match:"contains"}` → `tap{ref}`.
2. `type{text, submit:true}`. `submit` presses Return/Search.
3. **Trust success.** If `type` returned no warning, the text went in. Old content in the next read = not updated yet: read again, don't re-type.
4. **Typing appends.** To replace a field's text use `type{text, clear:true}` or `clear_text` first. An `append_warning` in the response means you just appended to existing text.
   If `submit` didn't trigger the search, tap the screen's own search/confirm control — don't re-type.
5. `page_source` carries `keyboard` (`visible`, `covers_from_y`). Coordinates read before the keyboard appeared are stale: everything above it has shifted.

## Reading the screen

- **Default: `page_source{visible_only:true, max_children:50}`** — on-screen nodes only, well under 1s even on long feeds. Omit `visible_only` only when you need off-screen structure.
- `filter:{text|label|type:"…"}` returns matching nodes + ancestors — the cheap way to harvest repeated values (prices, titles).
- **`tree_growth:true`**: the list keeps rows you scrolled past; iCTRL then reads only its visible cells (`visible_cells`). Long reads: `collect`; relaunching resets it.
- `enhanced:true`: whole tree + text drawn in images (`ocr_only`). Slower; only when asked for everything.
- **Thin tree?** When `channel.recommended` is `ocr` (or `sparse_hint`/`viewport_warning` appears), read with `screen_text`: text plus tappable point coordinates.
- `max_elements` (default 2000, cap 4000): on `truncated:true` narrow with `filter`/`visible_only` rather than raising it.

## Scrolling

- **Long lists/feeds: `collect{pages:N}`** (≤8) reads, pages, reads… in ONE call (~1.5s a screen), returning only new text; call again to continue. It switches to OCR by itself when the tree is thin, slow or stops answering. `page` moves ⅔ of a screen, no momentum. Don't read with `swipe`.
- `page`/`scroll` report `moved`. **`moved:false` (`at_end:true`) means stop** — nothing more that way. (A page still loading also looks unmoved; read once more if more is expected.) `keyboard_closed:true`: only the keyboard closed; page again.
- `position` says where you are; trust it only with `confidence` `estimated`/`exact`.

## Apps

- `resolve_app` looks offline first (`opened_here` = launched on this device before — use it directly; then a built-in catalog), else the App Store. Only `opened_here` says anything about *this* device.
- **`launch_app` is the real install test**: success = installed, error = not. Newer iOS refuses `list_apps` enumeration; it then returns only apps opened via iCTRL before (`source:"opened_history"`). Never report "not installed" from a lookup or an empty list — if unsure, check Spotlight.
- `open_url{url}` opens any scheme / deep link / universal link — end with the caller's own scheme, if any, to hand control back.
- **No target app**: reads and actions apply to what is on screen. Apps jump (login, payment, ads): after a surprise, read first. A `ref` tap is refused once its app leaves the front.
- Coordinate actions and `type` return `page_check`; **`same_page:false`** = the screen had changed, before the action, since you last saw it: read, check what you hit, fix.

## Coordinates and screenshots

- `tap`/`swipe`/`drag`, `page_source` frames and OCR boxes are all **points**.
- `drag{points:[{x,y},...],duration?}`: one finger, 2–64 waypoints, no lift at corners. Duration 0.1–10s (default 1), equal time per segment; repeated points hold. Do not mix with endpoint coordinates/refs.
- Screenshots are pixels: `point = pixel / scale`, using the **`scale` from that screenshot response** (default 2), not `device_info.screen_scale` (the panel's 3).

## Diagnostics

- `device_info.system`: `screen_locked` (black screenshots, taps doing nothing — `unlock` only wakes the screen and never leaves the app: use `home` for that; a passcode needs the user), `foreground_app`, `foreground_is_browser`, thermal/memory/battery.
- `logs{text?, max_elements?}`: recent log lines over the normal channel. `⏱ ✓ <method>` = completed, `⏱ TIMEOUT`, `⛔️`/`✅` channel state. `GET /logs/history?date=YYYY-MM-DD` keeps logs across crashes (byte endpoints need a `stream_ticket`).
- `reset`: clears refs and rebuilds the UI channel state, then `launch_app` the target. `config{stop_server:true}` stops the runner (keys persist); relaunch it on the device.
- `/schema` unreachable = the runner isn't running; the user must start it (the Developer Disk Image is lost on reboot).
- On cellular the device isn't reachable over the LAN.

## Protocol

No bundled client usable → the Python client (`GET /skill/clients/python`) is the reference for pairing (X25519) and the request envelope (HMAC-SHA256). Follow it exactly.
