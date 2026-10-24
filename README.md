# jipass

An original music trivia game that runs entirely on your computer. A Python standard-library server handles metadata, clips, answers, scoring, and SQLite persistence. A buildless browser interface serves directly from it. Music files, library indexing, gameplay, and scores stay local. Artist photos use artist-name-only lookups on Wikipedia/Wikimedia Commons, then are cached locally. No music, paths, credentials, or gameplay data is sent. No browser CDN, telemetry, account, or API key is used.

## Launch

Requires **Python 3.9+** and **FFmpeg with ffprobe** on your PATH. Both were detected in the development environment. On macOS, FFmpeg can be installed with `brew install ffmpeg`; on Debian/Ubuntu use `sudo apt install ffmpeg`.

From this folder, run one command:

```sh
python3 app.py
```

Open **http://127.0.0.1:8765**. First launch generates 18 short original melodic sketches locally; these are clearly marked **Demo mode** and are not recognizable commercial songs. The game opens on your own library by default. To try the demo before connecting your NAS, open **Settings** with the gear button at the top right and enable **Demo mode**. Create a player, choose a category, and start playing. Demo genres have six tracks each, so choose a five-question round for a single demo genre. Mixed demo supports all round lengths.

## Connect your NAS

Mount your SMB/NFS share using your operating system. Keep its credentials in the OS credential manager; jipass neither accepts nor stores NAS passwords. In **Library settings**, enter a mounted folder path and click **Add folder**. Repeat for each folder, then click **Rescan all folders**. Each saved folder also has its own **Rescan** and **Remove** buttons. Removing a folder only removes index entries exclusive to it; it never deletes music or scores. Existing single-folder settings migrate automatically on restart. Leave **Demo mode** off in Settings to play your own library. It must be readable by the user running Python. Examples:

- macOS: `/Volumes/Music`
- Linux: `/mnt/nas/music`
- Windows: `Z:\Music` (run Python in an environment where that drive is mounted)

Alternatively configure the backend with an environment variable:

```sh
NEEDLE_MUSIC_DIR="/Volumes/Music" python3 app.py
```

For multiple environment-managed folders, use a JSON array (this takes precedence over `NEEDLE_MUSIC_DIR`):

```sh
NEEDLE_MUSIC_DIRS='["/Volumes/Music/Artist A", "/Volumes/OtherMusic"]' python3 app.py
```

Environment-managed folders appear in Library settings but cannot be added or removed there. Click **Rescan all folders** to index them. Paths must be absolute mounted directories; up to 50 folders are supported. Folders can overlap: canonical file paths are deduplicated, and removing a parent folder preserves tracks still covered by another saved folder. Offline folders retain their indexed tracks while other folders continue scanning.

Other optional variables:

```sh
NEEDLE_PORT=8766 NEEDLE_DATA="/path/to/local/needle-data" python3 app.py
```

`NEEDLE_DATA` defaults to `data/` beside the app. Put it on the local computer to keep scores and clip preparation off the NAS. Do not include it in version control or share it: it contains library paths and gameplay records. Back up `data/needle.sqlite3` while the server is stopped to preserve profiles and history. The original music is read-only.

## Mixed question types

In Genre mode, choose **Mixed: artist + song title** under **I’m guessing** (the default). Questions alternate between song title and artist when both can offer four distinct answers from the same source library. Each question clearly labels what to identify. The backend controls the selected type, answers, timer, and scoring.

If only one type is possible, the game uses it and shows a notice. Artist questions require at least four distinct known artist labels across that source library; demo and NAS artists never mix to fill answers. Adding another artist folder and scanning can unlock artist questions. Artist-specific categories continue to use song-title questions.

## Artist categories

With **Demo mode** off, choose **Artists** to browse or search artists from indexed metadata. Select an artist to play song-title questions from their tracks; the question type is locked because the artist is already known. Wrong song titles prefer that artist, then the same genre, then the rest of the selected source library. Artists need at least five eligible tracks. Missing artist tags are excluded; case and whitespace variants are grouped. Collaboration tags remain their own categories. Choose Mixed library or switch back to Genres for other modes.

