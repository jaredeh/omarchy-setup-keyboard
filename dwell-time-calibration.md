# Dwell-Time Calibration

*A proposed `omarchy setup keyboard repeat-delay` wizard*

A tool that measures how long you actually hold keys, then sets `repeat_delay` just
above your worst case — and tells you when the problem is your switches instead.

| | |
|---|---|
| **Status** | Proposal |
| **Surface** | `omarchy setup keyboard repeat-delay` |
| **Built as** | Quickshell QML plugin + bash helper |
| **Distributed as** | Git plugin — `omarchy plugin add` |
| **Target** | Hyprland 0.56.2, Quickshell 0.3.1 |
| **Validated by** | `spike/dwell-probe.qml`, 144 samples |

---

## The default is tuned past the point of safety

Omarchy ships `repeat_delay = 250` and `repeat_rate = 40` in `default/hypr/input.lua`.
Hyprland's own default is 600ms. At 250ms, an ordinary pause — resting a finger while
you think of the next word — crosses the repeat threshold and emits a second character.

The failure is nasty because of how it presents. It is intermittent, it follows no
pattern the typist can perceive, and it is **identical in feel to a failing key switch**.
This proposal came out of a session where the reported symptom was "my keyboard double
types constantly, it's way too sensitive," on a hot-swap board where switch chatter was
the obvious suspect. It wasn't the switches. Anyone with a mechanical keyboard will reach
the same wrong conclusion, and some fraction of them will reseat switches or RMA a board
over a config default.

> Raising the default would trade one arbitrary number for another. The right value is a
> property of the individual typist, and it is measurable.

---

## Decision: measure dwell time, don't detect repeats

The instinct is to have the user type a prompt and check the result for doubled
characters. That approach is weak: real typos confound the diff, the user has to
proofread, and you only get signal on the rare keystrokes that actually misfired.

Measure **dwell time** instead — the interval between press and release of a single key.
A phantom character occurs precisely when dwell exceeds `repeat_delay`. That turns a
subjective "did that feel wrong" into one number per keystroke, and crucially it captures
the *near misses*: the 230ms hold that didn't fire but was one distraction away from
firing. Near misses are the entire basis for choosing a safe threshold, and
repeat-detection is blind to them.

```
 hold (ms)   keystrokes                      n = 144, one 120s session
  20– 40   ▏1
  40– 60   ▏1
  60– 80   █████ 5
  80–100   ████████ 8
 100–120   ███████████████ 16
 120–140   ██████████████████████████████████ 37
 140–160   ████████████████████████████████ 35
 160–180   █████████████████ 19
 180–200   ██████████ 11
 200–220   ███████ 8
 220–240   ▏1
─────────────────────────────────────────────────────  250ms · Omarchy default
 240–260   ▏1  ← doubles
      ⋮        (nothing at all between 260 and 420)
 420–440   ▏1  ← doubles
─────────────────────────────────────────────────────  500ms · currently applied

 p50 143    p90 189    p99 256    max 433
```

**Measured, not illustrative.** 144 keystrokes captured in one session on a YUNZII AL80
with `spike/dwell-probe.qml`. Two of them — 1.4%, roughly one keystroke in seventy — exceed
250ms and would emit a phantom character on Omarchy's default. That rate is entirely
consistent with the reported symptom of constant double-typing.

Note the shape of the tail. The single 433ms sample sits 177ms clear of the next-highest
keystroke and sets the threshold **on its own**. A different session could as easily have
produced 380 or 520. That instability is the whole argument for accumulating across runs:
the peak of this distribution is stable after a hundred samples, and the maximum is not.

---

## How key repeat actually works on Wayland

Two protocol facts shape every decision below, and both are counterintuitive.

**The compositor does not generate repeat.** Hyprland sends exactly one `wl_keyboard.key`
event on press and one on release. It never sends repeated keys. Separately it broadcasts
`wl_keyboard.repeat_info { rate, delay }`, and **each client synthesizes repeats itself**.

So `repeat_delay = 250` is not a behavior Hyprland performs. It is a number Hyprland
*tells every client*, which Qt, GTK, and xkbcommon-based terminals then implement
independently — mostly consistently. Two consequences: verification has to be per-toolkit,
and a client that simply ignores `repeat_info` sees no autorepeat whatsoever.

