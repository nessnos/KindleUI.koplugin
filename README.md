# KindleUI for KOReader

A KindleOS-style interface for KOReader: a home screen with modules, a bottom navigation bar,
a Kindle-like quick-settings panel as the top menu, and Kindle-style settings pages.

| Part | What it is |
| --- | --- |
| Home screen, navigation bar, library, settings window | Based on **SimpleUI** by Doctor Hetfield (MIT, see LICENSE). |
| Quick-settings panel | KindleUI's own, written from scratch. Inspired by the idea of Neo QuickSettings. |
| Vertical scrolling library | Lina's vertical_library_scroll, built in. |
| Top chevron | The flat chevron from Lina's Kindle toolbar. |

## Install

1. Copy the `KindleUI.koplugin` folder into `koreader/plugins/`.
2. Delete (or keep disabled) `simpleui.koplugin` and `vertical_library_scroll.koplugin`.
   If they are still there, KindleUI switches them off itself and asks for a restart.
3. Restart KOReader.

No icon files need to be copied; everything is inside the plugin folder.
Your SimpleUI home screen, bars and modules carry over (same `simpleui_*` settings).

## Quick settings (the top menu)

Tapping or swiping down at the top of the screen (Home, Library, reader) opens the quick-settings panel, laid out like KindleOS:

