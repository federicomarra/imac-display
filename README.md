# imac-display

Use an old iMac (built for the 21.5" Retina 4K, Late 2015, on macOS 12 Monterey) as a second screen for an Apple silicon Mac — without extra hardware.

Retina iMacs never supported Target Display Mode, so no cable can make the Mac see them as a real monitor. iMacDisplay does it in software:

- **iMacDisplay** (on the Mac) creates a virtual screen, captures it with ScreenCaptureKit, encodes it with the hardware H.264/HEVC encoder and sends it over the network.
- **iMacDisplay Receiver** (on the iMac) decodes it in hardware and shows it full screen, plays the Mac's sound and sends the iMac's keyboard and mouse back.

*Italiano più sotto.*

## Features

- **Extend** the desktop (a new screen in System Settings → Displays) or **mirror** the main screen.
- Retina resolution by default (looks like 2048 × 1152, rendered at 4096 × 2304), up to 60 fps.
- **Adaptive quality**: when the link can't keep up, iMacDisplay lowers the frame rate first (configurable: resolution or compression instead).
- **Brightness, gamma and warmth** of the iMac screen controlled from the Mac's menu bar.
- **Audio**: the Mac's sound plays on the iMac only (the Mac's speakers are muted while streaming).
- **Keyboard and mouse** connected to the iMac control the Mac. ⌃⌥⌘⌫ gives them back to the iMac.
- **Automatic discovery** (Bonjour) and a **one-time pairing code**.
- Picks the fastest link automatically: **Thunderbolt cable** (Thunderbolt Bridge), **Ethernet** or **Wi-Fi**.
- The receiver opens at login on the iMac.
- English and Italian interface.

## Requirements

| | Mac (sender) | iMac (receiver) |
|---|---|---|
| macOS | 14.2 or later | 12 or later |
| Chip | Apple silicon (Intel Macs may work, untested) | Any |

Both computers must be on the same network, or connected with a Thunderbolt cable (see below). Building needs Xcode 16 or later on the Mac.

## Limits — read this first

- **It is not a real monitor.** The iMac only shows the Mac while both apps are running: no boot screen, no login window, no FileVault unlock.
- **The image is compressed.** Text is sharp on a cable or good Ethernet; on Wi-Fi expect artifacts or a lower frame rate.
- **4K at 60 Hz is at the edge of what the iMac can decode.** Its processor (Broadwell) decodes H.264 in hardware but not HEVC, and 4096 × 2304 at 60 fps is beyond the official H.264 Level 5.2 limit (about 56 fps). If the image stutters, set the maximum frame rate to 45 fps.
- **Private API.** The virtual screen uses Apple's private `CGVirtualDisplay` API (also used by BetterDisplay and DeskPad). A macOS update could break it. Mirror mode doesn't need it.
- **Some iMac shortcuts stay on the iMac.** Spotlight (⌘Space) and Mission Control shortcuts are handled by the iMac's system before the app sees them. Turn them off on the iMac in System Preferences → Keyboard → Shortcuts if you want them to reach the Mac.

## Build

1. Open `iMacDisplay.xcodeproj` in Xcode.
2. **Mac app:** choose the scheme **iMacDisplay** → *Product → Run*. An icon appears in the menu bar.
3. **iMac app:** choose the scheme **iMacDisplay Receiver** → *Product → Build*, then *Product → Show Build Folder in Finder* and take `iMacDisplay Receiver.app` from `Products/Debug`. It is a universal app, so it runs on the Intel iMac.

Or from Terminal:

```sh
xcodebuild -project iMacDisplay.xcodeproj -target "iMacDisplay Receiver" -configuration Release build
xcodebuild -project iMacDisplay.xcodeproj -target iMacDisplay -configuration Release build
# The apps end up in build/Release/
```

The apps are signed "to run locally" (no Apple developer account needed). macOS asks for the Screen Recording permission again after every rebuild.

## Install on the iMac

