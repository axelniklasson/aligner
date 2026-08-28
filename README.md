# Aligner

A tiny macOS menu-bar app for eyeballing alignment in any app: hold **⇧ Shift**,
then click-and-drag anywhere on screen to draw a red guide line. Lines snap to
0° / 45° / 90° (like Preview) and stay on screen — on top of everything, across
all Spaces and full-screen apps — until you double-tap ⇧ to undo the last one
or triple-tap ⇧ to clear them all.

## Build & run

```sh
./build.sh run       # builds build/Aligner.app and launches it
./build.sh install   # …or copy it to /Applications and launch from there
```

Requires macOS 14+ and Xcode (or the Command Line Tools) — it's a plain
SwiftPM package, no Xcode project. No Accessibility / Input Monitoring
permission is needed; *Snap to Elements* needs Screen Recording (see below).

## Use

| Action | How |
| --- | --- |
| Draw a line | Hold ⇧, click-drag, release |
| Move a line | Hold ⇧, drag an existing line (cursor turns into a hand) |
| Extend / shorten / re-angle a line | Hold ⇧, hover the line, drag one of its endpoint handles — the other end stays put. Keep holding ⇧ to snap the dragged end to 0/45/90°, or release ⇧ mid-drag to move it freely (capture stays on until you let go of the mouse) |
| Stretch a line across the screen | Hold ⇧, double-click the line |
| Snap to elements on screen | On by default (needs Screen Recording access, see below); hold ⌘ mid-drag to skip snapping |
| Undo last line | **Double-tap ⇧**, menu-bar ╱ → *Undo Last Line*, or **⌃⌥⌘Z** anywhere |
| Clear all lines | **Triple-tap ⇧**, menu-bar ╱ → *Clear All Lines*, or **⌃⌥⌘C** anywhere |
| Pause (make ⇧-clicks reach apps again) | Menu-bar ╱ → uncheck *Enabled* |
| Use a different key | Menu-bar ╱ → *Draw While Holding* |
| See this list in the app | Menu-bar ╱ → *Help* |
| Change how new lines look | Menu-bar ╱ → *Color* / *Thickness* / *Style* |

Each line keeps the colour, thickness and style it was drawn with, so changing
the settings only affects the next line and you can mix, say, red solid guides
with blue dashed ones. *Color → Custom…* opens the system colour picker (alpha
included). Thickness goes from a ½ pt hairline to 4 pt; horizontal and vertical
lines are pixel-snapped so they render crisp on Retina displays. Settings are
remembered between launches.

## Snap to elements

While you draw, move, or reshape a line, Aligner looks at the pixels of the
screen you're on and snaps to element edges within ~6 pt: the anchor of a new
line snaps to the nearest horizontal/vertical edge (click near a corner and you
get the corner), an axis-aligned line being moved snaps to parallel edges, and
a dragged end snaps to the edge it's about to cross. The edge you snapped to is
highlighted in cyan along its whole detected extent so you can see what you're
aligned with. Lines are placed *just outside* the edge, on the side you
approached from, so they never cover the pixels you're checking.

Edges are found by looking for a consistent luminance step across a 60 pt
stretch of a pixel boundary: text and noise don't qualify, gradients and soft
shadows are rejected as plateaus, and anti-aliased edges, hairlines and thin
borders are kept. Only the display you're drawing on is captured, once per
mouse-down (plus while you hover), and nothing is stored.

**Permission.** This needs *Screen Recording* — Aligner asks on first launch and
appears under System Settings → Privacy & Security → Screen & System Audio
Recording. Relaunch after granting. Without it everything else keeps working
and the menu item reads *Snap to Elements — Needs Screen Recording Access…*.

**Keeping the permission across rebuilds.** macOS ties the grant to the app's
code signature, and an ad-hoc signature changes with every build, so a rebuilt
Aligner has to be re-granted. To avoid that, create a self-signed certificate
once: Keychain Access → Keychain Access menu → Certificate Assistant → Create a
Certificate…, name **Aligner Dev**, Identity Type *Self-Signed Root*,
Certificate Type *Code Signing*. `build.sh` finds it automatically (or set
`ALIGNER_SIGN_IDENTITY` to any other identity's name). Grant the permission
once more after the first signed build.

## How it works

One transparent, borderless, non-activating `NSPanel` per screen sits at the
screen-saver window level and ignores mouse events. A 60 Hz timer reads the
hardware modifier state via `CGEventSource.flagsState` (no permissions
required); while the chosen modifier is the *only* modifier held, the panels
stop ignoring mouse events and capture the drag. Committed lines are stored in
global screen coordinates so they survive display changes.

## Caveats

- While the app is *Enabled* and ⇧ is held, ⇧-clicks and ⇧-scrolls go to the
  overlay instead of the app underneath. Switch the modifier (e.g. ⌥⇧) or
  uncheck *Enabled* if that gets in the way.
- Drawing mode needs the chosen modifier to be the only one held, so ⌘⇧
  shortcuts keep working.
- A ⇧ tap only counts towards a double/triple-tap if no key, click or scroll
  happened while it was down, so typing "PR" won't touch your lines. Each tap
  must be under 0.35 s with under 0.4 s between taps. A triple-tap undoes on
  the second tap and clears on the third, so there's no delay waiting to see
  whether a third tap is coming. (JetBrains IDEs also use double-⇧ for *Search
  Everywhere*; that will undo a line too.)
- To start it at login, add `Aligner.app` under *System Settings → General →
  Login Items*.

## Debugging

```sh
ALIGNER_DEBUG=1 ALIGNER_DEBUG_DUMP=/tmp/overlay.png ./build/Aligner.app/Contents/MacOS/Aligner
```

`ALIGNER_DEBUG` logs capture/mouse events to stderr and runs a self-test that
asks the window server which window would receive a click with capture on and
off. `ALIGNER_DEBUG_DUMP` additionally draws three sample lines and renders the
first overlay to a PNG, which is handy because `screencapture` without Screen
Recording permission silently returns only the wallpaper.
`ALIGNER_DEBUG_CAPTURE=/tmp/luma.png` captures the main display through the
snapping pipeline (overlay excluded), writes the luminance image, and logs the
edges found along the screen's centre lines.
