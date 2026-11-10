# Couchmate for Apple TV

The Apple TV app for [Couchmate](https://github.com/valonia/couchmate) – watch together, in sync.

Like the [Android TV app](https://github.com/valonia/couchmate-androidtv) it is a front end: it plays video in sync
with everyone else and has search, favourites, history, settings and translation built in. Everything else – the
menu, the screens, what is played and how the player reacts to the remote – comes from the plugins on the
Couchmate server. The app draws what they describe.

SwiftUI for tvOS 17, with VLC (TVVLCKit) as the player – it plays everything the plugins deliver (MPEG-TS live,
MKV, AC3, video and audio as separate files …).

## Install

Every push builds an unsigned `.ipa` on GitHub (**Actions → Build → the latest run → Artifacts**, or attached to each
release). Install it with **TVSign** (or another tool that signs with your Apple account).

Start the app, write the server's address (e.g. `192.168.1.10:8787`), your name and the room's PIN code.

## The remote

In the player, the plugin decides what the touch surface's up/down/left/right and a click do (pause, channel list,
skip, queue …). Play/Pause always pauses and plays. **Menu** closes panels, cancels "next" or a reminder for
everyone, and otherwise goes back to the menu. Hold the click on a card to add it to the favourites.

## Build on a Mac

```bash
brew install xcodegen
xcodegen generate
pod install
open Couchmate.xcworkspace
```

Choose your team under **Signing & Capabilities** to run it on an Apple TV straight from Xcode.

## How it fits together

| File | |
|---|---|
| `SyncClient.swift` | The WebSocket to the server: the room's state, favourites, reminders, chat and every command |
| `PlaybackSync.swift` | Makes VLC follow the room – speed corrections, seeks, the separate audio file |
| `Api.swift` | The server's HTTP API: menu, views, search, plugin data |
| `ViewRenderer.swift`, `ViewBlocks.swift` | Draws the screens plugins build from building blocks |
| `PlayerView.swift`, `PlayerPanels.swift` | The player: the plugin's keys, overlay and settings, the queue, chat and "next" |
| `I18n.swift` | The app's texts, translated by the server into the TV's language |

Sizes follow the Android TV app (its dp/sp times `uiScale` in `Theme.swift`).
