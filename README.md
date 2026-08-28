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

Requires Xcode (or the Command Line Tools) — it's a plain SwiftPM package, no
Xcode project. No Accessibility / Input Monitoring permission is needed.

## Use

| Action | How |
| --- | --- |
| Draw a line | Hold ⇧, click-drag, release |
| Move a line | Hold ⇧, drag an existing line (cursor turns into a hand) |
| Undo last line | **Double-tap ⇧**, menu-bar ╱ → *Undo Last Line*, or **⌃⌥⌘Z** anywhere |
| Clear all lines | **Triple-tap ⇧**, menu-bar ╱ → *Clear All Lines*, or **⌃⌥⌘C** anywhere |
| Pause (make ⇧-clicks reach apps again) | Menu-bar ╱ → uncheck *Enabled* |
| Use a different key | Menu-bar ╱ → *Draw While Holding* |
| Change how new lines look | Menu-bar ╱ → *Color* / *Thickness* / *Style* |

Each line keeps the colour, thickness and style it was drawn with, so changing
the settings only affects the next line and you can mix, say, red solid guides
with blue dashed ones. *Color → Custom…* opens the system colour picker (alpha
included). Thickness goes from a ½ pt hairline to 4 pt; horizontal and vertical
lines are pixel-snapped so they render crisp on Retina displays. Settings are
remembered between launches.

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
