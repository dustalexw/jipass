# jipass — native Mac edition

A SwiftUI port of jipass. The window, category browser, four-answer grid, playback, scoring,
profiles, history, image controls and settings run natively. There is no Python process,
web view, HTTP server, port or browser at runtime.

## Download

Get the Apple Silicon build from the [latest GitHub release](https://github.com/dustalexw/jipass/releases/latest).
Unzip it, move `jipass.app` to Applications, and open it. Requires macOS 13+ and FFmpeg
(`brew install ffmpeg`). This release is ad-hoc signed, not notarized. Intel users can
build from source on their own Mac.

The downloadable app uses `~/Library/Application Support/jipass` for its local data.
It starts with an empty library: add your mounted music folders, or enable Demo in Settings.
To import an existing browser collection, copy its `needle.sqlite3`, `artist-photos/`, and
`category-images/` into that folder **before the first native launch**. Native state is
imported once and saved separately. No personal data is included in the release.

## Build and open

Requires macOS 13+, Xcode's Swift toolchain and FFmpeg (`brew install ffmpeg`).

```sh
./Native/build.sh open
```

The script builds a release `.app` at `Native/build/jipass.app`, gives it an ad-hoc signature,
and opens it. The current build targets the Mac's own architecture. No download or
installation is performed by the build script.

Double-click the app afterward, or drag it to the Dock. Keep FFmpeg and ffprobe installed
in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` or `/usr/bin`.

## Your existing library

The locally built app uses this checkout's `data/` folder, stored as an absolute path in its
Info.plist so moving the `.app` does not lose the library. On first native launch it reads
`needle.sqlite3` in **read-only mode**, importing tracks, folders, memberships, profiles,
completed rounds, and custom category image references. Existing photo caches are reused.
It writes separate native state to `native-state.json` atomically. It does not write to the
old SQLite database or synchronize later browser changes; the browser version remains available.
Back up the complete `data/` folder with both apps closed.

`JIPASS_DATA=/absolute/path` overrides the data directory when launching the executable.
If there is no bundled path or override (for example `swift run`), the default is
`~/Library/Application Support/jipass`. To migrate on another computer, put the old database
and image folders in that directory before the first launch. A first launch without an old
database creates an empty local library. Add folders using the native folder picker.

## Playing

Choose Genres, Artists or Mixed library. Artist categories use title questions. Genre and
mixed-library rounds can alternate title and artist questions when each has four valid
choices. All distractors come from the same local source. Configure 5/10/15 questions and
5/10/15-second clips. The app skips corrupt or unavailable tracks and never repeats a track
in a round. If too few playable tracks remain, the results show the completed questions.

FFmpeg prepares stripped-metadata WAV clips. AVAudioPlayer starts playback automatically.
A monotonic clock starts only after `play()` succeeds; pausing does not stop it. Answer
with the 2×2 buttons or keys 1–4. Return continues after a reveal. One submission is accepted
per question. Correct answers earn `500 + round(500 × (1 − elapsed / duration))`; wrong answers
and timeouts earn zero. Album art is extracted only after an answer or timeout.

History saves each submitted question, including unfinished rounds. Personal bests compare
player, source, question mode, requested round length and clip duration.

## Settings and images

Open the gear button or press ⌘,. Demo is available only here and is off on first launch.
The demo contains locally generated original sketches. **BIG CHIEF'M (Debug)** enables
artist and genre image uploads and reset controls. Choose a local file, confirm its preview,
and save. The native store independently requires Debug mode. Uploaded images persist when
Debug is off. JPEG/PNG/WebP up to 8 MB and 40 megapixels are re-encoded as local JPEGs.

Automatic artist photos use artist-name-only Wikipedia/Wikimedia lookups with exact music-page
matching and local caches. Credits appear in Settings. Existing artist photos, including
custom replacements, are kept. Collaboration labels may use the lead artist's photo.
No music, NAS paths or gameplay records are transmitted. Album art is local only.

## Checks

```sh
./Native/test.sh
```

Focused Swift tests cover answer generation, library-only distractors, scoring boundaries,
monotonic timer gating, duplicate submissions, complete round flow with a deterministic playback driver (actual audio output is checked in the app), no repeated tracks,
mixed question alternation, persistence, read-only legacy import, image editing gates,
incremental and overlapping scans, offline roots, corrupt files and real FFmpeg clips.

The original browser implementation and its tests are retained for compatibility. Native
state is a separate JSON snapshot; large libraries are loaded in memory. Scans are manual.
The app is for casual local play, with local profiles rather than authentication. It is
ad-hoc signed for local use, not notarized or distributed through the Mac App Store.

## Release packaging

`./Native/release.sh` builds and signs a ZIP for the current architecture, removes the
development data path, and creates SHA-256 checksums in `Native/build/release/`.
Only the `.app` is packaged; the local library and caches are never included.