**The compositor is an input monopoly.** It holds the only privileged read on
`/dev/input/*`, and every other process receives keys exclusively through `wl_keyboard`,
exclusively while focused. There is no X11-style global grab — a deliberate Wayland
security property. Any tool that wants to see key releases must own focus to see anything
at all.

---

## Constraint: this cannot be a terminal program

A TTY delivers characters, not key-up events. There is no dwell time to be had from
`termios` at any level of cleverness, which rules out the shell-script shape every other
`omarchy setup` wizard uses.

Reading `/dev/input/event*` directly would work, but those devices are `root:input` and a
default Omarchy user is not in the `input` group. Requiring that group — or root — for a
comfort setting is a poor trade: it grants a global keylogging capability to fix key
repeat.

That leaves a Wayland client, which is the right answer anyway.

---

## The hard part: the sample is the whole problem

Worst-case dwell does not come from typing fast. It comes from **hesitation** — a finger
resting on a key while you think of the next word, reach for a modifier, or lose your
place on the line. A familiar pangram typed fluidly produces a tidy distribution topping
out near 150ms. Ship the value derived from that and it fails the first time the user
pauses mid-word.

So the prompt text has to work against flow rather than for it:

- Random alphanumeric strings and mixed case, so nothing is muscle memory.
- Pinky-weighted content — `a q z p ; shift` — because those fingers are slow and weak
  and they dominate the tail.
- Deliberate think-points: transcription or arithmetic mid-line, forcing a pause with
  hands still on the keys.
- Enough length to get bored. Attention lapses are where the tail lives.

Even then, ninety seconds cannot honestly justify a value at the bleeding edge. A tail
estimate needs volume.

---

## Decision: accumulate across runs, don't watch passively

The obvious answer to needing volume is a background collector sampling real work. **On
Wayland that is impossible.** A client sees only the keystrokes delivered to its own
focused surface, so a passive collector watching you use your editor would record nothing.
Getting that data means either a compositor plugin — C++, ABI-fragile, broken by every
Hyprland release — or an evdev daemon with exactly the privileges rejected above.

Accumulate instead. Store the histogram in
`~/.local/state/omarchy/keyboard-dwell.json`, merge on every calibration run, and let the
recommendation tighten as the sample count grows. Three ninety-second sessions across a
week gives the tail volume that matters, without privileges Wayland is right to withhold.

This is a better feature than passive watching anyway: it makes re-running the wizard
*useful* rather than merely idempotent, and the user can see the recommendation converge.

### Report the distribution, not a number

Show the histogram and make the margin the user's choice — `P100 + 150` for safe,
`P100 + 50` for tight — with the tradeoff and the sample count both visible. A tool that
silently picks one number teaches nothing about how much headroom was surrendered, and
this is a setting whose failure mode reveals itself gradually enough that the user needs
to understand what they chose.

**P100 must be taken over retained samples, not raw ones.** A single intentional hold — the
user leaning on backspace — measured 1323ms in testing, which would recommend a
`repeat_delay` of 1423ms and make every held key useless. Percentiles do not rescue this:
at n=103 both P99.5 and P100 select that same outlier.

Reject dwells above a fixed ceiling (600ms is comfortably past any typing keystroke and
far below a deliberate hold) as non-typing, report how many were discarded, and compute the
recommendation from what remains. Rejecting holds structurally is more honest than
softening the percentile, because a held key is not a slow keystroke — it is a different
gesture that happens to share a measurement.

---

## Decision: a Quickshell QML plugin plus a bash wrapper

**The tool is written in QML and JavaScript, with a thin bash entry point.** Those are the
two languages Omarchy is already made of — the shell is QML, the commands are bash.
Nothing is compiled, no runtime is added, no new dependency is introduced.

| Piece | Language | Owns |
|---|---|---|
| `Calibrate.qml` | QML + JS | Overlay, key capture, dwell math, histogram, margin choice |
| `apply.sh` | Bash | The `input.lua` write and the revert timer |
| `manifest.json` | — | Plugin id, entry point, version |

All three live in the plugin directory. Nothing is installed to `PATH`.

The split follows capability. QML has the key events and can draw a real histogram with
`Canvas`; bash does file manipulation and process supervision that must survive the
overlay closing.

**Flow:**

