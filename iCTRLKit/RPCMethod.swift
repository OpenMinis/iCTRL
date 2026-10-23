import Foundation

struct RPCParamDef: Encodable {
    let name: String
    let type: String
    let required: Bool
    let description: String
}

struct RPCMethodDef: Encodable {
    let name: String
    let description: String
    let params: [RPCParamDef]
    let returns: String
}

struct RPCMethodRegistry {
    static let methods: [RPCMethodDef] = [
        RPCMethodDef(
            name: "config",
            description: "Read or update server settings and manage authorized sessions. With no params: returns current config plus the list of authorized sessions (client name, masked token prefix, granted/expiry times). Pass allow_remote_access and/or listen_port to change settings (persisted; server restarts, dropping the connection — reconnect at the returned address). Pass revoke_session_id to remove one session, or clear_sessions=true to revoke ALL tokens (including your own). Pass stop_server=true to SHUT DOWN the service (stops listening after replying; re-launch the runner to restart — tokens are preserved so no re-auth is needed).",
            params: [
                RPCParamDef(name: "allow_remote_access", type: "boolean", required: false, description: "true = listen on all interfaces (LAN reachable); false = 127.0.0.1 only"),
                RPCParamDef(name: "listen_port", type: "number", required: false, description: "TCP port to listen on (1..65535, default 8200)"),
                RPCParamDef(name: "revoke_session_id", type: "string", required: false, description: "session_id of a single authorization to revoke"),
                RPCParamDef(name: "clear_sessions", type: "boolean", required: false, description: "true = revoke all authorized tokens immediately"),
                RPCParamDef(name: "nearby_discovery", type: "boolean", required: false, description: "Advertise to nearby Apple devices over peer-to-peer Wi-Fi (needs allow_remote_access). Switching it on is accepted only from this device (the iCTRL app or USB); switching it off from anyone"),
                RPCParamDef(name: "device_name", type: "string", required: false, description: "Name advertised to nearby (peer-to-peer) clients, at most 63 bytes; \"\" restores the default (model plus a short device id)"),
                RPCParamDef(name: "stop_server", type: "boolean", required: false, description: "true = stop the service (stops listening ~1s after replying). Re-launch the runner to restart; tokens persist."),
            ],
            returns: "{allow_remote_access, listen_port, address, restarted, device_name, lan_addresses, ipv4_interfaces, nearby:{enabled, advertising, status, interface, name, device_id, port}, active_sessions, sessions:[{session_id, client_name, tok, granted_at, last_active_at, expires_at, last_address, last_via: local (this device or USB) | lan | nearby (AWDL) | vpn | cellular | other}], cleared_sessions}"
        ),
        RPCMethodDef(
            name: "stream_ticket",
            description: "Mint a single-use, ~60s ticket authorizing ONE plain GET to /stream or /logs*. Those are raw byte responses a browser/player fetches directly, so they can't carry a per-request encrypted envelope; this hands out a short-lived credential instead. Call it over the encrypted channel (like every RPC), then append ?ticket=<ticket> to the URL. The ticket is consumed on first use — mint a new one per stream/log fetch.",
            params: [],
            returns: "{ticket, expires_in (seconds), hint}"
        ),
        RPCMethodDef(
            name: "device_info",
            description: "Get device name, model, OS version, the coordinate space (point size for tap/swipe, pixel size for screenshots, scale), AND the server's identity: server_version, protocol_version, and a capabilities array — so ONE device_info call gives you both the device and what this server supports (no separate /schema fetch for feature detection). CALL THIS FIRST before any coordinate-based action.",
            params: [],
            returns: "Object with point_width/point_height (tap space), pixel_width/pixel_height (screenshot space), scale, a 'hint' string, plus server_version (semver), protocol_version (int), capabilities (array of feature tags, e.g. envelope_v1, stream_ticket, find_element_ref, clear_text, page, stop_server), skill_version + skill_update_hint (if the device's skill_version is newer than your SKILL.md frontmatter, update before anything else — the hint has the commands), and a 'system' object of live health: thermal_state, low_power_mode, total_memory_mb, processor_count, process_memory_mb, process_cpu_percent, system_free_memory_mb?, disk_total_mb, disk_free_mb, disk_available_now_mb, disk_used_percent, battery_percent?, battery_state?. Keys the sandbox refuses are absent rather than zero. NOTE: process_cpu_percent is THIS runner's usage (can exceed 100% across cores), not system-wide — iOS does not expose global CPU. disk_free_mb matches what Settings shows (counts purgeable space); disk_available_now_mb is the stricter figure."
        ),
        RPCMethodDef(
            name: "page_source",
            description: "Inspect the current UI: returns the accessibility/view hierarchy as text (element types, labels, identifiers, frames in POINTS). Use it to UNDERSTAND layout — NOT as your locate-and-tap loop. To act on a control you already know by label, do NOT read its frame and tap x,y; call find_element{element_id:<label>} → tap{ref} (a ref survives scroll/animation, needs no coordinate math, and no re-read to re-derive coords). Reserve coordinate taps for elements with no usable label. On rich pages the full tree is large and the first call after a launch can be slow while the UI settles — scope it: filter returns only matching nodes+ancestors (also great for HARVESTING repeated data — filter by a substring common to the values you want), max_elements caps the count. 2000-node cap by default (truncated:true when hit); on a long recycling list pass visible_only:true to return just the on-screen rows. Use screenshot only when an element is missing here or you need visual detail.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "Inspect this app's tree; omit for the detected foreground app"),
                RPCParamDef(name: "filter", type: "object", required: false, description: "Return only matching nodes + their ancestors. {label:'<substring>'} (label/value substring, case-insensitive), {type:'button'} (element type), or {text:'<substring>'} (label+value+id substring). Also the cheapest way to HARVEST repeated data — filter by a substring common to the values you want, far easier than parsing the whole tree."),
                RPCParamDef(name: "max_depth", type: "number", required: false, description: "Max tree depth. WARNING: labels/tappable controls live near the LEAVES, so a shallow depth (3-4) returns structure with NO useful labels and you'll have to re-fetch — a wasted call. Use max_depth ONLY to preview overall layout; to FIND an element use filter or find_element instead."),
                RPCParamDef(name: "max_elements", type: "number", required: false, description: "Max nodes to RETURN (default 2000, hard cap 4000). If hit, response is truncated:true. NOTE this does not make the call faster: it trims after the tree is already fetched (measured: 20 vs 2000 both cost the same fetch time). To cut the TIME use max_depth or max_children, the only two limits the accessibility server applies while walking."),
                RPCParamDef(name: "max_children", type: "number", required: false, description: "Max children per node the accessibility server will walk (default 1000, cap 5000). One of only two knobs that bound the FETCH itself — the expensive phase (on a chat list, fetch is ~99% of the call). Lower it on wide recycling lists where thousands of offscreen rows hang off one container."),
                RPCParamDef(name: "enhanced", type: "boolean", required: false, description: "true = richest read, only when asked for everything: the whole tree (no visible-cells shortcut, max_children 5000) plus, as ocr_only, on-screen text the tree lacks (text drawn in images) read by OCR and de-duplicated against the tree. Seconds slower on long lists."),
                RPCParamDef(name: "visible_only", type: "boolean", required: false, description: "Return ONLY nodes intersecting the screen, plus their ancestor path. Use on long/infinitely-scrolling lists (chat lists, feeds, timelines): such a list keeps far more rows in the tree than are on screen — measured 91% offscreen on a WeChat chat list — and those offscreen rows exhaust max_elements before the visible ones are reached, so the response truncates while still missing what you can see. This returns the CURRENT VIEWPORT only: to see more, scroll (page{direction:'down'}) and read again, or use scroll_to_element to jump to a known item. Omit it when you need to reason about content just offscreen — scroll_to_element needs the full tree. Cuts payload and node count sharply; cuts TIME only modestly, since a container's frame doesn't bound its children in a recycling list so every node is still visited."),
            ],
            returns: "{source: the tree as text, truncated, total_returned, max_children_used, timing:{fetch_ms,render_ms}, coordinate_space:'points', channel:{ax_coverage, recommended:'tree'|'ocr', why} for THIS screen, hint}. Includes visible overlay windows automatically. AUTOMATIC OCR FALLBACK: when the accessibility tree returns NO on-screen content (common on chat lists and feeds), the response also carries ocr_items[] — same keys as find_element, each tagged source:'ocr', tap via tap{x:center_x,y:center_y} — plus ocr_count, ocr_timing and ocr_reason explaining why. viewport_warning / sparse_hint flag a tree that is present but suspect."
        ),
        RPCMethodDef(
            name: "screen_text",
            description: "OCR the screen with Vision and return text boxes in the SAME shape find_element uses (x/y/width/height/center_x/center_y/label), so a hit feeds straight into tap{x:center_x,y:center_y}. FALLBACK for one specific failure: a long recycling list whose on-screen rows never reach the accessibility tree — measured on a scrolled WeChat chat list, every page_source variant returned ZERO on-screen rows because the element budget is spent on offscreen ones. Screenshots bypass the accessibility channel entirely, so this still works there. Limits: no `ref` (coordinates go stale on scroll — tap immediately), no identifier, element_type is always 'OCRText' so you cannot tell a button from a label, and it only sees RENDERED TEXT (icon-only buttons and images are invisible). Prefer find_element whenever the tree has the element.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: false, description: "Only return results containing this substring (case-insensitive). Omit for every text box on screen."),
                RPCParamDef(name: "match", type: "string", required: false, description: "'fast' uses Vision's fast recognition level (lower accuracy, quicker); default is accurate."),
                RPCParamDef(name: "scale", type: "number", required: false, description: "Minimum confidence 0..1 (default 0.3). Raise to drop shaky reads."),
            ],
            returns: "{count, items:[{label, confidence, x, y, width, height, center_x, center_y, element_type:'OCRText', is_text_input, exists}] (the target app's text only), overlay_text?:[text the system drew over the app — status bar, banners], channel:{ax_coverage, recommended:'tree'|'ocr', why} for THIS screen, coordinate_space:'points', timing:{screenshot_ms, ocr_ms}, hint}. OCR is the fallback: when channel.recommended is 'tree', page_source/find_element give refs and exact labels"
        ),
        RPCMethodDef(
            name: "logs",
            description: "Recent server log lines, over the encrypted RPC channel. Use this after a TIMEOUT: a timed-out call may still have SUCCEEDED on the device, and '⏱ ✓ <method>' in the log is how you tell. Runs on the non-UI lane, so it answers even while UI calls are wedged — unlike GET /logs, which is a byte stream needing a stream_ticket minted over this same channel.",
            params: [
                RPCParamDef(name: "text", type: "string", required: false, description: "Only return lines containing this substring — pass the method name to check one action."),
                RPCParamDef(name: "max_elements", type: "number", required: false, description: "How many lines to return (default 80, max 500). Most recent last."),
            ],
            returns: "{lines:[string], count, total, hint}"
        ),
        RPCMethodDef(
            name: "reset",
            description: "Recover after UI automation stops responding (calls timing out, logs showing kAXErrorServerNotFound). Clears cached element refs, the learned front-app ids and the cached screen size, and re-arms the circuit breaker that rejects UI calls once the channel is judged unhealthy. Does NOT itself restart XCTest's accessibility session — after calling it, launch_app (or activate_app) the target app to force a reconnect, then retry. If UI calls still time out, restart the runner: config{stop_server:true}, then relaunch it. Safe to call any time; runs off the UI queue so it works even while UI methods are blocked.",
            params: [],
            returns: "Object: {reset:true, cleared_refs, unbound?, foreground_app?, hint}"
        ),
        RPCMethodDef(
            name: "screenshot",
            description: "Capture a screenshot as base64 JPEG (default) or PNG. SECOND CHOICE, not your default way of seeing the screen — reach for page_source{visible_only:true} first: it is usually faster (~100ms vs ~150ms), far smaller, and gives every element's type, label and exact frame. To ACT on a control, prefer find_element{element_id} → tap{ref}: a ref re-resolves the live element, survives scroll/animation, and avoids the pixel→point conversion that coordinate taps require (a conversion that silently mis-taps when it goes wrong). Use a screenshot when the tree genuinely cannot answer: unlabelled/icon-only controls, visual layout judgements, confirming an action landed, or when page_source returns sparse data (see its ax_coverage / sparse_hint / viewport_warning) — most often a WEB VIEW, whose page content never enters the accessibility tree. Captures the WHOLE SCREEN by default; pass bundle_id only to crop one app's window (slower). Image is in PIXELS, taps are in POINTS. Optional 'scale' (default 2, max 3).",
            params: [
                RPCParamDef(name: "scale", type: "number", required: false, description: "Output pixels-per-point (default 2, max 3; smaller = faster/less detail, e.g. 1 or 0.5)"),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "Crop to just this app's window (slower, time-bounded). OMIT for the default full-screen capture (fast) — the default is NOT scoped to the launched app."),
                RPCParamDef(name: "format", type: "string", required: false, description: "'jpeg' (default) or 'png'. JPEG is 5-10x smaller, which cuts BOTH transfer and the client's envelope decryption time — response size dominates a screenshot's end-to-end cost. Use 'png' only when you need lossless output (pixel diffing, OCR on fine text)."),
                RPCParamDef(name: "quality", type: "number", required: false, description: "JPEG quality 0.1-1.0 (default 0.6). Ignored for PNG. Lower = smaller/faster."),
            ],
            returns: "Object: {data: base64 image, format:'jpeg'|'png', bytes, quality?, pixel_width, pixel_height, point_width, point_height, scale, scope:'screen'|'app', scoped_to?, hint, prefer_instead}. `hint` carries the pixel→point conversion for THIS image; `prefer_instead` says when find_element/page_source would have served you better — read it before tapping from the image."
        ),
        RPCMethodDef(
            name: "tap",
            description: "Tap either by a stable 'ref' (from find_element/scroll_to_element — RECOMMENDED, re-resolves the live element and won't drift) OR by x,y coordinates in POINTS. If reading from a screenshot, convert: point = pixel / scale. Out-of-range coords return the valid range. Bottom tab bars sit just above the home-indicator safe area.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref from find_element/scroll_to_element (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points (0..point_width) — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points (0..point_height) — required if no ref"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use fast mode (bypasses quiescence waiting)"),
            ],
            returns: "{message, screen:{coordinate_space, point_width, point_height, scale}}"
        ),
        RPCMethodDef(
            name: "double_tap",
            description: "Double tap by a 'ref' (from find_element/scroll_to_element — preferred) OR by x,y in POINTS.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points — required if no ref"),
            ],
            returns: "{message, screen?}"
        ),
        RPCMethodDef(
            name: "long_press",
            description: "Long press by a 'ref' (from find_element/scroll_to_element — preferred) OR by x,y in POINTS.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points — required if no ref"),
                RPCParamDef(name: "duration", type: "number", required: false, description: "Press duration in seconds (default: 2.0)"),
            ],
            returns: "{message, screen?}"
        ),
        RPCMethodDef(
            name: "swipe",
            description: "Low-level swipe gesture. Do NOT use swipe to read through results/feeds — its default 100pt travel barely moves the page so you under-scroll and waste calls; use 'page' (one full screen, precise Page Down/Up, no overshoot) for reading, and 'scroll_to_element' to reach a known element. Reserve swipe for custom gestures (partial drags, horizontal carousels, pull-to-refresh). x,y OPTIONAL (default screen center). 'distance' = finger travel in points (default 100). 'velocity': 'fast'/'flick' adds iOS momentum (scrolls far, easy to overshoot), 'normal' (default), 'slow'/'precise' = exact drag.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "x", type: "number", required: false, description: "Start X (default: screen center)"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Start Y (default: screen center)"),
                RPCParamDef(name: "direction", type: "string", required: false, description: "Finger direction: up/down/left/right (default: up). 'up' reveals content below."),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Finger travel in points (default: 100)"),
                RPCParamDef(name: "velocity", type: "string", required: false, description: "fast/flick (momentum, far), normal (default), slow/precise (exact, no momentum)"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use synthesized fast path (default true); set false for legacy XCUITest swipe"),
            ],
            returns: "{message, from:{x,y}, velocity, note}"
        ),
        RPCMethodDef(
            name: "page",
            description: "Scroll by one screenful — like Page Down / Page Up on a keyboard. This is the RECOMMENDED way to read through a long page: it's PRECISE (no momentum/overshoot), so you won't skip content the way swipe with velocity:'fast' does. Use {\"direction\":\"down\"} (default, reveal content below) or {\"direction\":\"up\"}; the aliases page_down / page_up force the direction. After paging, re-read with page_source or screenshot. To jump straight to a known element, prefer scroll_to_element.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "direction", type: "string", required: false, description: "'down' (default, reveal below) or 'up'"),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Number of screenfuls (default 1; e.g. 0.5 = half a page, 2 = two pages). One screenful travels two thirds of the height, leaving a third overlapping so nothing falls between consecutive reads. Raising this past 1 trades that safety for fewer calls — on a feed, items can then pass between reads with no way to notice."),
            ],
            returns: "{message, screen, moved, position?, at_end?, hint?}. **moved:false means the gesture changed nothing** — you are at the end of the scrollable content in that direction, so scrolling again is wasted. `position` gives {percent, fraction, scrolled_pt, scrollable_pt, content_pt, content_top_y, content_bottom_y, rows_seen, row_estimate, confidence} derived from row frames; check `confidence` (estimated | low | exact) before trusting it, and note lazily-built lists report only visible rows so the figure pins near 0 or 100. A page still loading also reads as unmoved."
        ),
        RPCMethodDef(
            name: "collect",
            description: "Read a long list in ONE call: reads the visible screen, then pages down (the same precise, overlapping page as `page`) and reads again, up to `pages` times, stopping at the end. Returns only text it has not returned before for this app (consecutive calls continue the list, nothing repeated), each item with its type and frame so you can tap it by {x,y}. Use instead of page + page_source pairs on feeds and search results; it costs about 1s a screen. On a screen whose channel is ocr pass source:'ocr' (OCR per screen, ~1.5s each); in auto mode it switches to OCR by itself when the app stops answering accessibility (long-scrolled feeds).",
            params: [
                RPCParamDef(name: "pages", type: "integer", required: false, description: "Page moves after the first read (default 3, max 8); 0 = just read the current screen."),
                RPCParamDef(name: "direction", type: "string", required: false, description: "'down' (default) or 'up'"),
                RPCParamDef(name: "min_length", type: "integer", required: false, description: "Skip labels shorter than this many characters (default 2)."),
                RPCParamDef(name: "fresh", type: "boolean", required: false, description: "true = forget what earlier collect calls returned (start a new list)."),
                RPCParamDef(name: "source", type: "string", required: false, description: "'auto' (default: the tree, switching to OCR when the app's accessibility stops answering), 'tree', or 'ocr' (screens whose channel is ocr)."),
            ],
            returns: "{items:[{text, type, x, y, width, height, screen}], new_count, screens_read, at_end, elapsed_ms, hint}"
        ),
        RPCMethodDef(
            name: "scroll_to_element",
            description: "Scroll until an element is IN VIEW (inside the content area, not merely present in the tree), then return a stable 'ref' plus its tap point. If the element is already in the tree off screen it drags straight to it in one precise move; otherwise it searches, reversing once at an end when no direction is given, and reports 'NOT anywhere in this view' after reaching both ends — trust that and check the page/date/tab instead of scrolling further. Matching is EXACT by default (label == element_id, or accessibility id) to avoid hitting the wrong element — pass match:'contains' for a loose substring match. Narrow further with element_type. IMPORTANT: element_id must be the ACCESSIBILITY LABEL (from page_source), which may differ from on-screen text (e.g. a button showing '添加至购物袋' may have label '添加'). Prefer this over manual swipe loops.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Exact accessibility label or identifier (see page_source)"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains' (substring)"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "Restrict to a type: button/textfield/label/image/cell/switch/icon"),
                RPCParamDef(name: "direction", type: "string", required: false, description: "Finger direction to search in when the target is not in the tree yet: up/down/left/right. Omit it to search up (reveal below) and then the other way; give it to search one way only."),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Max scroll moves (default: 12). Aimed moves go exactly to a known target; searching moves are ~60% of the scroll area at a speed that adds no momentum, so nothing is skipped. Stops early at the end of the content."),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search; default = detected foreground app"),
            ],
            returns: "{found, swipes, ref, x, y, center_x, center_y, label, visibility, hint} — then tap by {ref}. Label matching ignores invisible formatting characters."
        ),
        RPCMethodDef(
            name: "scroll",
            description: "DEPRECATED — use 'swipe' instead (it supports velocity/momentum, custom distance, and start point), or 'scroll_to_element' to reach a specific element. This coarse full-screen scroll is kept only for compatibility.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "direction", type: "string", required: false, description: "Direction: up/down/left/right (default: down)"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "type",
            description: "Type text into the focused input field. A text field must already have keyboard focus — tap a real textfield first (see 'searching_and_typing'). Type always runs, but if no keyboard could be confirmed the response includes a 'warning' (keyboard detection can't see all third-party keyboards, so this is advisory, not a failure) — if the text didn't land, re-focus the field and type again. Set clear:true to EMPTY the field before typing (replace its contents); set submit:true to append Return/Search so the field's action (search/go/send) fires. See searching_and_typing guidance for the full search flow.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "text", type: "string", required: true, description: "Text to type (optional if clear:true — then it just empties the field)"),
                RPCParamDef(name: "clear", type: "boolean", required: false, description: "Empty the field before typing. Use whenever you are REPLACING contents — typing alone APPENDS, so a search box still holding the last query silently searches the concatenation (measured: '椰子汁' typed into a box holding '黄桃' searched '黄桃椰子汁'). The response carries append_warning when this is detected, but detection needs a readable focused field, so prefer clear:true over relying on it. Field must be focused first."),
                RPCParamDef(name: "submit", type: "boolean", required: false, description: "Append Return/Search to submit the field (recommended for search boxes)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "Tap X to focus before typing"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Tap Y to focus before typing"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use fast mode"),
            ],
            returns: "{message, warning?} — warning present when a focused keyboard couldn't be confirmed"
        ),
        RPCMethodDef(
            name: "clear_text",
            description: "Empty the currently-focused text field (delete its existing contents) without typing anything new. The field must already have keyboard focus — tap a real textfield first. Equivalent to type{clear:true} with no text. Sends backspaces sized to the field's value (falls back to a generous default when the length can't be read). If no focused keyboard could be confirmed the response includes an advisory 'warning'.",
            params: [],
            returns: "{message, warning?} — warning present when a focused keyboard couldn't be confirmed"
        ),
        RPCMethodDef(
            name: "home",
            description: "Press the home button and wait until SpringBoard is actually frontmost. Verified, not fire-and-forget: it polls for the transition and retries once, then errors if the foreground app never changed (a modal alert or system sheet can swallow the press).",
            params: [],
            returns: "{message, foreground_app, previous_app}"
        ),
        RPCMethodDef(
            name: "lock",
            description: "Lock the screen",
            params: [],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "unlock",
            description: "Wake the screen. This presses Home — it does NOT enter a passcode, so on a passcoded device it wakes the display and then fails after ~8s; the user must unlock by hand. It is also not a way to KEEP the screen awake: it only reacts once the device has already locked, by which point UI automation has broken. For a long unattended run, set 自动锁定/Auto-Lock to Never in Settings instead.",
            params: [],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "is_locked",
            description: "Check if the screen is locked",
            params: [],
            returns: "Lock state boolean"
        ),
        RPCMethodDef(
            name: "list_apps",
            description: "List installed apps with their bundle_id and name. The system enumeration is a private API that newer iOS refuses; when it does, this returns source:'opened_history' instead — apps previously opened successfully through iCTRL on THIS device, most recent first (every entry is installed, but the list is incomplete). An empty list never means 'not installed'. Prefer resolve_app to get a bundle_id from an app name. Pass text to filter by name or bundle substring (case-insensitive). By default only user apps are returned; pass element_type:\"all\" to include system apps.",
            params: [
                RPCParamDef(name: "text", type: "string", required: false, description: "Filter by name/bundle_id substring"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "'all' to include system apps (default: user apps only)"),
            ],
            returns: "{count, source:'system'|'opened_history', apps:[{bundle_id, name, last_opened?}], hint}"
        ),
        RPCMethodDef(
            name: "resolve_app",
            description: "Resolve an app NAME/keyword to its bundle_id. PURPOSE: launch_app/activate_app need an exact bundle_id, but you usually only know the app's name — call resolve_app first to turn e.g. '大麦' into 'cn.damai.iphone', then pass that to launch_app. HOW IT WORKS: looks offline first — apps this device has learned (opened successfully, or found by an earlier store lookup) merged per bundle_id with a built-in catalog of ~100 common apps — and falls back to the App Store's iTunes Search API for anything else (returns full metadata; the result is remembered so the next lookup is offline). Offline entries carry source:'opened_here' (launched on THIS device before — launch_app it directly), 'built-in' or 'learned'. Only 'opened_here' says anything about this device; otherwise launch_app will report if the app isn't installed. (Alias: search_app.)",
            params: [
                RPCParamDef(name: "text", type: "string", required: true, description: "App name or keyword. Put every name the app might go by in ONE call, separated by | (brand, store title, English and Chinese), e.g. 'Trip.com|Ctrip|Trip' — searched in parallel and merged, each result tagged with matched_term"),
                RPCParamDef(name: "country", type: "string", required: false, description: "App Store region to search (default: us). Choose it from context (Chinese name or China-only app → cn, jp, hk, …). Passing it skips the offline catalog and asks that store directly; every result says which region answered"),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Max results to return (default: 5, max 25)"),
            ],
            returns: "{count, term, source:'offline'|'app_store', apps:[{name, bundle_id, source?, installed_here?, last_opened?, developer?, category?, rating?, ...}], hint}"
        ),
        RPCMethodDef(
            name: "open_url",
            description: "Open a URL from the device — a custom app scheme, a universal/https link, or a deep link to a specific feature. Use this to jump into an app or a particular screen (e.g. 'weixin://' opens WeChat, 'alipays://platformapi/startapp?appId=…' opens an Alipay mini-program, 'https://…' opens in the default browser/handler, 'tel:10086' dials), or to jump BACK to a caller app via its callback URL (e.g. 'minis://done?status=ok'). For simply bringing an app to the front by identity, prefer launch_app with a bundle_id. URL-encode query values as needed.",
            params: [
                RPCParamDef(name: "url", type: "string", required: true, description: "The URL to open (scheme://… or https://…)"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "launch_app",
            description: "Open an app by bundle identifier (non-blocking, via LSApplicationWorkspace). If you don't know the bundle_id, use resolve_app to find it (e.g. 'Maps' → com.apple.Maps). There is no target app: every read and action applies to whatever is on screen, so if the app later jumps elsewhere, read the screen and decide. The app may still be drawing its first screen when this returns: read right away, and if you see a splash/placeholder, read again (poll ~0.5s, capped) — don't sleep a fixed time.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier (from resolve_app)"),
            ],
            returns: "{message, hint}"
        ),
        RPCMethodDef(
            name: "activate_app",
            description: "Bring an already-installed app to the foreground. Like launch_app but uses XCUIApplication.activate. Errors if the app isn't installed / can't be activated.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "terminate_app",
            description: "Terminate a running app",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "find_element",
            description: "Find an on-screen element by its accessibility LABEL (exact by default) or identifier, and get a stable 'ref' + frame back. Matching order: exact label → accessibility id → (if match:'contains') substring, and an element IN VIEW always beats an off-screen one (a month view holds '25' in three months — you get the visible one). The result carries visibility ('in_view'|'partial'|'offscreen') and, when several elements matched, alternatives[] and match_count. Use match:'contains' for loose matching, element_type to disambiguate. If the element needs scrolling to appear, use scroll_to_element instead. The returned ref is the reliable way to then tap/double_tap/long_press it.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label (from page_source) or identifier"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains' (substring)"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "button/textfield/label/image/cell/switch/icon/any"),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search; default = detected foreground app"),
            ],
            returns: "{exists, hittable, ref, element_type, is_text_input, x, y, width, height, center_x, center_y, label, value, note?} — element_type/is_text_input tell you if you matched a real input field vs a button; note flags the 'fake search bar' case. Then act by {ref}."
        ),
        RPCMethodDef(
            name: "tap_element",
            description: "Convenience: find an element by label/id and tap it in one call. Equivalent to find_element + tap{ref}. Prefer find_element when you also need the frame or want to double_tap/long_press.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains'"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "find_and_tap",
            description: "Locate an element by label/identifier and tap it in one call. Default is a synthesized tap at the element's center (fast, ~1s). Call `wait` 1-2s after any navigation (back/tab-switch/page open) before using this: mid-transition, every locate step runs 5-30x slower and matches mid-animation geometry, so the same call that takes ~1s settled can take 10s+ and still succeed — do NOT blindly retry a timeout (the tap may have landed; check /logs). IMPORTANT: on SwiftUI List/ForEach rows a synthesized tap can report success yet never land — if the tap visibly does nothing, retry with fast:false, which drives the native XCUIElement.tap() pipeline (slower, waits for quiescence, but resolves the element at hit time). Same match semantics: element_id may be a label OR identifier; pair with match:'contains' for partial substring matching.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier (see page_source)"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains' (substring)"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "Restrict to type: button/textfield/label/image/cell/switch/icon"),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "Target this app; omit for the bound/foreground app"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "false = native XCUIElement.tap() — the reliable path for SwiftUI Lists where a synthesized tap silently no-ops. Default true (synthesized)."),
            ],
            returns: "{message, matched, frame:{x,y,w,h}}"
        ),
        RPCMethodDef(
            name: "drag",
            description: "Drag between endpoints or follow points:[{x,y},...] with one uninterrupted single-finger touch. Path mode accepts 2...64 screen points and duration 0.1...10 seconds (default 1), equally timed per segment; do not combine with endpoints/refs. Endpoints may be coordinates (from_x/from_y/to_x/to_y in POINTS) OR element refs (from_ref/to_ref, which resolve to the element center). Use for reordering/sliders; for a simple scroll flick use swipe.",
            params: [
                RPCParamDef(name: "settle", type: "boolean", required: false, description: "Default true: after the action, wait until the screen stops changing (compares low-res frames; up to settle_timeout) and report it in `settle`. false = return right after the action."),
                RPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Max seconds to wait for the screen to settle (default 2, max 3)."),
                RPCParamDef(name: "points", type: "array", required: false, description: "Continuous single-finger path: 2...64 {x,y} objects in POINTS, one press and one lift; mutually exclusive with endpoints/refs."),
                RPCParamDef(name: "from_ref", type: "string", required: false, description: "Start element ref (alternative to from_x/from_y)"),
                RPCParamDef(name: "to_ref", type: "string", required: false, description: "End element ref (alternative to to_x/to_y)"),
                RPCParamDef(name: "from_x", type: "number", required: false, description: "Start X (points)"),
                RPCParamDef(name: "from_y", type: "number", required: false, description: "Start Y (points)"),
                RPCParamDef(name: "to_x", type: "number", required: false, description: "End X (points)"),
                RPCParamDef(name: "to_y", type: "number", required: false, description: "End Y (points)"),
                RPCParamDef(name: "duration", type: "number", required: false, description: "Drag duration in seconds (endpoints default 0.5; path default 1.0, range 0.1...10)"),
            ],
            returns: "{message, screen}"
        ),
        RPCMethodDef(
            name: "wait",
            description: "Pause for a fixed duration. Almost never the right tool: tap/swipe/page/type already wait for the screen to settle and report it in `settle` — when settle.stable is true, read right away; if not, read again (with a cap). A fixed pause is too long when the app is fast and too short when it is slow. Use it only for a delay that is genuinely time-based (a countdown, a video).",
            params: [
                RPCParamDef(name: "duration", type: "number", required: false, description: "Duration in seconds (default: 1.0)"),
            ],
            returns: "{message}"
        ),
    ]

    static func generateJSONSchema() -> [[String: Any]] {
        methods.map { m in
            var dict: [String: Any] = [
                "name": m.name,
                "description": m.description,
                "returns": m.returns,
            ]
            dict["params"] = m.params.map { p in
                [
                    "name": p.name,
                    "type": p.type,
                    "required": p.required,
                    "description": p.description,
                ] as [String: Any]
            }
            return dict
        }
    }

    /// A self-describing document for models: top-level guidance + methods.
    /// Returned from GET /schema and GET / (Accept: application/json).
    /// Semantic server version — bump on every functional change. 1.2.0 is the
    /// release that added the encrypted auth channel plus the docs/Skill,
    /// clear-text, page-source, and reliability improvements. Single source of
    /// truth for /schema AND device_info.
    static let serverVersion = "1.98.13"

    /// When this binary was built, as "YYYY-MM-DD HH:MM".
    ///
    /// `serverVersion` alone cannot tell two builds apart — bumping it is a
    /// manual step and gets forgotten, so a freshly installed runner can report
    /// the same version as the one it replaced. That ambiguity has already cost
    /// real debugging time: a change looked "not deployed" when the actual
    /// question was which binary was loaded. This is stamped by
    /// Scripts/stamp-build.sh on every build, so it always differs.
    static let buildTimestamp = BuildStamp.value

    /// Server capability/protocol version. v1 = encrypted-envelope auth over /pair +
    /// /rpc. Bump when the wire capabilities change so clients can auto-detect.
    static let protocolVersion = 1

    /// Capability tags a client can feature-detect against, from ONE device_info
    /// call (no separate /schema fetch needed). Keep in sync with what the server
    /// actually implements.
    static let capabilityTags: [String] = [
        "envelope_v1",         // /pair + encrypted /rpc envelopes (HMAC-SHA256)
        "stream_ticket",       // stream_ticket RPC → single-use ?ticket= for /stream + /logs
        "video_stream",        // GET /stream (H.264-in-MPEG-TS live screen)
        "remote_ui",           // GET /remote (browser control page)
        "page_source_filter",  // page_source{filter:{...}}
        "visible_only",        // page_source{visible_only:true} — viewport culling for long lists
        "max_depth",           // page_source{max_depth}
        "find_element_ref",    // find_element → ref; tap{ref}
        "scroll_to_element",   // scroll_to_element → ref
        "clear_text",          // clear_text + type{clear:true}
        "open_url",            // open_url deep links
        "resolve_app",         // resolve_app name → bundle_id
        "page",                // page{direction} precise paging
        "collect",             // collect{pages}: page + read N screens in one call
        "stop_server",         // config{stop_server:true}
        "logs_history",        // GET /logs/history (persisted logs)
        "screenshot_jpeg",     // screenshot{format:'jpeg'|'png', quality} — jpeg is the default
        "reset",               // reset RPC (recover from a dropped accessibility connection)
        "nonui_lane",          // config/reset/logs answer while UI calls are blocked
        "system_metrics",      // device_info.system — thermal/cpu/memory/disk/battery/screen_locked/foreground_app
        "screen_text",         // Vision OCR fallback when the AX tree has no on-screen rows
        "cli_binary",          // GET /skill/clients/cli — static aarch64-musl client
        "nearby_discovery",    // Bonjour over peer-to-peer Wi-Fi (AWDL) on port+1, when turned on
    ]

    static func generateSchemaDocument() -> [String: Any] {
        [
            "protocol": "JSON-RPC 2.0",
            "server_version": serverVersion,
            // Which BINARY this is. serverVersion is bumped by hand and so can be
            // identical across two different builds; this never is.
            "build": buildTimestamp,
            // Capability version — clients negotiate against this.
            "protocol_version": protocolVersion,
            // Feature-detection tags (same list device_info returns, so a client
            // can negotiate from either one).
            "capability_tags": capabilityTags,
            "endpoints": [
                "skill": "GET /skill — START HERE. The operating manual in Skill (Markdown) format; read it ONCE to learn the fast-path workflow and best practices, then treat iCTRL as a Skill.",
                "pair": "POST /pair  {client_name, plain:true | pub:<b64 raw 32B X25519>} → the 32-byte key K. IMPORTANT: this BLOCKS until the device user manually taps Allow/Deny on an on-screen prompt — use a long client timeout (at least 60s) and do NOT retry early; a retry queues another prompt. `plain:true` returns K in the clear and is accepted ONLY from 127.0.0.1 (USB/iproxy); over the LAN send `pub` and unwrap: K = token_ct XOR HMAC(HMAC(X25519(c_priv,d_pub), \"ictrl-pair\"||c_pub||d_pub), \"ictrl-wrap\"). Returns 403 if denied.",
                "rpc": "POST /rpc   an ENCRYPTED v1 envelope (no plaintext path, no Bearer header): {v:1, tok, ts, nonce:<32 hex>, ct:<b64>, tag:<64 hex>} wrapping the JSON-RPC body. See guidance.authorization for the construction.",
                "stream": "GET /stream[.ts]?ticket=<t>  live H.264 screen video (default 5 fps, ?fps=N in 0.5-30 to change). Screen capture is the limit, not encoding: where XCTest can capture straight to JPEG the full 30 is reachable on a cool device and somewhat less on a hot one; where it can't, capture caps the rate near 7. A byte pipe can't carry a per-request envelope, so it takes a SINGLE-USE ~60s ticket minted over the encrypted channel by the `stream_ticket` RPC. One shared encoder fans out to all clients; encoding stops when the last client disconnects.",
                "remote": "GET /remote  browser control page (shadcn-styled): plays the stream via MSE and drives the device with tap/swipe/scroll/keyboard + a side panel of buttons. Paste the 64-hex pairing key once; the page does the v1 crypto in-browser (WebCrypto) and keeps K in localStorage — it is never sent.",
                "whoami": "GET /whoami   unauthenticated {device_id, protocol_version, server_version}. device_id is stable per installation: store one key per device under it and use that key over every channel (USB, LAN, nearby). Every response also carries it as the X-ICTRL-Device header",
                "logs": "GET /logs?ticket=<t>   plain-text recent logs (current process, in-memory). Browser-issued GET, so it uses the same single-use ticket as /stream. Sensitive values are redacted",
                "logs_files": "GET /logs/files?ticket=<t>   list persisted daily log files (survive crashes/restarts)",
                "logs_history": "GET /logs/history?date=YYYY-MM-DD&ticket=<t>   dump a persisted day's log (redacted). Use this to recover logs from BEFORE a crash — /logs only holds the current process's memory",
                "client": "Download a client instead of hand-writing the crypto — both are served off the device, so they always match this build. GET /skill/clients/cli → a static aarch64-musl binary needing no interpreter (use this in Alpine/musl sandboxes such as Minis, where python3 is absent and installing it costs a network round-trip); fetch /skill/clients/cli.sh too and invoke it as `sh ictrl.sh call device_info`, since skill installers write files without an exec bit. GET /skill/clients/python → a stdlib-only reference client (X25519 LAN pairing additionally wants `pip install cryptography`): `curl -O http://<host>:8200/skill/clients/python`, then `python3 ictrl_rpc.py --host <host>:8200 pair`. Both share ~/.ictrl/token.json and are interchangeable.",
                "schema": "GET /schema  this document",
            ],
            "guidance": [
                "authorization":
                    "EVERY /rpc body is an encrypted envelope (protocol v1) — there is no plaintext/Bearer path; " +
                    "an unsealed POST gets 401 auth_required. All request-path crypto is HMAC-SHA256 only. " +
                    "STEP 1, pair once: POST /pair {client_name, plain:true} (127.0.0.1 only) or {client_name, pub} " +
                    "over the LAN, to obtain the 32-byte key K. This BLOCKS on an on-screen Allow/Deny prompt — " +
                    "use a timeout of AT LEAST 60s and do NOT retry early (each retry pops another prompt); 403 = denied. " +
                    "STEP 2, seal each call:  tok = first 4 bytes of SHA256(K) as 8 hex (a lookup id, NOT a secret); " +
                    "nonce = 16 random bytes per request; ts = unix seconds (server allows ±120s). " +
                    "K_enc_req = HMAC(K, \"ictrl-v1|enc-req\"||nonce); K_mac = HMAC(K, \"ictrl-v1|mac\"||nonce); " +
                    "keystream(Kx) = HMAC(Kx, nonce||be32(0)) || HMAC(Kx, nonce||be32(1)) || … truncated; " +
                    "ct = body XOR keystream(K_enc_req); tag = HMAC(K_mac, \"v1\"||tok_4B||be64(ts)||nonce||ct). " +
                    "POST {v:1, tok, ts, nonce:<hex>, ct:<base64>, tag:<hex>}. " +
                    "STEP 3, open the reply: it is sealed under the SAME nonce — verify " +
                    "tag == HMAC(K_mac, \"resp\"||nonce||ct), then decrypt with K_enc_resp = HMAC(K, \"ictrl-v1|enc-resp\"||nonce). " +
                    "Expiry is IDLE-BASED: a key dies only after 30 days of no use, and every call slides that forward, " +
                    "so a key in regular use never expires and survives app restarts. Cache K and re-pair ONLY on " +
                    "401 auth_failed. Nonces must never repeat (replay is rejected within the ±120s window). "
                    + "Keys are PER DEVICE: cache them keyed by host:port so you can drive several devices "
                    + "concurrently, and never send one device's key to another.",
                "client_timeouts":
                    "Set generous client timeouts for /rpc: at least 30s, ideally 60-120s. " +
                    "/schema and /logs are static and reply instantly, but /rpc drives the real device — a cold app " +
                    "launch or heavy page can make a single call take many seconds. " +
                    "CRITICAL: a client-side curl timeout does NOT mean the action failed — the device keeps executing " +
                    "and the call usually completes. Before retrying a timed-out /rpc, GET /logs and look for a " +
                    "'⏱ ✓ <method>' entry — if it's there, the action already succeeded and retrying would DOUBLE it " +
                    "(e.g. a tap fires twice). Only retry if /logs shows no success and no in-flight entry.",
                "connection_reliability":
                    "The service runs inside an XCUITest process on the phone and can occasionally drop (iOS backgrounding " +
                    "limits, or a stuck long-running call). Treat 8200 as possibly-transient: " +
                    "(1) Before a session, probe with a SHORT timeout: GET /schema (1-2s) — 200 means ready. " +
                    "(2) If the app was just woken via the ictrl:// URL scheme, note the returned 'opened' flag is UNRELIABLE " +
                    "(it only means the URL was handed to the system, NOT that the server is up) — always confirm by polling " +
                    "GET /schema for a few seconds. " +
                    "(3) If /rpc starts failing AND /logs is also unreachable, the service died — re-wake via ictrl:// and " +
                    "poll /schema until it returns 200. Your cached key still works — do NOT re-pair unless a call returns 401. " +
                    "(4) Space out ictrl:// re-wakes by a couple seconds; rapid repeats may be throttled. " +
                    "(5) CHEAP RECOVERY: don't restart the task from scratch. The resolved bundle_id is stable — REUSE it, do NOT call resolve_app again. The key is idle-expiry (30 days unused) and persists across restarts, so re-pair only if a call actually returns 401. If you know a deep link back to where you were (open_url), use it instead of re-navigating from the app's home screen.",
                "searching_and_typing": [
                    "Searching inside an app is the #1 place automation goes wrong. Follow this sequence:",
                    "DON'T WAIT A FIXED TIME between steps — not after launch_app either. Actions wait for the screen to settle before returning (settle.stable:true → read right away, no wait); if it is still changing or loading, read again (capped). Fixed sleeps after every step just add latency.",
                    "1. launch_app, then read the screen. If it shows a splash or placeholder, read again until it changes.",
                    "2. Find the search ENTRY by its visible label (whatever the app's language). It's often a Button/StaticText that opens a search PAGE, not a real input — is_text_input:false confirms it's an entry, not the field. find_element{element_id:'<label>'} → tap{ref}.",
                    "3. tap{ref} that entry (use the ref from step 2, not coordinates), then go straight to step 4 — if the search page isn't up yet, step 4 finds nothing; read again.",
                    "4. Locate the REAL input: find_element{element_type:\"textfield\"} (or searchField), confirm is_text_input:true, then tap{ref} to focus. (The keyboard comes up as part of that tap.)",
                    "5. type{text:\"…\", submit:true}. If type returns a 'no keyboard/focus' warning, re-focus the textfield (step 4) and retry — don't assume it went in.",
                    "6. Read results with page_source right away; if they're still loading, read again (poll) rather than sleeping.",
                    "Key trap: type() into an unfocused field silently loses the text and submit:true then searches an empty/garbage query. type() returns a 'warning' when it can't confirm a focused keyboard — heed it and re-focus if needed.",
                    "To REPLACE existing text, use type{clear:true, text:\"…\"} (empties first) or clear_text; tap the field to focus before clearing.",
                ],
                "front_app":
                    "There is no bound or target app. Reads (page_source, find_element, screen_text, screenshot) " +
                    "and actions always apply to what is on screen now. Apps jump (login, payment, store, an ad) and " +
                    "users switch, so after any surprise, read again before acting. A ref belongs to the app it was " +
                    "found in: if that app is no longer in front, tapping it is refused with a clear error. A SYSTEM " +
                    "ALERT/permission dialog covering the app blocks ref/element actions: read it via " +
                    "page_source{bundle_id:'com.apple.springboard'} and tap its button by coordinates. Pass an " +
                    "explicit bundle_id to read one specific app.",
                "opening_apps_and_urls": [
                    "Don't guess bundle IDs. To open an app by name:",
                    "1. resolve_app{text:'携程'} → resolves a name/keyword to a bundle_id via a built-in catalog, " +
                    "falling back to the iTunes Search API (source field says which). Returns candidates with bundle_id + name.",
                    "2. launch_app{bundle_id:<resolved>} → opens it.",
                    "list_apps returns the bundle IDs actually INSTALLED on this device — use it to confirm an app is present.",
                    "open_url{url:'scheme://…'} opens an app URL scheme / deep link (often faster than launch_app and can jump " +
                    "straight to a feature). Use it when you already know the app's scheme; use launch_app when you just want the app's home.",
                ],
                "scrolling_and_paging":
                    "Two ways to move a scroll view: swipe/scroll (a gesture — fast, has momentum, can overshoot) and " +
                    "page (a precise one-screen step, ~85% of the screen, NO momentum — best for reading long content " +
                    "predictably). page{direction:'down', pages:N} advances N screens. Prefer page when reading a feed/" +
                    "detail page screen-by-screen; use scroll_to_element when you're hunting a specific labeled element.",
                "stopping_the_service":
                    "config{stop_server:true} shuts the service down (it replies first, then stops listening ~1s later). " +
                    "Tokens persist, so after the runner is relaunched you can reconnect WITHOUT re-authorizing. Only do " +
                    "this when you intend to end automation — there is no remote start, the runner must be relaunched on-device.",
                "inspecting_ui":
                    "PREFER page_source (the accessibility/view hierarchy as text) to understand layout — " +
                    "it gives element types, labels, identifiers, and exact frames in POINTS, is far smaller " +
                    "than an image, and needs no pixel→point conversion. Use screenshot only as a SECOND choice: " +
                    "when an element is missing from the tree or you need visual detail. To go even lighter, " +
                    "request a smaller screenshot with scale (e.g. 1 or 0.5).",
                "locating_elements_decision_tree": [
                    "Pick the locate method by situation — each returns a stable 'ref' you then act on:",
                    "0. You already know the label of an on-screen control (search bar, a named button) → skip page_source, go STRAIGHT to find_element{element_id:<label>} → tap{ref}. Don't read the tree just to compute coordinates.",
                    "1. Element has a clear text/label AND is on screen → find_element{element_id:<label>} → tap{ref}. Fastest, precise.",
                    "2. Element is off-screen (need to scroll to it) → scroll_to_element{element_id:<label>} — it scrolls then returns the ref in one call. Don't hand-roll swipe loops.",
                    "3. App exposes accessibility identifiers (look for 'identifier:' in page_source, e.g. big apps use them for their own UI tests) → use that id as element_id — the most stable key.",
                    "4. The on-screen text ≠ accessibility label (common!), or label is truncated → read the EXACT label from page_source first, or use match:'contains'.",
                    "5. Pure icon / image / canvas with no useful label (games, webviews, custom-drawn UI) → screenshot, find it visually, tap by COORDINATE (pixel/scale). This is the fallback, not the default.",
                    "6. Multiple elements share a label → add element_type (button/cell/…) to disambiguate; the matcher returns the first HITTABLE one.",
                    "Prefer ref over coordinates whenever you have one: a ref re-resolves the live element and won't drift if the layout shifts; a coordinate is a fixed point that breaks after any scroll/animation.",
                ],
                "coordinate_space":
                    "tap, double_tap, long_press, swipe, drag and type(x,y) all use POINTS, not pixels. " +
                    "page_source frames are already in points. Screenshots are PIXELS: point = pixel / scale. " +
                    "Get scale and the valid point range from device_info (point_width/point_height).",
                "recommended_flow":
                    "1) call device_info once to learn point_width/point_height/scale. " +
                    "2) open the app you need: resolve_app{text:<name>} → launch_app{bundle_id} (or open_url for a deep link). " +
                    "3) call page_source to read the current layout (types, labels, ids, frames in points). " +
                    "4) locate the target: find_element (on screen) or scroll_to_element (needs scrolling) → get a ref. " +
                    "5) act by ref: tap/double_tap/long_press{ref}, or drag{from_ref,to_ref}; page{direction} to read long content. " +
                    "6) only fall back to screenshot + coordinate tap when the element has no usable label. " +
                    "7) re-check with page_source (or screenshot) to verify the result.",
                "common_pitfalls": [
                    "Reaching for screenshot first when page_source + find_element would locate the element more precisely and cheaply.",
                    "Using a coordinate when a ref is available — the coordinate breaks after any scroll/animation; a ref re-resolves the live element.",
                    "Passing raw pixel coordinates to tap → taps land off-target or out of bounds. Convert pixel/scale first.",
                    "Bottom tab bars/buttons live just above the home-indicator safe area; if a tap seems ignored, aim slightly higher (smaller y).",
                    "Searching by the ON-SCREEN text when the accessibility label differs (e.g. a button reads '添加至购物袋' but its label is '添加') — read the exact label from page_source, or use match:'contains'.",
                    "type requires an input field to already have keyboard focus — tap the field first (or pass x,y). To run a search, use type{submit:true} instead of hunting for the keyboard's Search key.",
                    "unlock only wakes the screen; a passcode-locked device must be unlocked by the user.",
                ],
            ],
            "methods": generateJSONSchema(),
        ]
    }

    static func generateHTMLDoc() -> String {
        var html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>iCTRL API</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 20px; }
        h1 { font-size: 28px; font-weight: 700; margin-bottom: 8px; }
        .subtitle { color: #86868b; margin-bottom: 24px; }
        .endpoint { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 12px; }
        .endpoint-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
        .method-name { font-size: 17px; font-weight: 600; font-family: SF Mono, monospace; color: #0071e3; }
        .desc { color: #6e6e73; font-size: 14px; margin-bottom: 8px; }
        .params { font-size: 13px; }
        .param { display: flex; gap: 8px; padding: 4px 0; border-top: 1px solid #f5f5f7; }
        .param-name { font-family: SF Mono, monospace; font-weight: 500; min-width: 100px; }
        .param-type { color: #86868b; min-width: 60px; }
        .param-req { color: #bf4040; font-size: 11px; }
        .section { margin-top: 24px; margin-bottom: 12px; font-size: 20px; font-weight: 600; }
        .info { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 12px; }
        code { background: #f5f5f7; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
        pre { background: #1d1d1f; color: #f5f5f7; padding: 12px; border-radius: 8px; font-size: 13px; overflow-x: auto; margin-top: 8px; }
        </style>
        </head><body>
        <h1>iCTRL API</h1>
        <p class="subtitle">JSON-RPC 2.0 &middot; iOS Automation Server</p>

        <div class="info">
        <p><strong>RPC Endpoint:</strong> <code>POST /rpc</code></p>
        <p style="margin-top:4px"><strong>Pairing:</strong> <code>POST /pair</code> — <code>{client_name, plain:true|pub}</code> → 32-byte key <code>K</code>. Every <code>/rpc</code> body is then an encrypted v1 envelope.</p>
        <p style="margin-top:8px">All <code>/rpc</code> calls are encrypted v1 envelopes — no headers, no plaintext. Pair once, then seal every body with the key.</p>
        <pre>{"jsonrpc": "2.0", "method": "tap", "params": {"x": 100, "y": 200}, "id": 1}</pre>
        </div>

        <div class="info" style="border-left:4px solid #ff9500">
        <p><strong>⏳ First, get a token — the user must approve it.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>POST /pair {client_name}</code> shows an <em>Allow / Deny</em> prompt on the device and BLOCKS until the user responds.
        Use a client timeout of <strong>at least 60 seconds</strong> and wait — do not retry early (each retry pops another prompt).
        On approval you receive a token (valid 30 days); on denial, HTTP 403.
        </p>
        </div>

        <div class="info" style="border-left:4px solid #5856d6">
        <p><strong>🔎 Version &amp; capabilities.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>device_info</code> (and <code>/schema</code>) report <code>server_version</code>, <code>protocol_version</code>
        and a <code>capabilities</code> array — feature-detect from ONE call and don't assume a method exists on an older
        <code>server_version</code>.
        </p>
        </div>

        <div class="info" style="border-left:4px solid #ff3b30">
        <p><strong>⚠️ Reliability &amp; timeouts — read before automating.</strong></p>
        <ul style="margin:6px 0 0 18px;color:#6e6e73;font-size:14px;line-height:1.6">
        <li><strong>Use long <code>/rpc</code> timeouts (≥30s, ideally 60–120s).</strong> <code>/schema</code> and <code>/logs</code> reply instantly, but <code>/rpc</code> drives the real device and a call can take seconds.</li>
        <li><strong>A client timeout ≠ failure.</strong> The device keeps executing. Before retrying, <code>GET /logs</code> and look for <code>⏱ ✓ &lt;method&gt;</code> — if present, it already succeeded and retrying would double the action.</li>
        <li><strong>Probe readiness with <code>GET /schema</code> (short timeout).</strong> If you woke the service via the <code>ictrl://</code> URL scheme, the <code>opened</code> flag is NOT proof the server is up — the runner cold-starts and needs a few seconds to bind :8200. Poll <code>/schema</code> until it returns 200.</li>
        <li><strong>If <code>/rpc</code> and <code>/logs</code> both go unreachable</strong>, the runner process died — re-wake via <code>ictrl://</code> and poll <code>/schema</code> until ready. Your cached key survives; only re-pair on a 401.</li>
        </ul>
        </div>

        <div class="info" style="border-left:4px solid #34c759">
        <p><strong>👁 Inspect the UI with <code>page_source</code> first.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>page_source</code> returns the view hierarchy as text (types, labels, identifiers, and frames
        already in <em>points</em>) — smaller, faster and more precise than an image. Use <code>screenshot</code>
        only when an element is missing from the tree or you need visual detail (and you can shrink it with <code>scale</code>).
        </p>
        <p style="margin-top:8px;color:#6e6e73;font-size:14px">
        Rich pages can be big and the first call after a launch can be slow. <strong>Scope it:</strong>
        <code>page_source({"filter":{"label":"&lt;substring&gt;"}})</code> returns only matching nodes + ancestors;
        <code>{"max_depth":3}</code> gives just the top structure; <code>{"max_elements":200}</code> caps the count.
        A 500-node hard cap applies by default (<code>truncated:true</code> when hit).
        </p>
        </div>

        <div class="info" style="border-left:4px solid #0071e3">
        <p><strong>⚠️ Coordinates use POINTS, not pixels.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        Screenshots come back in <em>pixels</em>; <code>tap</code>/<code>swipe</code>/<code>drag</code> take <em>points</em>.
        Convert: <code>point = pixel / scale</code>, taking <code>scale</code> from the
        <em>screenshot response</em> — not <code>device_info.screen_scale</code>, which is the
        panel ratio (3) while a screenshot is downscaled to 2 by default.
        The valid tap range (<code>point_width</code> × <code>point_height</code>) comes from either.
        </p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        Recommended flow: <code>device_info</code> → <code>resolve_app</code>/<code>launch_app</code> → <code>page_source</code> → tap frame center → verify.
        Fetch <code>GET /schema</code> for full machine-readable guidance (app binding, searching/typing, reliability…).
        </p>
        </div>

        <div class="info">
        <p><strong>Diagnostics &amp; logs (single-use <code>?ticket=</code> required, redacted):</strong></p>
        <ul style="margin:6px 0 0 18px;color:#6e6e73;font-size:14px;line-height:1.6">
        <li><code>GET /logs</code> — recent in-memory logs for the current process (includes <code>⏱ ✓ &lt;method&gt; &lt;ms&gt;</code> timings).</li>
        <li><code>GET /logs/files</code> — list persisted daily log files (survive crashes/restarts).</li>
        <li><code>GET /logs/history?date=YYYY-MM-DD</code> — read a persisted day's log. Use this to recover logs from BEFORE a crash.</li>
        <li><code>GET /schema</code> — this document, as JSON.</li>
        </ul>
        <p style="margin-top:8px;color:#6e6e73;font-size:14px">Stop the service remotely with <code>config {"stop_server": true}</code> — tokens persist, so relaunching the runner needs no re-auth.</p>
        </div>

        <p class="section">Methods (\(methods.count))</p>
        """

        for m in methods {
            html += """
            <div class="endpoint">
            <div class="endpoint-header"><span class="method-name">\(m.name)</span></div>
            <p class="desc">\(m.description)</p>
            """
            if !m.params.isEmpty {
                html += "<div class=\"params\">"
                for p in m.params {
                    let req = p.required ? "<span class=\"param-req\">required</span>" : ""
                    html += """
                    <div class="param">
                    <span class="param-name">\(p.name)</span>
                    <span class="param-type">\(p.type)</span>
                    <span>\(p.description) \(req)</span>
                    </div>
                    """
                }
                html += "</div>"
            }
            html += "</div>"
        }

        html += "</body></html>"
        return html
    }
}
