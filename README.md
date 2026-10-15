# omarchy-overview

An Exposé / Mission Control style window overview for [Omarchy](https://omarchy.org).
One key shows every open window as a live thumbnail, grouped by workspace, including
windows on workspaces you can't currently see. Pick a window with the mouse or the
keyboard and you land on it, workspace switch included.

It ships as an Omarchy shell plugin (`git-spren.overview`, kind `overlay`) for Quickshell.

<img width="1280" height="720" alt="omarchy-overview demo: open the overview, type to search, pick a window" src="https://github.com/user-attachments/assets/d4ea55fe-a238-4f8b-9ddf-681c87ea9303" />

Full-quality video (1080p):

https://github.com/user-attachments/assets/d0ddd1e4-f7d6-4459-a16d-9c51501c7996

## Features

<img width="1920" height="1080" alt="The overview in the default grid layout" src="https://github.com/user-attachments/assets/f41f3411-3738-4f30-8fbd-bcde81ebf3e3" />

- **Live thumbnails** of every window on every workspace, via Hyprland's toplevel
  export. Windows on screen refresh 4 times a second (adjustable), windows on hidden
  workspaces are captured once when the overview opens, and nothing is captured while
  it is closed, so it costs nothing at idle.
- **Three layouts.** The default `grid` draws one box per workspace that mirrors your
  monitor, with each window at its real position and size. `columns` gives one column
  per workspace, and `rows` one row per workspace.
- **Type to search.** Printable keys start a fuzzy search over window titles, app ids
  and classes. Windows that don't match are dimmed and skipped by navigation, and the
  best match is selected, so a few letters and Enter are often all you need.
- **Keyboard navigation.** Arrow keys move spatially in the grid (and along
  columns/rows in the other layouts), Tab walks every window in order, digits jump to a
  workspace, Enter or Space focuses the selected window.
- **Animations.** By default the overview zooms out from the live desktop and zooms
  back into the workspace you pick when it closes.
- **Themed.** Colours come from the current Omarchy theme's menu tokens.
- **Hide or redact windows.** Windows with the Hyprland tag `overview-hide` are left
  out; `overview-redact` keeps the window but shows a black box and the app name
  instead of its content and title, e.g. while screen sharing (see
  [Hiding and redacting windows](#hiding-and-redacting-windows)).

### Searching

Typing narrows the overview to the windows whose title, app id or class match
(`fo` finds Firefox and every `foot` terminal). The query and the "matches / total" count
show in the pill at the top. Every match shows its caption, and the rest are dimmed.

<img width="1920" height="1080" alt="Searching for fo: matches show their caption, the rest are dimmed" src="https://github.com/user-attachments/assets/7a10c790-a252-4dd1-9169-e4f3f727ca8c" />

### Hiding and redacting windows

Two Hyprland window tags keep private windows out of the overview:

- `overview-hide` skips the window entirely (a workspace whose windows are all hidden
  disappears too).
- `overview-redact` keeps the window in its slot, still selectable, but draws a black
  box with the app icon instead of its content (it is never captured) and captions it
  with the app name instead of its title. Search only matches its app name and class,
  so typing cannot probe the title.

Set either tag on one window, by address from `hyprctl clients`:

```sh
hyprctl dispatch 'hl.dsp.window.tag({ tag = "+overview-redact", window = "address:0x…" })'
hyprctl dispatch 'hl.dsp.window.tag({ tag = "-overview-redact", window = "address:0x…" })'
```

or for every window of an app, with a window rule in `~/.config/hypr/`:

```lua
o.window({ class = "^(org.keepassxc.KeePassXC)$" }, { tag = "+overview-hide" })
o.window({ class = "^(signal)$" }, { tag = "+overview-redact" })
```

Windows that Hyprland keeps out of screen sharing (the `no_screen_share` window-rule
property, which Omarchy sets for 1Password and Bitwarden) are redacted as well. Set
`redactNoScreenShare` to `false` to show them normally.

## Keys

| Key | Action |
|---|---|
| `SUPER + F3` | open / close the overview (see [Install](#install)) |
| arrows | move the selection (spatial in grid; wraps around) |
| `Tab` / `Shift+Tab` | next / previous window |
| `Enter` (`Space` while the query is empty) | focus the selected window |
| `1`–`9`, `0` (while the query is empty) | jump to workspace 1–9, 10 |
| letters, digits, punctuation | type into the search |
| `Backspace`, `Ctrl+Backspace`, `Ctrl+U` | edit the search |
| `Escape` | clear the search, then close |
| click a window / click the backdrop | focus it / close |

## Install

Requires Omarchy 4 (tested on 4.0.4 with Hyprland 0.56.2 and Quickshell 0.3.1).

```sh
omarchy plugin add <path-or-url-of-this-repo> --enable --yes
```

From a checkout, `bin/install` does the same with the current committed `HEAD`.

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + F3", "Window overview", "omarchy-shell shell toggle git-spren.overview")
```

and turn off Hyprland's own layer animation for the overlay in
`~/.config/hypr/looknfeel.lua`, so it doesn't fight the plugin's animation:

```lua
hl.layer_rule({ match = { namespace = "git-spren-overview" }, no_anim = true, animation = "none" })
```

## Settings

All settings are optional. Copy [`settings.example.jsonc`](settings.example.jsonc) to
`~/.config/omarchy/git-spren.overview.json` and edit it. Changes apply on save; you don't need to
restart the shell. Comments and trailing commas are allowed.

| Key | Values | Default |
|---|---|---|
| `layout` | `"grid"`, `"columns"`, `"rows"` | `"grid"` |
| `zoom` | selected-thumbnail zoom in columns/rows: `"small"`, `"medium"`, `"large"` or a number 1.0–2.0 | `"medium"` |
| `selectedBorder` | `"accent"`, `"selected"`, `"foreground"`, `"urgent"` or `"#rrggbb"` | `"accent"` |
| `animate` | `"all"` (zoom the whole overview), `"current"` (fly the current workspace's windows), `"none"` | `"all"` |
| `animationDuration` | milliseconds, 60–1000 | `250` |
| `closeFadeStart` / `closeFadeEnd` | when the close fades the overlay out, in percent of `animationDuration` (0–100); it is gone at `closeFadeEnd` | `35` / `90` |
| `redactNoScreenShare` | redact windows with Hyprland's `no_screen_share` property, like `overview-redact` (`true` or `false`) | `true` |
| `refreshRate` | thumbnail refreshes per second for windows on visible workspaces (0.5–60), `0` for one snapshot at open, or `"live"` for every frame (heavy on the GPU) | `4` |

## Development

```sh
omarchy plugin validate .                     # check the manifest
bin/sync                                      # copy into the plugin dir and restart the shell
omarchy-shell shell toggle git-spren.overview       # open / close
omarchy-shell shell call git-spren.overview dump "" # current model as JSON
omarchy-shell shell call git-spren.overview press down
omarchy-shell shell call git-spren.overview type "fire"
qs log -p /usr/share/omarchy/shell            # shell log (QML errors, settings warnings)
```

## License

MIT, see [`LICENSE`](LICENSE).