1. A keybinding or the Omarchy menu calls `qs ipc call keyboard-calibration start`
2. The handler returns `"ok"` immediately — it does not block for the length of the test
3. The overlay records press/release keyed by `nativeScanCode`, discarding `isAutoRepeat`
4. QML computes P100 and the chatter signature, draws the distribution, offers the margin
5. QML invokes `apply.sh <value>` by absolute path through Quickshell's `Process`
6. Bash writes the managed block, reloads, and runs revert-on-timeout under a `trap`

It runs as a plugin inside the **already-running** shell rather than a second `qs`
instance — that avoids two Quickshell processes competing for layer-shell surfaces, and it
inherits `qs.Commons` theme tokens so the overlay matches the active theme for free.

### Build on what already exists

- **`Ui/KeyboardPanel.qml`** — a layer-shell `PanelWindow` on `WlrLayer.Overlay` with
  focus acquisition already solved. Its header documents a trap worth reading first:
  layer-shell grants focus to the *surface*, but Qt still needs an active-focus *item*
  inside it before `Keys.onPressed` fires at all, scheduled via `Qt.callLater` after map.
- **`Ui/PanelKeyCatcher.qml`** — the focus target that pairs with it.
- **`IpcHandler`** — the pattern for bash-to-shell calls, as in `plugins/osd/Osd.qml:115`.
- **`Quickshell.Hyprland`** — lets the overlay suppress and restore `repeat_delay` during
  the test directly, keeping the restore inside the same object lifetime that owns the
  measurement rather than round-tripping through `hyprctl`.

### Suppressing repeat during the test

Qt implements `repeat_info` itself, and **it emits synthetic presses _and_ synthetic
releases** — measured as symmetric pairs, 34 of each in a run with `repeat_delay` forced
to 150ms. Both halves carry `isAutoRepeat`.

This makes filtering load-bearing rather than merely tidy. An unfiltered synthetic release
would terminate a dwell measurement at `repeat_delay` instead of at the physical release,
systematically truncating every long hold to the threshold and erasing exactly the tail the
tool exists to measure. Filtering does work — a deliberate 1323ms hold measured end to end
with the filter in place — but it works because the flag is set correctly on both halves,
not because synthetic events are structurally incapable of corrupting the pairing.

So suppression is the robust primary and filtering is defense in depth. Raise
`repeat_delay` for the duration of the test so no synthetic events are generated at all:

```bash
hyprctl eval 'hl.config({ input = { repeat_delay = 2000 } })'
```

**Not `hyprctl keyword`.** On Hyprland 0.56 that fails against Omarchy's Lua config with
`keyword can't work with non-legacy parsers` — and still exits 0. `hyprctl reload` restores
from `input.lua`, which means the managed block *is* the restore path and a tool that dies
mid-test self-heals on the next reload.

### Why not something else

**Rust or C on `wayland-client`** buys exact protocol timestamps and zero repeat
synthesis — genuinely the better measurement — at the cost of hand-rolling text rendering
and surface management for what is fundamentally a typing test. Wrong trade for precision
that isn't needed.

**A standalone C++/Qt application** gets `QInputEvent::timestamp()` cleanly but needs its
own layer-shell integration, theming, and packaging. Quickshell already *is* that
application.

**Python with evdev** dies on the input-group argument above. **Pure bash** cannot see
key-up at all.

### On timestamp precision

QML's `KeyEvent` exposes `key`, `text`, `modifiers`, `isAutoRepeat`, `count`,
`nativeScanCode` — but appears not to expose `timestamp`, so handlers must use
`Date.now()`. That records when the event loop reached the event, not the physical
release.

This is probably fine. Dwell is `release − press`, and correlated event-loop latency
largely cancels in the subtraction; residual jitter of a few milliseconds against a
50–150ms margin is noise. It is tightest for chatter detection, where gaps under 20ms are
being classified — but real bounce is 1–5ms, far from the boundary, and the other chatter
signature (a press with no intervening release) is immune to timing jitter entirely.

Worth an empirical check before committing. If it fails, the fix is a small C++ QML plugin
exposing `QKeyEvent::timestamp()`, not a different language for the tool.

---

## Verified on hardware

`spike/dwell-probe.qml` is a ~200-line Quickshell overlay that captures press/release
pairs and prints a summary. Three runs, 350 keystrokes, on a YUNZII AL80 under Hyprland
0.56.2 and Quickshell 0.3.1:

