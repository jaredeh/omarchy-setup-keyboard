# omarchy-keyboard-setup

Tunes Hyprland's key repeat delay to how *you* type — and tells you when your keyboard is
actually broken.

If your keyboard seems to double-type, it's probably not the switches. Omarchy ships
`repeat_delay = 250`; Hyprland's own default is 600. At 250ms a normal pause mid-word
crosses the repeat threshold and emits a second character, which feels exactly like a
failing switch.

## Install

```bash
omarchy plugin add https://github.com/jaredeh/omarchy-keyboard-setup --enable
```

## Run

Bind it — add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER CTRL", "K", "Calibrate key repeat", function()
  hl.dispatch(hl.dsp.exec("qs ipc call keyboard-repeat start"))
end)
```

Or call it directly:

```bash
qs ipc call keyboard-repeat start
```

> **Why not `omarchy setup keyboard repeat-delay`?**
> That is the name this would take as a built-in, and the design doc proposes it. The
> `omarchy` dispatcher resolves subcommands only inside its own `bin` directory, never
> `PATH`, so no installed plugin can register one — it would mean writing into `/usr/bin`.
> Until this is upstreamed, a keybinding is the real front door.

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

## Status

Works, lightly tested. `apply.sh` is verified end to end; the wizard overlay has been
built but not yet driven through a full session on a fresh install. No screenshot yet.

Design rationale, measurements, and open questions:
[`dwell-time-calibration.md`](dwell-time-calibration.md).
A standalone measurement probe with no UI lives in [`spike/`](spike/dwell-probe.qml).

## License

MIT — see [LICENSE](LICENSE).
