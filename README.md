# omarchy-keyboard-setup

A wizard that measures how long you actually hold keys, then sets Hyprland's
`repeat_delay` just above your worst case — and tells you when the problem is your
switches instead.

> **Status: installable, lightly tested.** `omarchy plugin validate` passes and
> `apply.sh` is verified end to end (write, idempotent re-run, `--show`, `--reset`,
> input rejection). The wizard overlay itself has not yet been driven through a full
> session, and there is no keybinding wired up — you summon it over IPC for now.

## The problem

Omarchy ships `repeat_delay = 250` in `default/hypr/input.lua`. Hyprland's own default is
600ms. At 250ms an ordinary pause — resting a finger while you think of the next word —
crosses the repeat threshold and emits a second character.

It is intermittent, it follows no pattern you can perceive, and it feels **exactly** like a
failing key switch. This repository exists because it fooled its author on a hot-swap
board. The switches were fine.

Measured on a YUNZII AL80, 144 keystrokes in one session:

```
 p50 143ms    p90 189ms    p99 256ms    max 433ms
 2 of 144 keystrokes — 1.4%, about one in seventy — exceed 250ms and double
```

## How it works

Measure **dwell time** — press to release, per keystroke. A phantom character appears
precisely when dwell exceeds `repeat_delay`, so the right setting is the top of your own
distribution plus a margin. That also captures the near misses: the 230ms hold that didn't
fire but was one distraction away.

The same data identifies real hardware chatter — a key pressed twice with no release
between, or re-pressed within 20ms — which no `repeat_delay` value can fix. Ending with
*"set it to 430ms"* **or** *"your E key is chattering"* is the point of the tool.

Full rationale, architecture, and open questions: [`dwell-time-calibration.md`](dwell-time-calibration.md)

## Use it

```bash
omarchy plugin add https://github.com/jaredeh/omarchy-keyboard-setup --enable
qs ipc call keyboard-repeat start
```

The wizard walks three steps: it explains what `repeat_delay` does and shows your current
value, gives you a passage to type while it times every keystroke, then shows you the
measured distribution with your current limit and a suggested one. **You move the line and
confirm before anything is written** — drag it, or use ←/→ (Shift for 50ms), `S` to snap
back to the suggestion, `R` to retest. Enter commits; Escape leaves everything alone.

Writes land in `~/.config/hypr/input.lua` inside a managed block, so re-running replaces
the value rather than stacking another one. `./apply.sh --reset` removes it entirely.

## Try just the measurement

```bash
qs -p ./spike/dwell-probe.qml
```

Run it from a terminal so you can see the log. It takes keyboard focus only when you click
it, Escape quits, and it hard-quits after 120 seconds. Type naturally and pause mid-word
sometimes — hesitation is where the tail lives.

On exit it prints your distribution and the `repeat_delay` you would need to never double.

## What the spike established

| Assumption | Result |
|---|---|
| Key releases reach a layer-shell overlay | confirmed |
| Press/release pair by `nativeScanCode` | confirmed — per-key attribution works |
| `KeyEvent.timestamp` reachable from QML | **no** — `undefined`; `Date.now()` is the only option |
| Synthetic repeats are press-only | **false** — Qt emits flagged press *and* release pairs |
| `hyprctl keyword` can suppress repeat live | **false** — non-legacy parser; use `hyprctl eval` |

Two tools report success while failing: `hyprctl keyword` prints a parser error and exits
0, and `omarchy plugin validate` prints a missing-entry-point error and exits 0. Check
output, not `$?`.

## Fixing it right now, without the tool

```lua
-- ~/.config/hypr/input.lua
hl.config({ input = { repeat_delay = 500 } })
```

500ms is a reasonable starting point. It is not calibrated to you — which is the entire
argument for building this.

## Built with

QML and JavaScript on [Quickshell](https://quickshell.outfoxxed.me/), plus a little bash.
Both are what Omarchy is already made of; nothing is compiled and no dependency is added.

## License

MIT — see [LICENSE](LICENSE).
