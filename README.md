# Keymapp Layers

An [Omarchy](https://omarchy.org/) bar-widget plugin for [ZSA](https://zsa.io/)
keyboards (Moonlander, ErgoDox EZ, Planck EZ, Voyager). Shows whether
[Keymapp](https://www.zsa.io/keymapp) is running, the connected keyboard's
active layer (with its real name, not just a number), and lets you switch
layers directly from the bar — all without opening Keymapp itself.

## How it works

<img width="404" height="319" alt="image" src="https://github.com/user-attachments/assets/04cab1b5-669c-4df5-93eb-7eef18b29650" />

There's no long-lived Quickshell service for Keymapp, so this plugin talks to
it directly through [`kontroll`](https://github.com/zsa/kontroll), a small CLI
that speaks Keymapp's local API over its Unix socket. Status is polled on a
timer that keeps running whether or not the panel is open.

The live API only reports the *active* layer as a bare index — it doesn't
expose layer names or count. Keymapp's own UI gets that from a local cache
instead: a compiled copy of your keymap kept in
`~/.config/.keymapp/keymapp.sqlite3`. This plugin reads that same file (via
the `sqlite3` CLI) to recover real layer names, and falls back to plain
numbers if the file or CLI isn't available.

The panel also shows a link to open your keyboard's current layout directly
in [ZSA's Configure](https://configure.zsa.io/) tool, built from the
connected keyboard's model and firmware version.

## Keeping Keymapp out of the way

`kontroll` (and so this widget) only works while the Keymapp app is actually
running — its gRPC socket and local cache go away the moment you quit it.
Hyprland has no real window minimization, but its *special workspaces* work
well as a stand-in: launch Keymapp on login, assign its window to a hidden
special workspace so it never shows up on a real one, and bind a key to pop
it into view only when you actually need its UI (e.g. to edit a layout or
check for firmware updates).

Add something like this to your Hyprland config:

```
# Launch Keymapp on login, headless
exec-once = uwsm-app -- keymapp

# Keep its window off your regular workspaces
windowrulev2 = workspace special:keymapp silent, class:^(keymapp)$

# SUPER+CTRL+ALT+K toggles the Keymapp window visible/hidden
bind = SUPER CTRL ALT, K, togglespecialworkspace, keymapp
```

If you're on Omarchy's Lua config format instead of raw `hyprland.conf`:

```lua
-- autostart.lua
o.launch_on_start("keymapp")

-- hyprland.lua (window rules)
o.window("keymapp", { workspace = "special:keymapp silent" })

-- bindings.lua
o.bind("SUPER + CTRL + ALT + K", "Toggle Keymapp", hl.dsp.workspace.toggle_special("keymapp"))
```

With this in place, Keymapp is always running in the background — this
widget stays live and `configure.zsa.io` links keep working — without ever
cluttering your workspaces. Note that a freshly launched, still-hidden
Keymapp instance hasn't connected to your keyboard yet on its own; that's
why the widget's status poll opportunistically runs `kontroll connect-any`
whenever it sees no keyboard connected.

## Requirements

- [Keymapp](https://www.zsa.io/keymapp) v1.3.2 or newer, installed and running
- Keymapp's local API enabled: **Keymapp → Settings → Enable API**. This is
  off by default — `kontroll` (and so this widget) can't connect at all
  until you turn it on once. If the widget shows "Keymapp not running" even
  though Keymapp is open, this is the first thing to check.
- [`kontroll`](https://github.com/zsa/kontroll) — install from the AUR:
  ```
  omarchy pkg aur add zsa-kontroll-bin
  ```
- `sqlite3` (optional, for real layer names/counts):
  ```
  omarchy pkg add sqlite
  ```

No special privileges are required — the plugin only shells out to
`kontroll` and does a read-only query against Keymapp's own local cache
file.

## Installation

```
omarchy plugin add https://github.com/ethanthompson/omarchy-plugin-keymapp --enable
```

## Usage

Click the keyboard icon in the bar to open the panel. It shows:

- Whether Keymapp is running and whether a keyboard is connected
- The active layer, with a row of buttons to switch layers, and a ⟳ button
  next to the layer list to force an immediate re-read of Keymapp's cache
  (useful right after flashing new firmware, so you don't wait for the
  periodic background refresh)
- The connected keyboard's firmware version, with a link to open that exact
  layout in ZSA's Configure tool

Keyboard navigation: arrow keys move the layer cursor, Enter/Space activates
the highlighted layer, Escape closes the panel.

## Configuration

Available in the plugin's settings (via the Omarchy bar/plugin settings UI):

| Setting | Default | Description |
|---|---|---|
| Refresh interval (seconds) | `5` | How often to poll Keymapp for status |
| Fallback layer count | `6` | Used only if layer names can't be read from Keymapp's local cache |
| Manual layer names | _(empty)_ | Comma-separated names (e.g. `Base, Nav, Sym, Num`) that override auto-detected names entirely |

## Removal

```
omarchy plugin remove ethan.keymapp
```
