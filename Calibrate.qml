// Calibrate.qml — the keyboard repeat-delay calibration wizard.
//
// Four phases, driven entirely from the keyboard:
//
//   intro   explain what this is and what it will change
//   typing  a fixed passage to transcribe; every press/release is timed
//   review  the measured distribution, the current limit, the suggestion,
//           and a threshold line the user can move before agreeing
//   done    what was written, and the choice to retest or leave
//
// Nothing is written until the user explicitly confirms in `review`.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  // ---- lifecycle --------------------------------------------------------
  //
  // Overlay plugins are summoned by id — `omarchy-shell shell summon <id>` —
  // and with keepLoaded false the shell creates this item on summon and
  // destroys it on hide. Existence is the open state, so there is no local
  // `open` flag and every session starts clean, which is what a wizard wants.
  //
  // These three are injected by the shell's plugin loader if declared.

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property string phase: "intro"          // intro | typing | review | done
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- measurement ------------------------------------------------------

  // Dwells above this are a deliberate hold (leaning on backspace), not a
  // keystroke. They are a different gesture that happens to share a
  // measurement, and including them would recommend an absurd delay.
  readonly property int holdCeilingMs: 600

  // Finishing early is allowed, but not from a handful of keystrokes: the
  // whole point is the tail, and a tail estimate from ten samples is a guess
  // wearing a number's clothing. Below this the affordance is not offered.
  readonly property int minSamples: 40

  property var downAt: ({})
  property var upAt: ({})
  property var dwells: []
  property int rejectedHolds: 0
  property int chatterNoRelease: 0
  property int chatterRebound: 0
  property int tick: 0

  property string typed: ""

  readonly property string prompt:
    "The quick zephyr jabs of my vexed pixie quill.\n" +
    "Codes: az-QP-72, zq9-PLA-4x, xzq-06-Pz, aqp-Z3-11\n" +
    "Words: quizzical jazzy pizzazz syzygy plaza aqua\n" +
    "Copy these in order: 4817, 2093, 6654, 3371, 5528\n" +
    "Awkward: aqz;p AQZ:P a-q-z-; p0p q1q z2z ;;pp qq"

  // ---- values -----------------------------------------------------------

  property int currentDelay: 0            // read live from Hyprland
  property int chosenDelay: 0             // what the user will commit
  property string applyResult: ""

  readonly property int maxRetained: {
    tick
    var m = 0
    for (var i = 0; i < dwells.length; i++) if (dwells[i] > m) m = dwells[i]
    return m
  }

  // The recommendation: the worst real keystroke, plus honest headroom.
  readonly property int suggestedDelay: {
    tick
    if (dwells.length === 0) return currentDelay
    return Math.min(1000, Math.max(200, Math.round((maxRetained + 100) / 10) * 10))
  }

  readonly property int wouldDoubleAtChosen: {
    tick
    var n = 0
    for (var i = 0; i < dwells.length; i++) if (dwells[i] > chosenDelay) n++
    return n
  }

  readonly property int wouldDoubleAtCurrent: {
    tick
    var n = 0
    for (var i = 0; i < dwells.length; i++) if (dwells[i] > currentDelay) n++
    return n
  }

  function percentile(p) {
    if (dwells.length === 0) return 0
    var s = dwells.slice().sort(function (a, b) { return a - b })
    return s[Math.min(s.length - 1, Math.floor(s.length * p))]
  }

  function resetMeasurement() {
    downAt = ({}); upAt = ({}); dwells = []
    rejectedHolds = 0; chatterNoRelease = 0; chatterRebound = 0
    typed = ""; tick++
  }

  // ---- key capture ------------------------------------------------------

  function handlePress(event) {
    if (event.isAutoRepeat) return          // synthetic; both halves are flagged
    var scan = event.nativeScanCode || event.key
    var t = Date.now()

    if (downAt[scan] !== undefined) chatterNoRelease++
    if (upAt[scan] !== undefined && (t - upAt[scan]) < 20) chatterRebound++

    downAt[scan] = t
  }

  function handleRelease(event) {
    if (event.isAutoRepeat) return
    var scan = event.nativeScanCode || event.key
    if (downAt[scan] === undefined) return

    var t = Date.now()
    var dwell = t - downAt[scan]
    delete downAt[scan]
    upAt[scan] = t

    if (dwell > holdCeilingMs) rejectedHolds++
    else dwells.push(dwell)
    tick++
    if (phase === "typing") livePlot.requestPaint()
  }

  function typeChar(event) {
    if (event.key === Qt.Key_Backspace) {
      typed = typed.slice(0, -1)
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (typed.length < prompt.length) typed += "\n"
      return
    }
    if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32)
      typed += event.text
  }

  // ---- phase transitions ------------------------------------------------

  function beginTyping() {
    resetMeasurement()
    phase = "typing"
  }

  function finishTyping() {
    chosenDelay = suggestedDelay
    phase = "review"
    plot.requestPaint()
  }

  function commit() {
    applyProc.command = [pluginDir + "apply.sh", String(chosenDelay)]
    applyProc.running = true
    phase = "done"
  }

  // close() is the shell's teardown hook, not our dismiss button: shell.hide()
  // invokes it via invokeIfLoaded(id, "close"). Calling shell.hide() from in
  // here recurses until the stack blows, the hide never completes, and the
  // overlay stays up holding an exclusive grab on keyboard and pointer.
  // Tear down only.
  function close() {
    // Nothing to undo. This deliberately mutates no global state while it
    // runs, so being killed at any moment leaves the system as it found it.
  }

  // What Escape actually calls. The shell invokes close() on the way through,
  // then drops us from openPanelIds so the Loader destroys the item.
  function dismiss() {
    var id = manifest && manifest.id ? manifest.id : "jaredeh.keyboard-calibration"
    if (shell && typeof shell.hide === "function") shell.hide(id)
    else close()
  }

  // ---- processes --------------------------------------------------------

  Process {
    id: readDelay
    command: ["hyprctl", "getoption", "input:repeat_delay", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.currentDelay = JSON.parse(text).int } catch (e) { root.currentDelay = 250 }
        if (root.chosenDelay === 0) root.chosenDelay = root.currentDelay
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { onStreamFinished: root.applyResult = text.trim() }
    onExited: function (code) {
      if (code !== 0 && root.applyResult === "") root.applyResult = "apply.sh failed (" + code + ")"
      readDelay.running = true
    }
  }

  Component.onCompleted: readDelay.running = true

  // ---- surface ----------------------------------------------------------

  PanelWindow {
    id: win
    visible: true

    anchors { top: true; bottom: true; left: true; right: true }
    color: Color.menu.scrim

    WlrLayershell.namespace: "omarchy-keyboard-repeat"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // Anything holding an exclusive grab on keyboard and pointer needs a way
    // out that does not depend on its own code being correct.
    Timer {
      id: idleGuard
      interval: 300000          // five minutes without a keystroke
      running: true
      onTriggered: root.dismiss()
    }

    // Layer-shell grants focus to the surface, but Qt still needs an
    // active-focus item inside it before Keys.* fires at all.
    Component.onCompleted: Qt.callLater(function () { keys.forceActiveFocus() })

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function (event) {
        event.accepted = true

        idleGuard.restart()
        if (event.key === Qt.Key_Escape) { root.dismiss(); return }

        if (root.phase === "intro") {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.beginTyping()
          return
        }

        if (root.phase === "typing") {
          // Ctrl+Enter / Ctrl+D end the sample early. Checked before anything
          // else so the chord never lands in the transcript, and gated on a
          // usable sample size.
          var finishChord = (event.modifiers & Qt.ControlModifier) &&
                            (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
                             event.key === Qt.Key_D)
          if (finishChord) {
            if (root.dwells.length >= root.minSamples) root.finishTyping()
            return
          }

          // Qt synthesises repeat as flagged press/release pairs. Dropping
          // both halves keeps the dwell pairing intact and stops repeats from
          // filling the transcript, which is why this needs no global
          // repeat_delay suppression to undo.
          if (event.isAutoRepeat) return
          root.handlePress(event)
          root.typeChar(event)
          if (root.typed.length >= root.prompt.length) root.finishTyping()
          return
        }

        if (root.phase === "review") {
          if (event.key === Qt.Key_Left)  { root.chosenDelay = Math.max(100, root.chosenDelay - (event.modifiers & Qt.ShiftModifier ? 50 : 10)); plot.requestPaint() }
          else if (event.key === Qt.Key_Right) { root.chosenDelay = Math.min(1500, root.chosenDelay + (event.modifiers & Qt.ShiftModifier ? 50 : 10)); plot.requestPaint() }
          else if (event.key === Qt.Key_R) { root.beginTyping() }
          else if (event.key === Qt.Key_S) { root.chosenDelay = root.suggestedDelay; plot.requestPaint() }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.commit()
          return
        }

        if (root.phase === "done") {
          if (event.key === Qt.Key_R) root.beginTyping()
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.dismiss()
          return
        }
      }

      Keys.onReleased: function (event) {
        event.accepted = true
        if (root.phase === "typing") root.handleRelease(event)
      }

      // ---- card ----------------------------------------------------------

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(80), Style.space(760))
        height: Math.min(parent.height - Style.space(60), body.implicitHeight + Style.space(64))
        color: Color.menu.background
        radius: Style.cornerRadius
        border.width: Math.max(1, Style.space(1))
        border.color: Color.menu.border

        Column {
          id: body
          anchors.fill: parent
          anchors.margins: Style.space(32)
          spacing: Style.spacing.xl

          // ---- header ----

          Text {
            text: "Keyboard repeat delay"
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            text: {
              switch (root.phase) {
              case "intro":  return "Step 1 of 3 — what this does"
              case "typing": return "Step 2 of 3 — typing sample"
              case "review": return "Step 3 of 3 — choose the value"
              default:       return "Done"
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Color.menu.border; opacity: 0.5 }

          // ================= INTRO =================

          Column {
            visible: root.phase === "intro"
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              lineHeight: 1.35
              text: "When you hold a key longer than the repeat delay, it starts repeating. " +
                    "If that delay is set too low, an ordinary pause mid-word emits a second " +
                    "character — which feels exactly like a failing key switch, but isn't."
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              lineHeight: 1.35
              text: "This measures how long you actually hold keys, then suggests a delay just " +
                    "above your slowest keystroke. You will see the measurements and choose the " +
                    "final value yourself. Nothing is changed until you confirm."
            }

            Rectangle {
              width: parent.width
              height: currentRow.implicitHeight + Style.space(24)
              color: Color.menu.selectedBackground
              radius: Style.cornerRadius

              Column {
                id: currentRow
                anchors.centerIn: parent
                width: parent.width - Style.space(32)
                spacing: Style.spacing.xs

                Text {
                  text: "Current setting"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: root.currentDelay + " ms"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: "You will type a short passage. Type it as you normally would — and let " +
                    "yourself pause mid-word when you lose your place. Those pauses are the " +
                    "measurement that matters. Typos are fine and do not affect the result."
            }

            Text {
              text: "Press Enter to begin      ·      Esc to cancel"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // ================= TYPING =================

          Column {
            visible: root.phase === "typing"
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              text: "Type this:"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              width: parent.width
              height: promptText.implicitHeight + Style.space(24)
              color: Color.menu.selectedBackground
              radius: Style.cornerRadius

              Text {
                id: promptText
                anchors.centerIn: parent
                width: parent.width - Style.space(28)
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pixelSize: Style.font.body
                lineHeight: 1.5
                text: {
                  root.tick; root.typed
                  var done = root.typed.length
                  var head = root.esc(root.prompt.slice(0, done))
                  var here = root.esc(root.prompt.slice(done, done + 1))
                  var tail = root.esc(root.prompt.slice(done + 1))
                  return "<span style='color:" + Color.muted + "'>" + head + "</span>" +
                         "<span style='background-color:" + Color.accent + ";color:" + Color.menu.background + "'>" + here + "</span>" +
                         "<span style='color:" + Color.menu.text + "'>" + tail + "</span>"
                }
              }
            }

            Text {
              text: "You typed:"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              width: parent.width
              height: Math.max(Style.space(80), typedText.implicitHeight + Style.space(24))
              color: "transparent"
              radius: Style.cornerRadius
              border.width: Math.max(1, Style.space(1))
              border.color: Color.accent

              Text {
                id: typedText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(14)
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pixelSize: Style.font.body
                lineHeight: 1.5
                text: root.renderTyped()
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xxl

              Text {
                text: root.typed.length + " / " + root.prompt.length + " characters"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: { root.tick; return root.dwells.length + " keystrokes timed" }
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: { root.tick; return "slowest so far " + root.maxRetained + " ms" }
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            Canvas {
              id: livePlot
              width: parent.width
              height: Style.space(120)
              onPaint: root.paintPlot(getContext("2d"), width, height, true)
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.wouldDoubleAtCurrent > 0 ? Color.urgent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: {
                root.tick
                if (root.dwells.length === 0)
                  return "Every keystroke lands here as you type."
                if (root.wouldDoubleAtCurrent === 0)
                  return "Nothing has crossed your current " + root.currentDelay +
                         " ms limit yet."
                return root.wouldDoubleAtCurrent + " of " + root.dwells.length +
                       " keystrokes crossed " + root.currentDelay +
                       " ms — each of those doubles a character today."
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(4)
              color: Color.menu.selectedBackground
              radius: height / 2

              Rectangle {
                height: parent.height
                width: parent.width * Math.min(1, root.typed.length / root.prompt.length)
                color: Color.accent
                radius: height / 2
                Behavior on width { NumberAnimation { duration: 90 } }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dwells.length >= root.minSamples ? Color.accent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              text: {
                root.tick
                if (root.dwells.length >= root.minSamples)
                  return "Ctrl+Enter to finish now  ·  Esc to cancel"
                return "Type " + (root.minSamples - root.dwells.length) +
                       " more to enable Ctrl+Enter to finish early  ·  Esc to cancel"
              }
            }
          }

          // ================= REVIEW =================

          Column {
            visible: root.phase === "review"
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              lineHeight: 1.35
              text: {
                root.tick
                return "Every keystroke you just made, by how long you held it. Anything to the " +
                       "right of the line doubles. Your current setting of " + root.currentDelay +
                       " ms would have doubled " + root.wouldDoubleAtCurrent + " of these " +
                       root.dwells.length + " keystrokes."
              }
            }

            Canvas {
              id: plot
              width: parent.width
              height: Style.space(190)
              onPaint: root.paintPlot(getContext("2d"), width, height, false)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeHorCursor
                onPressed: function (m) { root.setChosenFromX(m.x, plot.width); plot.requestPaint() }
                onPositionChanged: function (m) { if (pressed) { root.setChosenFromX(m.x, plot.width); plot.requestPaint() } }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.huge

              Column {
                spacing: Style.spacing.xxs
                Text {
                  text: "Suggested"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: root.suggestedDelay + " ms"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                }
              }

              Column {
                spacing: Style.spacing.xxs
                Text {
                  text: "You chose"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: root.chosenDelay + " ms"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }

              Column {
                spacing: Style.spacing.xxs
                Text {
                  text: "Would double"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: {
                    root.tick
                    return root.wouldDoubleAtChosen === 0
                      ? "none of " + root.dwells.length
                      : root.wouldDoubleAtChosen + " of " + root.dwells.length
                  }
                  color: root.wouldDoubleAtChosen === 0 ? Color.accent : Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                }
              }

              Column {
                spacing: Style.spacing.xxs
                Text {
                  text: "Headroom"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: { root.tick; return (root.chosenDelay - root.maxRetained) + " ms" }
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                }
              }
            }

            Text {
              visible: root.rejectedHolds > 0 || root.chatterNoRelease > 0 || root.chatterRebound > 0
              width: parent.width
              wrapMode: Text.WordWrap
              color: (root.chatterNoRelease + root.chatterRebound) > 0 ? Color.urgent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: {
                root.tick
                var parts = []
                if (root.rejectedHolds > 0)
                  parts.push(root.rejectedHolds + " held key" + (root.rejectedHolds === 1 ? "" : "s") +
                             " excluded — a hold is not a keystroke")
                if (root.chatterNoRelease + root.chatterRebound > 0)
                  parts.push("hardware chatter detected (" + (root.chatterNoRelease + root.chatterRebound) +
                             " events) — no repeat delay can fix a failing switch")
                return parts.join(".  ")
              }
            }

            Rectangle { width: parent.width; height: 1; color: Color.menu.border; opacity: 0.5 }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: "Drag the line, or ←/→ to adjust (Shift for 50 ms).  " +
                    "S resets to the suggestion.  R retests."
            }

            Rectangle {
              width: parent.width
              height: confirmRow.implicitHeight + Style.space(22)
              color: Color.menu.selectedBackground
              radius: Style.cornerRadius
              border.width: Math.max(1, Style.space(1))
              border.color: Color.accent

              Text {
                id: confirmRow
                anchors.centerIn: parent
                width: parent.width - Style.space(28)
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                text: "Press Enter to set repeat_delay to " + root.chosenDelay + " ms"
              }
            }

            Text {
              text: "This writes to ~/.config/hypr/input.lua.  Esc leaves everything unchanged."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ================= DONE =================

          Column {
            visible: root.phase === "done"
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              text: "repeat_delay is now " + root.chosenDelay + " ms"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              lineHeight: 1.35
              text: "Written to ~/.config/hypr/input.lua in a managed block. Re-running this " +
                    "wizard replaces that block rather than adding another. To undo it by hand, " +
                    "delete the block and reload Hyprland."
            }

            Text {
              visible: root.applyResult !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.muted
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              text: root.applyResult
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: "One session is a small sample — your slowest keystroke today may not be " +
                    "your slowest tomorrow. Running this again on another day gives a better " +
                    "picture of the tail."
            }

            Text {
              text: "R to test again      ·      Enter to finish"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }

  // ---- rendering helpers ------------------------------------------------

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/\n/g, "<br>").replace(/ /g, "&nbsp;")
  }

  function renderTyped() {
    tick
    if (typed.length === 0)
      return "<span style='color:" + Color.muted + "'>…</span>"
    var out = ""
    for (var i = 0; i < typed.length; i++) {
      var ok = typed[i] === prompt[i]
      var ch = esc(typed[i])
      out += "<span style='color:" + (ok ? Color.menu.text : Color.urgent) + "'>" + ch + "</span>"
    }
    return out + "<span style='color:" + Color.accent + "'>|</span>"
  }

  // ---- plot -------------------------------------------------------------

  readonly property int plotMaxMs: Math.max(700, chosenDelay + 120, maxRetained + 120)

  function msToX(ms, w) {
    var padL = Style.space(8), padR = Style.space(8)
    return padL + (ms / plotMaxMs) * (w - padL - padR)
  }

  function setChosenFromX(x, w) {
    var padL = Style.space(8), padR = Style.space(8)
    var ms = (x - padL) / (w - padL - padR) * plotMaxMs
    chosenDelay = Math.max(100, Math.min(1500, Math.round(ms / 10) * 10))
  }

  function paintPlot(ctx, w, h, live) {
    ctx.reset()
    var base = h - Style.space(24)

    // bins
    var binMs = 20
    var nBins = Math.ceil(plotMaxMs / binMs)
    var bins = []
    for (var i = 0; i < nBins; i++) bins.push(0)
    for (i = 0; i < dwells.length; i++) {
      var b = Math.min(nBins - 1, Math.floor(dwells[i] / binMs))
      bins[b]++
    }
    var peak = 1
    for (i = 0; i < bins.length; i++) if (bins[i] > peak) peak = bins[i]

    // baseline
    ctx.strokeStyle = String(Color.menu.border)
    ctx.lineWidth = 1
    ctx.beginPath(); ctx.moveTo(0, base); ctx.lineTo(w, base); ctx.stroke()

    // bars — red once past the chosen threshold
    for (b = 0; b < nBins; b++) {
      if (bins[b] === 0) continue
      var x0 = msToX(b * binMs, w)
      var x1 = msToX((b + 1) * binMs, w)
      var bh = (bins[b] / peak) * (base - Style.space(14))
      ctx.fillStyle = String((b * binMs) >= (live ? currentDelay : chosenDelay) ? Color.urgent : Color.accent)
      ctx.fillRect(x0, base - bh, Math.max(1, x1 - x0 - 1), bh)
    }

    // current setting — dashed, muted
    var xc = msToX(currentDelay, w)
    ctx.strokeStyle = String(Color.muted)
    ctx.setLineDash([4, 3])
    ctx.beginPath(); ctx.moveTo(xc, 0); ctx.lineTo(xc, base); ctx.stroke()
    ctx.setLineDash([])
    ctx.fillStyle = String(Color.muted)
    ctx.font = Style.font.caption + "px sans-serif"
    ctx.fillText("current " + currentDelay, xc + 4, 11)

    if (live) {
      // Live view: the current limit is the whole story. No handle, no
      // suggestion — the sample is still being collected.
      ctx.fillStyle = String(Color.muted)
      ctx.font = Style.font.caption + "px sans-serif"
      for (var lms = 0; lms <= plotMaxMs; lms += 200)
        ctx.fillText(String(lms), msToX(lms, w) - 8, h - Style.space(6))
      return
    }

    // suggestion — faint tick
    var xs = msToX(suggestedDelay, w)
    ctx.strokeStyle = String(Color.muted)
    ctx.globalAlpha = 0.5
    ctx.beginPath(); ctx.moveTo(xs, base - Style.space(8)); ctx.lineTo(xs, base); ctx.stroke()
    ctx.globalAlpha = 1

    // the chosen line — the thing the user moves
    var xh = msToX(chosenDelay, w)
    ctx.strokeStyle = String(Color.accent)
    ctx.lineWidth = 2
    ctx.beginPath(); ctx.moveTo(xh, 0); ctx.lineTo(xh, base + Style.space(5)); ctx.stroke()
    ctx.fillStyle = String(Color.accent)
    ctx.beginPath()
    ctx.moveTo(xh - 5, base + Style.space(5))
    ctx.lineTo(xh + 5, base + Style.space(5))
    ctx.lineTo(xh, base)
    ctx.closePath(); ctx.fill()
    ctx.fillText(chosenDelay + " ms", xh + 6, 24)

    // axis
    ctx.fillStyle = String(Color.muted)
    for (var ms = 0; ms <= plotMaxMs; ms += 200) {
      var x = msToX(ms, w)
      ctx.fillText(String(ms), x - 8, h - Style.space(6))
    }
  }
}