- the device name, the time and date (e.g. "18:07 • Sept 30, 2026"), and the battery at the top;
- round buttons with a label under each (filled when on), in equal columns; a shorter last row is centred, like on a Kindle;
- the Wi-Fi button's label shows its state: the network's name when connected, "On" when on but not connected, "Off" (it can't be renamed);
- Brightness and Warmth sliders, with the value above the knob and − / + on each side;
- the up chevron at the bottom closes it (so does a tap below the panel or a swipe up);
- the screen behind is dimmed.

Long-press a button to open its settings. The **KOReader** button opens KOReader's full top menu with every
setting. You can rename it and change its icon, but it's always shown and its action can't change.

Settings: KindleUI Settings → **Quick Settings** (also under Bars → Quick Settings (top menu)). Everything saves as soon as you change it.

- **Top menu shows quick settings only.** Switch it off to get KOReader's normal menu back.
- **Device name.** Read from the Kindle when possible; otherwise type your own ("Lina's Kindle").
- **Buttons**
  - Add a custom button.
  - Arrange buttons.
  - Buttons per row (3–8).
  - One page per button: *Show in quick settings*, *Name*, *Icon* and, for custom buttons, *Action* (any KindleUI or KOReader action) and *Delete*.
  - Built-in buttons: KOReader, Wi-Fi, Light, Dark mode, Rotate, Sleep, Screenshot, Search, Home, Library, Settings, Restart, Exit.
- **Slider options.** Brightness slider, warmth slider (on devices with warm light), − / + buttons.
- **Dim the screen behind the panel.**

Choosing an icon opens a grid of the symbols in KOReader's icon font (common ones first, starting with a KindleOS-style half-filled circle for dark mode; searchable) and of
the plugin's and KOReader's images.

Gesture actions: "KindleUI: Quick settings" and "KindleUI: KOReader menu".

## Kindle-style settings

Module settings (long-press a module) and bar settings (long-press a bar) open as the same full-screen Kindle-style page.
KindleUI's settings window looks like the Kindle's settings: full screen, a back chevron and bold title,
plain rows with grey descriptions, switches for on/off options and chevrons for sub-pages.

## Home screen modules

Add modules from KindleUI Settings → Home Screen → Edit Layout → Add Module. Long-press a module on the
Home screen to change its settings.

### Progress bars and collection titles

- Progress bars in the Home screen modules are thinner, with the read part in black.
- Featured Collection, Author / Series Collection and To Be Read show the number of books ("12 books") under their title, in smaller regular text.

### Currently Reading

On top of SimpleUI's options:
- **Show cover.** Switch it off to show only the book's details, without the cover.
- **Page progress** (under Items): "Page 3 of 10", alone on its line or in the compact stats row.

### Author / Series Collection

Looks and works like a Featured Collection (covers in a row or grid, same Size and Appearance settings). Instead of one
collection you choose, it shows one author or series from your library, and a different one each time you come back
to the Home screen. The section title is the author's or series' name.

Its settings:
- Authors and/or Series.
- Only those with at least N books (2 by default).
- Shuffle: every visit, hourly or daily.
- Shuffle now.

### Two Columns

Puts two modules side by side. Its settings:

- Left side / Right side: pick any of your modules, or make a new Featured Collection, Author / Series Collection or quick-actions row just for that column.
- Left / Right module settings: the chosen module's own settings.
- Left column width (30–70%).
- Show the modules' titles.

The two sides have a clear gap between them, and each side's title lines up with its first cover.
Rows of covers (Featured Collection, Author / Series Collection, Recent…) always show one row of two books in a column;
their size setting is fixed there.

The Clock can't go in a column; use its Column Width setting instead.

## Navigation bar

The bar is slimmer and its labels larger than SimpleUI's: KindleUI's 100% bar size is SimpleUI's 70%, and its 100% label size is SimpleUI's 170%.
Sizes you had set before are converted once, so your bar keeps its look.
The Continue tab isn't offered on the bar.
Change them under KindleUI Settings → Bars → Navigation Bar.

### Groups (menus that open upwards)

A tab can hold several actions, like KindleOS. For example, a bar of `Home  [Current Book]  Library ^`, where
**Library** opens a menu with Library, Authors, Series and Collections.

1. KindleUI Settings → Quick Actions → Custom Quick Actions → **Create Quick Action**.
2. Choose **Group of Quick Actions** and tick the actions you want, in order. Then give it a name (e.g. "Library") and, if you like, an icon.
3. KindleUI Settings → Bars → Navigation Bar → **Tabs**: put the group on the bar.

On the bar the group's name has a small up chevron next to it (not in icons-only mode). Tapping the tab opens a Kindle-style
menu just above it (the same dropdown as the Kindle-style toolbar's ⋮ menu). Tapping an entry goes there, and the group's tab stays highlighted while you're in any of its places.

### Current Book tab

Add **Current Book** as a navigation bar tab (KindleUI Settings → Bars → Navigation Bar). It shows the cover of
the book you're reading, rising above the bar like on KindleOS. Tapping it opens the book.
The library's author and series views don't show the "Page x of y" line at the bottom, so it can't end up behind the cover.

## Battery

The status bar and the quick-settings panel show a horizontal battery like KindleOS.
Status Bar → "Kindle-style battery" switches back to the classic icon.

## Vertical scrolling library

KindleUI Settings → Library → **Vertical scrolling library**.

- Swipe up or down to turn pages.
- A KindleOS-style scrollbar sits on the right edge: a small solid triangle at each end (grey when you can't go further), a thin grey track and a thick black bar for where you are.
- A swipe down that starts in the top bar still opens quick settings.

## Chevron

The top bar's swipe indicator on Home and in the Library is the flat Kindle-style chevron (`infra/kui_chevron.lua`).

## Files added on top of SimpleUI

- `features/quickpanel/`: the quick-settings panel:
  - `qp_panel`: the panel;
  - `qp_slider`: the sliders;
  - `qp_actions`: the buttons;
  - `qp_store`: saved settings;
  - `qp_settings`: the settings pages;
  - `qp_iconpicker` and `qp_glyphs`: choosing an icon;
  - `qp_icons`: drawing icons;
  - `qp_device`: the device name.
- `features/kui_topmenu.lua`: makes the panel the top menu.
- `features/kui_vertical_scroll.lua`: vertical library scrolling.
- `infra/kui_chevron.lua`: the chevron.
- `infra/kui_battery.lua`: the horizontal battery.
- `engines/kui_kobo_tiles.lua`, `modules/module_kobo_coll.lua`, `modules/module_kobo_meta.lua`: Kobo shelves (no longer offered when adding modules; shelves already on a page keep working).
- `modules/module_two_col.lua`: Two Columns.
- The Current Book tab: `current_book` in `features/sui_quickactions.lua` and `screens/sui_bottombar.lua`.

SimpleUI's self-updater is switched off (it would install SimpleUI over KindleUI).

Credits: SimpleUI by Doctor Hetfield (MIT, see LICENSE). The quick-settings panel was inspired by Neo QuickSettings; its code is KindleUI's own.
