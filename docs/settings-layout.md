# Impostazioni — layout per dispositivo (v1.2, 13 nov 2026)

Same content and wording on Apple and Android; only the layout changes with the device, the way Netflix does it.
Nothing stays as a narrow column in the middle of a wide screen, and no choice opens as a floating centred panel.

## Content (unchanged, regrouped into categories)

| Category (id) | Icon (SF / Material) | Rows (existing ones, same texts) |
|---|---|---|
| Profilo (`profile`) | person.crop.circle / AccountCircle | header with avatar, name, maturity, PIN; Cambia profilo; Gestisci profili; Le tue squadre; Copia o invia i profili |
| Riproduzione (`playback`) | play.rectangle / PlayCircle | Film e serie rows: autoplay, credits prompt, still watching hours/episodes, audio language, Download (phone/tablet), Azzera "Continua a guardare" |
| Canali in diretta (`live`) | tv / LiveTv | Qualità video, HEVC, Sottotitoli, Player compatibile (Apple) |
| In casa (`home`) | house / Home | telecomando / remote rows of the platform |
| Linea e dati (`line`) | antenna.radiowaves.left.and.right / Router | line + expiry + VPN; change line from phone (TV); sync row; refresh channels/EPG; update on-demand sources; Esci dalla linea (destructive, confirm) |
| Assistenza (`help`) | questionmark.circle / HelpOutline | send log (where it exists), version line |

## TV (Apple TV, Android TV / Fire TV): two panes, full screen

- Left pane (~30% width, starts right of the side menu): page title "Impostazioni", then the categories as a vertical list
  (icon + name). Moving onto a category shows it on the right at once (no click needed); select or RIGHT enters the right pane.
- Right pane (rest of the width, left-aligned, scrolls): the rows of the category. Rows are full-width lines with the
  value on the right edge (no cards floating in the middle).
- A row with choices (quality, audio language, hours, episodes, subtitles…) does NOT open a panel: the right pane shows the
  choice list in place (title of the setting on top, options with a tick on the current one). Picking one or BACK
  returns to the rows with the focus on that row.
- BACK: choice list → rows → categories → side menu (the app's usual back chain). Confirmations (Esci dalla linea) stay
  dialogs.

## Phone (iPhone, Android phone): full-width grouped list, pushed pages

- Edge-to-edge list on the page background (no rounded cards, no max width): section header in small caps, rows separated
  by a hairline inset after the icon, chevron or value or switch on the right. Profile header at the top as now.
- A row with choices opens a pushed page (own top bar with back + the setting name) with the options as a radio list and a
  one-line explanation under the title; picking one goes back. No bottom sheet for settings choices.

## Tablet (iPad, Android tablet): master–detail

- Categories on the left (fixed ~320 pt/dp column, same list as the TV), the selected category on the right filling the rest.
- Choices open in the right column in place, with a back arrow (like the TV).
- Portrait iPad / narrow tablet (< 700 pt/dp wide): behave like the phone.