| Assumption | Result |
|---|---|
| Key releases reach a layer-shell overlay | **confirmed** |
| Press/release pair by `nativeScanCode` | **confirmed** — per-key attribution works |
| `KeyEvent.timestamp` reachable from QML | **no** — `undefined`; `Date.now()` is the only option, and no C++ plugin is needed |
| Synthetic repeats are press-only | **false** — Qt emits flagged press *and* release pairs |
| `hyprctl keyword` can suppress repeat live | **false** — non-legacy parser; use `hyprctl eval` |
| Board is chattering | **no** — 0 press-without-release, 0 sub-20ms rebounds across 350 samples |

The chatter result is worth stating plainly: the double-typing that motivated this document
was entirely the 250ms default. The hardware was never at fault, which is precisely the
conclusion a user cannot reach unaided.

Two tools reported success while failing: `hyprctl keyword` printed a parser error and
exited 0, and `omarchy plugin validate` printed a missing-entry-point error and exited 0.
Anything wiring these into CI must check output rather than status.

---

## Decision: writing the result

The value belongs in `~/.config/hypr/input.lua`, never the packaged default. Two details
that a hand-edit gets away with and a tool cannot:

**Idempotent writes.** Use a marked managed block so a re-run replaces rather than
appending. Repeated calibration must not accumulate stale `hl.config` calls that silently
shadow one another.

```lua
-- >>> omarchy:keyboard-repeat (managed — edits here are overwritten)
hl.config({ input = { repeat_delay = 430 } })
-- <<< omarchy:keyboard-repeat
```

**Revert on timeout.** Apply, then confirm — "Keep this setting? Reverting in 15s" — the
same pattern a display-resolution change uses. Cheap insurance on a value whose badness
surfaces over minutes rather than instantly.

Scope the write to `repeat_delay` alone. `repeat_rate` is not a safety lever: the first
phantom character lands at `delay`, and rate only governs characters two and later.
Touching it widens the blast radius for no reduction in doubling.

---

## Decision: detect real chatter and say so

This is the feature that justifies building the tool rather than documenting the setting.

The collector is already timing every press and release, so it can recognize hardware
bounce for free: the same key pressed twice with no intervening release, or a
release-to-press gap under roughly 20ms. That is a failing switch, and *no* `repeat_delay`
value fixes it.

Because `nativeScanCode` carries the evdev keycode, chatter can be attributed to a
**specific physical key** — which is exactly what a user needs to act on it, since the
remedy is replacing one switch rather than the board.

> Ending with "your delay should be 430ms" **or** "the `E` key on your board is chattering,
> this setting won't help you" resolves in ninety seconds the exact ambiguity that
> otherwise costs a user a week of suspicion and possibly a new keyboard.

It also protects the tool's credibility. Without chatter detection, a user with a
genuinely failing switch calibrates, sees no improvement, and concludes the tool is
broken.

---

## Distribution: plugin first, upstream later

Omarchy installs shell plugins straight from git. `omarchy plugin add <url>` clones the
repository, reads `manifest.json` **at its root**, and installs into a directory named by
the manifest `id`. So this repository *is* the plugin, and shipping it requires no
maintainer approval and no packaging:

```bash
omarchy plugin add https://github.com/jaredeh/omarchy-keyboard-setup --enable
```

```json
{
  "schemaVersion": 1,
  "id": "jaredeh.keyboard-calibration",
  "name": "Keyboard Calibration",
  "version": "0.1.0",
  "author": "Jared Hulbert",
  "description": "Measure key dwell time to calibrate repeat_delay and detect switch chatter.",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "Calibrate.qml" }
}
```

`kinds: ["overlay"]` matches `omarchy.clipboard` — a summoned full-screen surface.
`keepLoaded: true` is required so the `IpcHandler` exists before anything calls it.

**A plugin cannot put a binary on `PATH`.** That is the one thing this form gives up:
`omarchy setup keyboard repeat-delay` exists only if the tool is upstreamed into `bin/`. Until then the
wizard is summoned from a keybinding or the Omarchy menu, and `apply.sh` is invoked by
absolute path from inside the plugin directory.

| | As a git plugin (now) | Upstreamed (later) |
|---|---|---|
| Install | `omarchy plugin add <url>` | ships with Omarchy |
| Trigger | keybinding or Omarchy menu | `omarchy setup keyboard repeat-delay` |
| Helper | `apply.sh` in the plugin dir | `bin/omarchy-setup-keyboard-repeat-delay` on `PATH` |
| Approval needed | none | Discussion, then PR |

### Development

