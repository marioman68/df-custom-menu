# Changelog

## 1.0 – First release

**The menu**
- Replaces the list that opens from the DFHack logo with one you can edit. It starts with the same commands DFHack shows, so nothing changes until you edit it.
- Add any DFHack command – from a searchable list of every command, or by typing a command line with options.
- Remove commands, move them into your own order, and give them your own names (e.g. *Fast dwarves* for `fastdwarf 1 0`).
- Group commands under headings or divider lines.
- Commands that have a hotkey show it; commands that can be switched on and off are green while they're on.

**Hotkeys**
- Assign a hotkey to any command by pressing the shortcut you want – with a warning if it's already used. Saved in `dfhack.init` so it works everywhere.
- Remove hotkeys you assigned with one key.

**Toolbar**
- Put favourite commands on a strip of buttons under the top information bar. It grows and shrinks to fit, wraps onto more rows when needed, and hides when empty.
- Buttons are green while their command is switched on.
- A small arrow button next to the DFHack logo shows or hides the toolbar.
- Toolbars for fort mode, adventure mode, legends and the embark screen, each movable with `gui/overlay`.

**Launcher**
- **Add to DFHack menu** (Ctrl-K) in the DFHack launcher adds the command you typed or just ran, with a popup to name it and put it on the toolbar.

**Options**
- Hide commands that don't work on the current screen (e.g. fort-only tools in adventure mode).
- Ask before running cheat (armok) commands.

**Other**
- Keeps itself out of the game's mod list – subscribing is enough.
- Unsubscribe and the normal DFHack menu comes straight back – no DFHack settings are changed.
