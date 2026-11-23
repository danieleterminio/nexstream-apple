# NexStream on TV — one experience on Android TV / Fire TV and Apple TV (v1.4, 24 Nov 2026)

Goal: "a Netflix, but better for us". Both TV apps must look and behave the same. Every key must do something
sensible on every screen, the focus must always be visible, BACK must never drop the user out of the app by surprise.

Units: Apple TV sizes are in points on a 1920×1080 canvas; Android TV sizes are in dp on a 960×540 canvas.
**1 Android dp = 2 Apple pt.** Below, sizes are written "Android dp / Apple pt".

## 1. Side rail (both TVs) — the 0.9 style, bigger

The user preferred the 0.9 Android rail (git `887b208:app/src/main/java/app/nexstream/one/ui/Nav.kt`, `NavRail`) to the
1.0 icon-only Netflix rail, but finds both too small. New rail:

- **Collapsed** (focus in the page): 84 dp / 168 pt wide, black. Top: the brand symbol (32 dp / 64 pt). Then the profile
  avatar (40 / 80) and the section icons (28 / 56 glyph) centred in 56 / 112 tall slots. The section in view has a red
  bar (4 × 26 dp / 8 × 52 pt) on the left edge and a white icon; the others are grey (#B8B8B8). At the bottom: the clock
  (HH:mm, label style 13 sp / 26 pt, grey).
- **Expanded** (focus in the rail): 300 dp / 600 pt wide, black fading to transparent over 48 / 96 on the right, drawn
  OVER the page (the page does not move). Top row: brand symbol + "NexStream" (title style) + clock on the right.
  Profile item: avatar 44 / 88, name (button style, 17 sp / 34 pt bold) and "Cambia profilo" (caption) under it,
  select = profile picker. A hairline. Then the sections, each a pill 52 / 104 tall, corner 12 / 24, icon 26 / 52,
  label 18 sp / 36 pt (bold when selected).
  Focused item = white pill, black icon and text, scale 1.0 (no zoom). Selected but not focused = white text + small
  red dot at the right end of the pill. Others = grey text.
- Sections, top to bottom (both TVs): Cerca, Home, Diretta, Guida TV, Film, Serie TV, I miei, Impostazioni.
- Opening/closing animates width in 180 ms ease-out. Entering the rail (LEFT from the left edge of a page, or BACK on a
  section root) puts the focus on the section in view, never on the first item.
- RIGHT (or select) from the rail goes into the page of the focused/selected section and collapses the rail. RIGHT from
  any rail item must land in the page even when the page top is not focusable (billboard): the page is one focus group.

## 2. Keys and BACK chain (everywhere outside the player)

| Where | BACK | Notes |
|---|---|---|
| A pushed page (title, programme, genre, teams, remote, transfer, manage profiles, downloads…) | the page before, focus restored on the card/row that opened it | |
| A section root, focus in the page | focus to the rail, on the section in view | |
| Rail | dialog "Vuoi uscire da NexStream?" with "Resta" (focused, primary) and "Esci" | second BACK = Resta |
| Settings | choice → rows (focus on that row) → categories → rail | see docs/settings-layout.md |
| Gates (VPN, login, Chi guarda?, onboarding) | the exit dialog (login: phone-QR panel → form first) | |
| Any dialog / panel | closes it, focus back where it was | |

- Long press select on a card = its menu (Apple: system context menu; Android: our menu). Play/pause key on a card of
  something playable = play it directly.
- Focus feedback: every focusable thing has a clearly visible focused state. Cards: scale 1.06 + 3 dp / 6 pt white
  border + slight shadow. Buttons and rows: white fill, black content. Nothing focusable without a visible state; no
  focus ever lands on something invisible or off screen (scroll to keep it visible, rows keep a 1-card lead).
- Browsing pages (v1.4): the row under the remote comes up whole under the billboard (rows above leave entirely, never
  half a row); the focused card comes to the row's left edge (page margin), one card per press. Guide cells: the white
  frame is inside the cell, no zoom (never over the neighbours); cells under 3 min are slivers the focus skips; narrow
  cells keep the first letters of the title.
- Sounds: Apple TV keeps the system focus sounds. Android TV plays the system navigation sounds
  (`AudioManager.playSoundEffect(FX_FOCUS_NAVIGATION_UP/DOWN/LEFT/RIGHT)` on D-pad moves that move the focus,
  `FX_KEY_CLICK` on select), which respect the system "sounds" setting.
- Key repeat: holding a direction scrolls smoothly and fast, never queues hundreds of moves after release.

## 3. On-demand player (films and episodes)

Reference implementation: Apple `App/Shared/UI/TvPlayerChrome.swift` + `VodPlayerView.swift` (branch tv-polish).

- Controls hidden while playing; any key shows them (and does its action). They hide after 5 s without input while
  playing; they stay while paused.
- Layout: top-left title (display 26 / 52 bold) and, for episodes, "S4:E5 Titolo episodio" under it; bottom: play/pause
  glyph, elapsed time, thin bar (4 / 8, red progress, red knob 14 / 28 when focused), remaining time "-9:32".
  Under the bar the option row: "Episodi" (series), "Audio e sottotitoli", "Velocità", "Fonte" (when there is another
  source), "Prossimo episodio" (when there is one). Buttons: icon + text, grey translucent, focused = white/black.
- Keys while the bar is focused (or controls hidden):
  - select / play-pause: toggle pause, show controls;
  - LEFT/RIGHT: seek −/+10 s; repeated or held presses accelerate (10, 10, 20, 30, 60, 120 s per step); the bar shows the
    target time and a preview position; applied 700 ms after the last press;
  - Apple touch surface swipe left/right: scrub proportionally (a full swipe ≈ 10% of the length, min 2 min), applied
    on release + 500 ms;
  - DOWN: focus the option row; UP from the option row: back to the bar;
  - BACK: option row → bar; bar visible → hide controls; controls hidden → close the player (back to the page that
    opened it, focus restored there). Never leaves the app.
- Panels (full-screen overlays inside the player, black 88%):
  - **Audio e sottotitoli**: two columns "Audio" | "Sottotitoli", plain text items with a tick on the current one, focus
    starts on the current audio; LEFT/RIGHT between columns; select applies immediately; BACK closes. The audio track
    picked becomes the profile's audio language.
  - **Episodi**: seasons on the left (current one ticked), episodes on the right as rows (still 16:9, "5. Titolo",
    duration, 2–3 lines of plot, "IN RIPRODUZIONE" on the current one); focus starts on the current episode; the list
    scrolls under a fixed header without overlapping it; select plays.
  - **Velocità**: compact list in the same style.
  - **Cambia fonte** (v1.4, option "Cambia fonte"): every source of the title at once (site, server, the site's own
    tag), the one playing ticked "IN RIPRODUZIONE"; each line gets its real quality (720p / 1080p / 4K, HEVC) as it is
    checked in the background, dead ones are greyed "Non disponibile" and cannot be chosen. Focus starts on the source
    playing and follows it while lines arrive until the user moves; the panel never closes by itself (the bar and the
    option row behind it cannot take the focus while a panel is open); select plays from the same position; BACK closes.
- **Prossimo episodio** (v1.4, all platforms): when the credits buttons appear, "Prossimo episodio" (focused) fills up
  over 5 s and plays the next episode; any other key / touch stops the countdown; "Guarda i titoli di coda" dismisses
  the buttons. The end-of-episode screen also counts 5 s. Both respect the autoplay setting.
- States: loading (backdrop + logo animation + status + "Annulla" focused), error ("Riprova" focused, "Chiudi"),
  end of episode (next episode card with countdown, "Guarda ora" focused, BACK = close), "Stai ancora guardando?"
  ("Continua" focused), credits prompt ("Prossimo episodio" focused, "Titoli di coda").

## 4. Live player (channels) — same style

- Controls hidden while watching; any key shows the info bar for 5 s.
- Info bar (bottom): channel logo + number + name, "IN DIRETTA" badge, programme title (bold) and time range
  "21:30 – 23:00", a progress line of the programme, the next programme ("Dopo: 23:00 Titolo"). Top-left: clock.
- Option row under the info bar: "Canali", "Guida", "Audio e sottotitoli", "Info programma", "Preferito" (toggle),
  "Versione" (when the channel has alternative streams, e.g. HD/FHD/backup).
- Keys with controls hidden:
  - UP / DOWN (and CH+/CH− on Android): previous / next channel in the current list order, instantly; a compact zap
    banner shows number, logo, name and the programme for 3 s; fast repeated presses move a cursor in the banner and
    tune only 600 ms after the last press;
  - Apple TV, Siri Remote (user decision 23 Nov 2026): only a **physical click** on the top / bottom edge of the
    clickpad zaps (UP = +1, as Android), also while the info bar is up. A **swipe** up/down or a finger resting on the
    surface only shows the info bar (a swipe down with the bar up goes into its options); a swipe never zaps.
    Swipe or click LEFT / RIGHT open Canali / Guida. Implementation: `TvRemoteCatcher` (press recognisers on the arrow
    press types + a touch recogniser, on the window) in `TvPlayerChrome.swift`; `TvLiveLayer.move` treats an up/down
    move command without a click just before it as a swipe. UI tests: `XCUIRemote.press(.up/.down)` is a press (= a
    click); swipes cannot be sent by XCUIRemote, `-nxPlayerPanel swipe` simulates the move command of one;
  - LEFT: open "Canali" (channel list panel); RIGHT: open "Guida" (the next programmes of this channel);
  - select: show the info bar (focus on the option row); play/pause: show the info bar;
  - digits (Android remotes): type a channel number, tuned 1.5 s after the last digit (already exists);
  - BACK: hide what is shown; with nothing shown → close the player (back where it was opened).
- **Canali** panel (left side, ~40% width, over the video which keeps playing): category chips on top (Preferiti,
  Tutti, then the groups), the channels as rows (number, logo, name, current programme, progress); focus starts on
  the channel playing; select tunes and closes; BACK closes.
- **Guida** panel (bottom sheet ~45% height): the current and next programmes of this channel as cards
  (time, title, short plot); select on a future programme = reminder toggle; on the current one = info.
- **Info programma**: title, time, plot, genre/year, image if known.
- Errors: "Il canale non risponde" with "Riprova" (focused) / "Altra versione" / "Canale successivo"; automatic retry
  already exists — keep the never-stall reconnect logic untouched.

## 5. Verification checklist (every item must be checked on the emulator/simulator)

1. Every section reachable from the rail; RIGHT from every rail item lands in the page; LEFT from the page's left edge
   opens the rail on the current section.
2. BACK chain of section 2 on every page listed, including focus restoration.
3. No screen where the focus is lost (pressing keys does nothing visible) — for every page and panel.
4. Player: every key in sections 3–4 in every state; panels open, move, apply, close; BACK never exits the app.
5. Text never cut or overlapping at 1080p; nothing under the TV safe area (5% margin).
6. No crash, no ANR, no error in the log during the whole run.

## 6. v1.4 additions (24 Nov 2026)

- **Opening** (every cold start, all devices, not skippable): variant A "Titoli di testa" — the quote "If buying isn't
  owning, piracy isn't stealing." word by word with a blur-in, fades at 3.0 s, then the breathing symbol with a red glow
  (~5 s). The system splash is plain black. Nothing under it takes keys. Anything that wants the screen at start waits
  for it: the Apple update notice and the Android update page come right after the opening, never under it.
- **App updates**: Android = mandatory update page (download, SHA-256 + same signing certificate check, system
  installer), the app is blocked until updated. Apple = one dismissable notice per version ("Nuova versione
  disponibile") plus a line in Impostazioni → Informazioni. Service and channels: NexStreamSync/UPDATES.md.
- **Guide focus through a refresh**: when the guide is read again (EPG refresh) while a cell has the focus, the focus
  stays on the same channel at the same time (Apple `GuideFocus`; Android keys the cells by channel + start). It must
  never fall back to the side menu. Apple UI test `ParityTests/testGuideFocusSurvivesRefresh` (`-nxEpgRefresh`
  rewrites the demo guide every 10 s).
- **Playback stalls (Apple)**: bigger forward buffer, ExoPlayer-style resume after a stall, the live proxy reconnects
  to the line silently; stall telemetry in the log (`NxStall`).
