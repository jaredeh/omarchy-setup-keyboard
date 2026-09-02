// dwell-probe.qml — hello-world scale spike for Dwell-Time Calibration.
//
// Proves the four things the design rests on, and nothing else:
//
//   1. Key RELEASE events reach a Quickshell layer-shell overlay at all.
//   2. Press/release can be paired by nativeScanCode into a dwell time.
//   3. Qt's synthetic autorepeat is distinguishable (isAutoRepeat, press-only).
//   4. Whether QML's KeyEvent exposes a real `timestamp`, or we're stuck with
//      Date.now() — the one open question that decides if a C++ plugin is needed.
//
// Run it in a terminal so you can see the log:
//
//   qs -p ./spike/dwell-probe.qml
//
// Focus is OnDemand, not Exclusive: it will not touch your keyboard until you
// click the overlay. Escape quits, and it hard-quits itself after 120s.

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
  id: root

  // ---- measurement state -------------------------------------------------

  property var downAt: ({})     // scancode -> press time
  property var upAt: ({})       // scancode -> last release time
  property var dwells: []       // every completed dwell sample, ms

  property int repeatsFiltered: 0   // synthetic autorepeat events discarded
  property int orphanPress: 0       // press with no intervening release  → chatter
  property int fastRebound: 0       // release→press < 20ms, same key     → chatter
  property int tick: 0              // bump to invalidate display bindings

  // ---- probe results (question 4) ---------------------------------------

  property bool probed: false
  property string tsVerdict: "waiting for first keystroke…"
  property string scanVerdict: ""

  readonly property int maxDwell: {
    tick
    if (dwells.length === 0) return 0
    var m = 0
    for (var i = 0; i < dwells.length; i++) if (dwells[i] > m) m = dwells[i]
    return m
  }

  function percentile(p) {
    if (dwells.length === 0) return 0
    var s = dwells.slice().sort(function (a, b) { return a - b })
    return s[Math.min(s.length - 1, Math.floor(s.length * p))]
  }

  // Answer question 4 once, off the first event we see.
  function probeEvent(event) {
    if (probed) return
    probed = true
    var t = event.timestamp
    if (typeof t === "number" && t > 0) {
      tsVerdict = "KeyEvent.timestamp IS available (" + t + ") — use it, not Date.now()"
    } else {
      tsVerdict = "KeyEvent.timestamp NOT available (" + typeof t + ") — Date.now() it is"
    }
    var sc = event.nativeScanCode
    scanVerdict = (typeof sc === "number" && sc > 0)
      ? "nativeScanCode IS available (" + sc + ") — per-key attribution works"
      : "nativeScanCode NOT usable (" + typeof sc + ") — fall back to event.key"
  }

  function onPress(event) {
    probeEvent(event)

    if (event.isAutoRepeat) {
      repeatsFiltered++
      tick++
      return
    }

    var scan = event.nativeScanCode || event.key
    var t = Date.now()

    // Chatter signature A: pressed again with no release in between.
    if (downAt[scan] !== undefined) {
      orphanPress++
      console.log("CHATTER? press-without-release scan=" + scan)
    }

    // Chatter signature B: released and re-pressed almost instantly.
    if (upAt[scan] !== undefined) {
      var gap = t - upAt[scan]
      if (gap < 20) {
        fastRebound++
        console.log("CHATTER? rebound scan=" + scan + " gap=" + gap + "ms")
      }
    }

    downAt[scan] = t
    tick++
  }

  function onRelease(event) {
    if (event.isAutoRepeat) {
      // Qt should never emit these — a synthetic repeat is press-only.
      // If this fires, the filtering assumption in the design is wrong.
      repeatsFiltered++
      console.log("UNEXPECTED: autorepeat on RELEASE — design assumption broken")
      tick++
      return
    }

    var scan = event.nativeScanCode || event.key
    if (downAt[scan] === undefined) return

    var t = Date.now()
    var dwell = t - downAt[scan]
    delete downAt[scan]
    upAt[scan] = t

    dwells.push(dwell)
    console.log("dwell scan=" + scan + " " + dwell + "ms  n=" + dwells.length)
    tick++
  }

  function histogram() {
    tick
    if (dwells.length === 0) return "   (type something)"
    var bins = []
    for (var i = 0; i < 26; i++) bins.push(0)
    for (i = 0; i < dwells.length; i++) bins[Math.min(25, Math.floor(dwells[i] / 20))]++

    var peak = 1
    for (i = 0; i < bins.length; i++) if (bins[i] > peak) peak = bins[i]

    var lastBin = Math.min(25, Math.floor(maxDwell / 20))
    var out = []
    for (var b = 0; b <= lastBin; b++) {
      var lo = ("   " + (b * 20)).slice(-4)
      var hi = ((b + 1) * 20 + "    ").slice(0, 4)
      var bar = "█".repeat(Math.round(bins[b] / peak * 34))
      var over = (b * 20) >= 250 ? "  ← would double at 250ms" : ""
      out.push(lo + "–" + hi + " " + bar + (bins[b] ? " " + bins[b] : "") + over)
    }
    return out.join("\n")
  }

  function summarize() {
    console.log("──────── dwell-probe summary ────────")
    console.log(tsVerdict)
    console.log(scanVerdict)
    console.log("samples=" + dwells.length +
                "  max=" + maxDwell + "ms" +
                "  p50=" + percentile(0.5) + "ms" +
                "  p95=" + percentile(0.95) + "ms")
    console.log("autorepeat filtered=" + repeatsFiltered +
                "  chatter(press-without-release)=" + orphanPress +
                "  chatter(rebound<20ms)=" + fastRebound)
    if (dwells.length > 0)
      console.log("would need repeat_delay > " + maxDwell + "ms to never double")
  }

  PanelWindow {
    id: win

    anchors { top: true; bottom: true; left: true; right: true }
    color: "#f00E1413"

    WlrLayershell.namespace: "dwell-probe"
    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand, not Exclusive: this spike must never trap the user's keyboard.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // Safety net. An input overlay that can't be escaped is a bug, not a test.
    Timer {
      interval: 120000
      running: true
      onTriggered: { root.summarize(); Qt.quit() }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: catcher.forceActiveFocus()
    }

    FocusScope {
      id: catcher
      anchors.fill: parent
      focus: true

      // Layer-shell hands focus to the SURFACE, but Qt still needs an
      // active-focus ITEM before Keys.* fires. Schedule it after map.
      Component.onCompleted: Qt.callLater(function () { catcher.forceActiveFocus() })

      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          root.summarize()
          Qt.quit()
          event.accepted = true
          return
        }
        root.onPress(event)
        event.accepted = true
      }

      Keys.onReleased: function (event) {
        root.onRelease(event)
        event.accepted = true
      }

      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 760)
        spacing: 18

        Text {
          text: "dwell-probe"
          color: "#2FBFAB"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 26
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          color: catcher.activeFocus ? "#94A2A0" : "#E0705A"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 13
          text: catcher.activeFocus
            ? "Type naturally. Pause mid-word sometimes — hesitation is where the tail lives.\nEsc quits and prints the summary. Auto-quits after 120s."
            : "CLICK ANYWHERE to give this overlay keyboard focus."
        }

        Rectangle { width: parent.width; height: 1; color: "#26302E" }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          color: "#E4EAE8"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 13
          text: root.tsVerdict + "\n" + root.scanVerdict
        }

        Rectangle { width: parent.width; height: 1; color: "#26302E" }

        Text {
          color: "#E4EAE8"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 14
          text: {
            root.tick
            return "samples " + root.dwells.length +
                   "   max " + root.maxDwell + "ms" +
                   "   p50 " + root.percentile(0.5) + "ms" +
                   "   p95 " + root.percentile(0.95) + "ms"
          }
        }

        Text {
          color: "#8B9897"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 12
          text: {
            root.tick
            return "autorepeat filtered " + root.repeatsFiltered +
                   "    chatter: no-release " + root.orphanPress +
                   ", rebound " + root.fastRebound
          }
        }

        Text {
          color: "#2FBFAB"
          font.family: "JetBrains Mono, monospace"
          font.pixelSize: 12
          lineHeight: 1.25
          text: root.histogram()
        }
      }
    }
  }
}
