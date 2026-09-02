# omarchy-setup-keyboard

Tunes Hyprland's key repeat delay to how *you* type — and tells you when your keyboard is
actually broken.

If your keyboard seems to double-type, it's probably not the switches. Omarchy ships
`repeat_delay = 250`; Hyprland's own default is 600. At 250ms a normal pause mid-word
crosses the repeat threshold and emits a second character, which feels exactly like a
failing switch.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jaredeh/omarchy-setup-keyboard/main/install.sh | bash
```

Installs the plugin and adds its menu entry. Pipe it to `bash`, not `sh`.

To read it first, or to remove everything again:

```bash
curl -fsSL https://raw.githubusercontent.com/jaredeh/omarchy-setup-keyboard/main/install.sh -o install.sh
less install.sh && bash install.sh
bash install.sh --uninstall
```

## Manual install

```bash
omarchy plugin add https://github.com/jaredeh/omarchy-setup-keyboard --enable
```

Add one entry to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"setup.keyboard-repeat": {
  "icon": "󰌌",
  "label": "Keyboard repeat",
  "description": "Calibrate repeat delay from how you actually type",
  "aliases": ["repeat-delay", "double-typing", "key-repeat"],
  "action": "omarchy-shell shell summon jaredeh.keyboard-calibration"
}
```

## Run

**SUPER + SPACE → Setup → Keyboard repeat**, or open the menu and type `double`.

From a terminal:

```bash
omarchy menu summon setup.keyboard-repeat
```

## What happens

Three steps, all keyboard-driven.

1. **Explains** what the setting does and shows your current value.
2. **Times you typing** a short passage — every press and release, so it learns how long
   you actually hold keys. Pause mid-word when you lose your place; those pauses are the
   whole point.
3. **Shows you the data** and lets you pick. Your current limit and a suggested one are
   marked on the distribution. Move the line wherever you want, then confirm.

Nothing is written until you press Enter on an explicit confirmation.

| Key | |
|---|---|
| `←` `→` | move the threshold by 10ms (`Shift` for 50) |
| drag | move it with the mouse |
| `S` | snap back to the suggested value |
| `R` | retest |
| `Enter` | commit the value shown |
| `Esc` | leave without changing anything |

## Where it writes

`~/.config/hypr/input.lua`, in a managed block:

```lua
-- >>> omarchy:keyboard-repeat (managed — edits here are overwritten)
hl.config({ input = { repeat_delay = 430 } })
-- <<< omarchy:keyboard-repeat
```

Re-running replaces that block rather than adding another. Every write makes a timestamped
backup alongside the file.

```bash
./apply.sh --show     # what's currently set
./apply.sh --reset    # remove it, back to the Omarchy default
```

## If it says your keyboard is chattering

It found the same key pressed twice with no release between, or re-pressed within 20ms.
That's a failing switch, and no repeat delay will fix it — replace the switch. The tool
names which key so you don't have to guess.

## Also here

[`dwell-time-calibration.md`](dwell-time-calibration.md) — why this measures dwell time,
how the value gets chosen, and what remains unproven.

[`spike/dwell-probe.qml`](spike/dwell-probe.qml) — a bare measurement probe. Run it with
`qs -p ./spike/dwell-probe.qml` to print your dwell distribution, with no UI and no writes.

## License

MIT — see [LICENSE](LICENSE).