After upgrading from an older version, stop the running server with Control+C, run `python3 app.py` again, and refresh the browser. No rescan is needed for artist categories.

## Game rules

- Guess song titles or artists from four distinct labels, all drawn from the chosen source library. Distractors prefer the same genre, then fall back to the rest of that source library. Demo and NAS songs never mix.
- A category needs enough eligible tracks for the requested round. At least four distinct titles/artists must exist in the source library. Missing artist tags cannot serve as artist questions or distractors. Duplicate labels are matched without case/extra whitespace.
- Genre tags are used as supplied (one category per full tag). Missing genre = Uncategorized; missing title = filename; missing album/artist = Unknown album/artist.
- Random clips avoid the first/last ten seconds when space allows. Short tracks use safe margins and shorter clips. Tracks do not repeat in a round; corrupt tracks are skipped in favor of remaining candidates.
- Each clip starts automatically when ready. If your browser blocks autoplay, press **Play** to enable audio and begin. The browser waits for playable audio and successful playback, then activates the backend clock. Pausing never pauses the clock. The server controls elapsed time and accepts one result per question. Correct answers stay on the backend until submission/timeout.
- Correct, before timeout: **500 + round(500 × (1 − response seconds ÷ clip seconds))**. Incorrect or timeout: **0**. Each question reveals the song, artist, album, elapsed time, and earned points, with animated correct/incorrect states, a speed bonus breakdown, and a correct-answer streak. Short locally synthesized feedback tones follow the volume control. You can also answer with number keys 1–4.
- Personal bests compare rounds with the same source, question type, requested round length, and clip length; genres may differ. Average response includes timeouts at their full deadline.

## Indexing and storage

A manual rescan compares file size and nanosecond modification time; unchanged files are not probed again. FFprobe extracts metadata and duration. FFmpeg decodes clips to stripped-metadata mono WAV, so formats need not be supported natively by the browser. Supported extensions include MP3, FLAC, M4A, AAC, Ogg, Opus, WAV, AIFF, WMA, ALAC, APE, and MP4 with audio. Actual decoder support depends on your FFmpeg build. Files under three seconds or without a usable duration are skipped. Symlink files outside the root are skipped. Overlapping roots are supported without duplicate track entries. Scan counts describe file checks across folders, so an overlapping file may contribute to more than one unchanged count even though the collection contains it only once.

Unavailable folders retain the existing index and report an error. Removal pruning happens only after a complete folder traversal. An incomplete/disconnected traversal retains indexed rows; an unplayable row is skipped during round preparation. Rescanning never alters source files. Scans run in the background; UI status reports counts and up to 30 file errors.

Generated clips are local temporary files. They are removed on restart, and old clips are cleaned while running. Profiles, round snapshots, scores, and completed history persist in SQLite. Abandoned rounds retain their submitted answers but cannot be resumed. History displays the latest 20 completed rounds across all profiles, filtered to the selected player in the UI.

## Settings and custom artist/genre images

Open **Settings** with the gear button at the top right. Demo mode is available only in this window, and is off by default. Settings persist locally. You cannot switch music sources in the middle of a round; finish or leave it first. The question clock continues if you open Settings during playback.

To change a card image:

1. Enable **BIG CHIEF'M (Debug)** in Settings.
2. Close Settings and choose **Artists** or **Genres**.
3. Click **Change image** under a named category card.
4. Choose a JPEG, PNG, or WebP image, check its preview, and click **Save image**.
5. Optionally turn Debug off again; the uploaded image remains visible.

The server rejects uploads and image resets unless Debug is enabled. This is a local editing switch, not an authentication system. Files must be smaller than 8 MB and below 40 megapixels. The backend decodes and re-encodes the first frame as a JPEG up to 1200 pixels per side, strips metadata, and stores it under `data/category-images/`. It never alters the source music or sends the image externally. **Reset image** restores the automatic artist photo or the genre’s original graphic. Demo categories can also receive local images while Debug is enabled. Mixed library uses the original record graphic.

