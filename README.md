# Keymapp Layers

An [Omarchy](https://omarchy.org/) bar-widget plugin for [ZSA](https://zsa.io/)
keyboards (Moonlander, ErgoDox EZ, Planck EZ, Voyager). Shows whether
[Keymapp](https://www.zsa.io/keymapp) is running, the connected keyboard's
active layer (with its real name, not just a number), and lets you switch
layers directly from the bar — all without opening Keymapp itself.

## How it works

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

## Requirements

- [Keymapp](https://www.zsa.io/keymapp) installed and running
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
- The active layer, with a row of buttons to switch layers
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
