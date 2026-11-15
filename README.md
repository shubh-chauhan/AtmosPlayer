# AtmosPlayer

A personal iPhone video player: paste a direct link (MKV, MP4, HLS) and it plays, keeping
Dolby Atmos (Dolby Digital Plus / E-AC-3 JOC) so iOS renders it as spatial audio on AirPods.

Playback is done by [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (LGPL-3.0).
This repo is only the app around it. It is built on GitHub's Mac machines, so no Mac is needed.

## What it does

- **Discover** tab: browse and search movies and series through Stremio addons, open a title,
  pick a season and episode, and see the streams every installed addon returns for it, with
  badges (Atmos, 4K, HDR, DV, TrueHD, DTS) read from the addon's description. "Only streams
  labelled Atmos" filters the list. "Continue watching" remembers where you stopped.
- **Addons** tab: install addons by pasting their link (`https://…/manifest.json` or
  `stremio://…`). Cinemeta, Stremio's official catalog addon, is installed on first launch.
  Add your stream addon the same way. Only streams with a direct http(s) link play; torrent-only
  streams need an addon that returns direct links (for example through a debrid service).
- **Links** tab: paste any direct link and play it; recent links are remembered. Also opens files
  from the Files app.
- Player: audio track and subtitle pickers, seek bar, skip 10 s, resume.
- A debug overlay (ladybug button) showing the audio codec, whether the track is Atmos, how the
  engine delivers it, and where iOS is sending the sound.

### Getting an addon link from Stremio

In Stremio, open **Addons**, select the addon and use its share / copy-link button. For addons
you configured with your own settings, open the addon's configure page and copy the install link
it gives you. Paste it into AtmosPlayer's Addons tab.

Needs iOS 18 or later.

## 1. Build it (GitHub Actions)

1. Create a repository on GitHub and push this folder to its `main` branch.
   - A **public** repo builds for free and makes the built-in Dolby test stream work.
   - A private repo also builds, but uses your limited free Mac minutes (about 10 per build,
     counted 10x) and the built-in test stream button will not load.
2. Open the repo's **Actions** tab. The "Build unsigned IPA" run starts on every push; you can
   also start it with **Run workflow**.
3. When it is green, open the run and download two artifacts:
   - `AtmosPlayer-unsigned-ipa` → unzip to get `AtmosPlayer.ipa`
   - `atmos-test-mkv` → unzip to get `atmos-test.mkv` (Dolby's Atmos demo sound in an MKV)

## 2. Install it on the iPhone (Sideloadly, Windows)

1. Install **iTunes** and **iCloud** from Apple's website (the direct downloads, not the
   Microsoft Store versions).
2. Install [Sideloadly](https://sideloadly.io).
3. Connect the iPhone by USB and tap **Trust** on the phone.
4. In Sideloadly: drag in `AtmosPlayer.ipa`, enter your Apple ID, press **Start**.
5. On the iPhone:
   - Settings → General → VPN & Device Management → your Apple ID → **Trust**
   - Settings → Privacy & Security → **Developer Mode** → on (the phone restarts)

With a free Apple ID the app stops opening after 7 days. Repeat step 4 to renew it; your
history is kept.

## 3. Test Atmos

Connect the AirPods Pro, then:

1. **Built-in test:** tap "Dolby Atmos test stream (audio only)".
2. **MKV test:** send `atmos-test.mkv` to the iPhone (iCloud Drive, or iTunes file sharing into
   AtmosPlayer's folder), then "Open a file from Files…".
3. **Real link:** paste a link you also play in Infuse and compare.

What a pass looks like:

| Where | Expected |
| --- | --- |
| Debug overlay, **Track** | `eac3 … JOC (Atmos)` |
| Debug overlay, **Verdict** | `ATMOS passed through untouched` |
| Debug overlay, **Output** | your AirPods, `spatial=on` |
| Control Center, long-press the volume slider | "Dolby Atmos", with Head Tracked available |

If the verdict says Atmos was lost, note the **Audio path** line and the grey log lines under
it; they say why.

## Build settings

- `project.yml` is the project definition; CI turns it into an Xcode project with XcodeGen.
- AetherEngine is pinned from `7.67.1`. It requires Xcode 27, which is why the workflow runs on
  GitHub's `xcode-27` image.
- Plain `http://` links are allowed (App Transport Security is opened up), since many stream
  links are not https.
- Another app can hand over a link with `atmosplayer://play?url=<percent-encoded link>`.

## Stremio account

In the **Stremio** tab, tap **Sign in with Stremio** and use your Stremio email and password.
The app then uses your account's addons (in the same order), shows your Stremio Library on
Home, merges Stremio's Continue Watching, and sends where you stop back to Stremio (turn that
off with "Send watch progress to Stremio"). The password goes only to api.strem.io; the app
keeps just the session key, in the iOS Keychain.

## Previews without sideloading

Every push also runs the app in the iOS Simulator and screenshots Home, a title page, the
Stremio tab, Search and the player. They're pushed to the `previews` branch.