1. Copy `iMacDisplay Receiver.app` to the iMac's Applications folder (USB stick, AirDrop or file sharing).
2. Because the app isn't notarized, open it the first time with right-click → *Open*, or run on the iMac:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/iMacDisplay Receiver.app"
   ```
3. The receiver goes full screen and waits. It adds itself to the login items automatically (menu *iMacDisplay Receiver → Open at Login* to change this).

## First connection

1. On the Mac, click the menu bar icon and choose the iMac.
2. The iMac shows a 6-digit code: type it on the Mac. This happens only once.
3. Allow the permissions macOS asks for on the Mac: **Screen Recording**, **System Audio Recording**, **Accessibility** (for the iMac keyboard and mouse) and **Local Network**.
4. In extend mode, arrange the new screen in System Settings → Displays.

## Using a Thunderbolt cable

The fastest and most stable link. The iMac has Thunderbolt 2 ports and the Mac Thunderbolt 3/4 (USB-C) ports, so you need:

- Apple **Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter**, and
- a **Thunderbolt 2 cable** (not a Mini DisplayPort cable: it looks the same but carries only video).

Connect them and macOS creates a *Thunderbolt Bridge* network on both computers by itself. iMacDisplay prefers it automatically over Ethernet and Wi-Fi; the menu shows "Thunderbolt cable" as the link.

## How it works

```
Mac                                                    iMac
CGVirtualDisplay → ScreenCaptureKit → VideoToolbox ─┐
Core Audio process tap ─────────────────────────────┼─ TCP (Bonjour) ─→ AVSampleBufferDisplayLayer
CGEvent ←───────────────────────────────────────────┘                   AVAudioEngine, NSEvent
```

- `Shared/` — wire protocol (length-prefixed messages over TCP) used by both apps.
- `Sender/` — Mac app (SwiftUI menu bar extra + settings).
- `Receiver/` — iMac app (AppKit, macOS 12).
- `Config/` — Info.plists and the bridging header with the private virtual display API.

The stream is **not encrypted** (meant for a trusted home network). Pairing uses a one-time code and a stored token.

---

## In italiano

Usa un vecchio iMac (pensato per il 21,5" Retina 4K, fine 2015, con macOS 12 Monterey) come secondo schermo di un Mac con chip Apple, senza hardware aggiuntivo. Gli iMac Retina non hanno mai supportato la Modalità Monitor Esterno, quindi nessun cavo può farli vedere al Mac come un monitor vero: iMacDisplay lo fa via software.

**Cosa fa:** estende o duplica la scrivania; risoluzione Retina fino a 60 fps; qualità adattiva (di default abbassa prima il frame rate, configurabile); luminosità, gamma e temperatura colore dell'iMac regolabili dalla barra dei menu del Mac; audio del Mac solo sull'iMac; tastiera e mouse dell'iMac controllano il Mac (⌃⌥⌘⌫ li restituisce all'iMac); ricerca automatica e codice di abbinamento la prima volta; sceglie da solo il collegamento più veloce tra cavo Thunderbolt, Ethernet e Wi-Fi; si apre al login sull'iMac; interfaccia in italiano e inglese.

**Limiti:** non è un monitor vero (funziona solo con entrambe le app aperte, niente schermata di avvio o login); l'immagine è compressa; il 4K a 60 Hz è al limite di decodifica dell'iMac (se scatta, imposta 45 fps); lo schermo virtuale usa un'API privata di Apple che un aggiornamento di macOS potrebbe rompere; Spotlight e Mission Control dell'iMac restano all'iMac, a meno di disattivarne le scorciatoie sull'iMac.

**Compilazione:** apri `iMacDisplay.xcodeproj` in Xcode 16+. Schema **iMacDisplay** → *Run* per il Mac. Schema **iMacDisplay Receiver** → *Build*, poi copia `iMacDisplay Receiver.app` sull'iMac (è universale, gira anche su Intel). Al primo avvio sull'iMac: clic destro → *Apri*, oppure `xattr -dr com.apple.quarantine "/Applications/iMacDisplay Receiver.app"`.

**Primo collegamento:** dal menu del Mac scegli l'iMac, inserisci il codice di 6 cifre che compare sull'iMac e concedi i permessi Registrazione schermo, Registrazione audio di sistema, Accessibilità e Rete locale.

**Cavo Thunderbolt:** servono l'adattatore Apple da Thunderbolt 3 (USB-C) a Thunderbolt 2 e un cavo Thunderbolt 2 (non Mini DisplayPort). macOS crea da solo la rete "Bridge Thunderbolt" e l'app la preferisce automaticamente.

## License

MIT — see [LICENSE](LICENSE).