The plugin directory hot-reloads on save, so clone the repository directly to
`~/.config/omarchy/plugins/jaredeh.keyboard-calibration/` and edit in place — there is no
restart cycle while iterating on QML. `omarchy-shell shell rescanPlugins` forces a reload
if a change fails to take, and `omarchy plugin validate <folder>` mirrors the checks in
`shell/services/PluginRegistry.qml`, so it refuses anything the running shell would reject.

### Naming

Omarchy derives a command's route from its binary filename, hyphens becoming spaces:
`omarchy-setup-direct-boot` is invoked as `omarchy setup direct boot`. No command in the
CLI uses an underscore. So the idiomatic form is a nested `keyboard` group with a
kebab-case leaf — `omarchy setup keyboard repeat-delay`, from
`bin/omarchy-setup-keyboard-repeat-delay` — rather than `keyboard_repeat_delay`.

The nesting also leaves room: `repeat-rate`, `layout`, and `chatter` are plausible
siblings under the same `keyboard` group, and a bare `omarchy setup keyboard` would have
claimed that space for one setting.

### Upstreaming

Omarchy reserves issues for validated bugs; a new wizard is a feature and belongs in
[Discussions → suggestions](https://github.com/basecamp/omarchy/discussions/categories/suggestions)
first. A PR forks `basecamp/omarchy`, follows that repository's own `AGENTS.md`, and runs
`./test/all` before `gh pr create`. Never develop against `/usr/share/omarchy`.

Upstreaming is also what unlocks a real CLI surface, in the `omarchy setup` group beside
`setup security fido2`:

| Command | Behavior |
|---|---|
| `omarchy setup keyboard repeat-delay` | Run the guided calibration, merge into the stored histogram, show the distribution, offer safe / tight margins, apply with revert-on-timeout. |
| `… --show` | Print the current value, the stored histogram, the sample count, and the measured headroom without changing anything. |
| `… --device <name>` | Calibrate one keyboard into a Hyprland per-device section rather than the global input block. |
| `… --reset` | Remove the managed block and the stored histogram, falling back to the Omarchy default. |

Ship the plugin first regardless. A working tool with real dwell histograms is a far
stronger argument than a design document.

### Per-device or global

Dwell time is mostly a property of the typist, not the board — but travel depth and key
height shift it enough to matter, and a laptop's internal keyboard next to a tall
mechanical is a realistic split. Hyprland supports per-device input sections, so store
measurements per device and apply globally by default, with `--device` as the escape
hatch. A typical desktop enumerates several HID devices that report as keyboards but are
receivers or headsets; the picker should show only devices that have produced real
keystrokes.

---

## Open: to verify before building

- **Per-toolkit repeat semantics.** Qt is measured to emit repeat as press/release pairs;
  whether GTK and xkbcommon-based terminals agree, and whether the first repeat fires at
  exactly `delay`, is unconfirmed. The "rate is not a safety lever" argument rests on it.
- **Rejection ceiling.** 600ms is a guess at the boundary between a slow keystroke and a
  deliberate hold. Worth deriving from accumulated data rather than asserting.
- **Suppression from inside QML.** `hyprctl eval` is confirmed to work from a shell;
  whether `Quickshell.Hyprland` can issue the same Lua evaluation, or whether the plugin
  must shell out via `Process`, is untested.
- **Exclusive focus tradeoff.** `Ui/KeyboardPanel.qml` deliberately avoids sustained
  `WlrKeyboardFocus.Exclusive` because Hyprland routes *every* pointer event to an
  exclusive surface regardless of output. A modal test probably wants Exclusive anyway,
  but confirm the multi-monitor behavior is acceptable.
- **Per-device syntax.** Confirm the exact Hyprland 0.56 device-section syntax for
  `repeat_delay` before committing to the `--device` flag.
- **Sample sufficiency.** How many keystrokes, and how many runs, before a P100 estimate
  is stable enough to tighten the margin on.
- **Trigger surface as a plugin.** Whether an `overlay` plugin can register its own
  keybinding, or whether summoning it requires a manual `bindd` in `bindings.lua` plus an
  entry in `omarchy-menu.jsonc`.

---

*Originated from a misdiagnosis: persistent double-typing on a YUNZII AL80 attributed to
switch chatter, resolved by raising `repeat_delay` from the shipped 250ms to 500ms.
Environment: Hyprland 0.56.2, Quickshell 0.3.1, user not in the `input` group.*