Image URLs carry a version that changes with each new upload or cache replacement. Browsers therefore display updates immediately instead of retaining a previous photo. Automatic artist images also use versioned URLs and revalidation. Back up `data/category-images/` alongside the SQLite database to preserve your uploaded pictures.

## Artist card photos

Real artist cards show photos from exact Wikipedia music-artist pages, with monogram fallbacks when no match is available. Downloads use Wikimedia hosts only and are converted to local JPEGs under `data/artist-photos/`. Cached photos work offline. The browser requests only local image URLs. Lookups are lazy, and fictional demo artists do not trigger them. Artist names are the only library metadata sent for these lookups.

Expand **Artist photo credits** below the cards for the photographer, license, photo source, and license link. Collaboration tags without their own matching page may use the lead artist’s photo; those cards say **Lead artist photo**, and the credits identify the match. Missing matches are cached for one day, while temporary network failures retry after five minutes. Delete both an artist’s JPG and JSON cache files to force a new lookup.

## Local album artwork

After an answer or timeout, the record graphic changes to the album cover, with a thumbnail in the feedback and round results. Covers never appear during the guessing stage. The server issues an opaque artwork URL only after resolution; audio clips remain stripped of cover art and metadata.

Artwork is extracted from an embedded attached picture first, falling back to a conventional image in the same album directory: `cover`, `folder`, `front`, `album`, or `artwork`, with JPG, JPEG, PNG, or WebP extensions (case-insensitive). Folder images must be at most 20 MB and remain in the same directory. Output is a stripped-metadata JPEG up to 600 pixels per side, cached locally under `data/artwork/`. Artwork references persist with history. No internet artwork lookup is performed. Missing or unreadable artwork shows a styled placeholder and does not affect scores. Demo sketches do not contain album covers. Already-completed rounds from older versions have no artwork references.

## Checks

```sh
python3 -m unittest discover -s tests -v
node --test tests/test_ui.cjs
```

The 31 Python tests include a complete HTTP round with real FFmpeg clips, idempotent submissions, timeout handling, history persistence, and cross-origin rejection. They also cover source-only choices, same-genre preference, duplicate labels, insufficient distractors, missing artists, scoring boundaries, server timer gating, deadlines and duplicate submissions, hidden answers, random clip boundaries, incremental scans, disconnected roots, removal, corrupt files, untagged WAV metadata, multiple folders and overlapping memberships, migration from a legacy path, independent offline-folder handling, environment configuration, embedded/sidecar artwork extraction, artwork access only after resolution, mixed-question alternation/fallback, photo matching, local caching, photographer/license retention, custom-photo protection, image version changes, persistent settings, image validation, artist/genre overrides, and server rejection of uploads and resets with Debug off.

Eight additional JavaScript tests (Node.js required only for these tests) cover automatic playback readiness, duplicate media events/submissions, blocked-autoplay fallback, leaving during pending playback, artist category selection/search, artwork reveal/reset timing, folder controls during scans, same-origin artist photo rendering, mixed-mode eligibility notices, and Debug-only image editing controls.

## Local operating limits

This is a single-computer, casual trivia game. It binds only to loopback, rejects cross-origin writes, and never serves original paths to the browser. Keep it on loopback: there is no multi-user authentication or internet-facing hardening. Profiles are local selections, not security boundaries. Do not put it behind a public proxy.

The browser necessarily controls its first playback-ready signal, so this is not an anti-cheat tournament platform. Once activated, deadlines and scoring are enforced by the server. Audio preparation can take time on slow NAS connections; the timer does not run during preparation. Large libraries are kept in each round's local database snapshot for consistent distractors, which increases storage. Scans are manual, not a filesystem watcher. Album artwork is read only from local files. Artist photos are the sole remote integration and send only artist names to Wikipedia/Wikimedia.

A real mounted NAS collection was used to verify artist rounds, overlapping folder rescans, audio playback, and album artwork reveal. Other shares and formats still depend on your mount permissions and FFmpeg decoder support.
