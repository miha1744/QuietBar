![QuietBar](docs/assets/quietbar.svg)

# QuietBar

[![Build and verify packages](https://github.com/miha1744/QuietBar/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/miha1744/QuietBar/actions/workflows/ci.yml)

**A quieter menu bar for macOS.**

QuietBar is a small, native macOS utility focused on the purple screen-sharing indicator. It offers a native hiding mode where the required system API exists, plus an experimental launch mode for Jump Desktop Connect on older macOS versions.

[Русский](docs/README.ru.md) · [Compatibility & evidence](docs/compatibility.md) · [How it works](docs/architecture.md)

Use QuietBar on your own Mac, with the knowledge of anyone using it. **Hiding an indicator does not stop screen capture or remote access.**

## What is ready

| Mode | Current status |
| --- | --- |
| Native system filter | Indicator-group hiding was observed on macOS 27.0.1, Apple Silicon. Uses a private API and can change with macOS updates. |
| Experimental Jump launcher | Implemented for macOS 14 and later when the native API is absent. A real Jump session, its image, input and hidden indicator still need end-to-end validation. |

The app builds for **macOS 14+**, on **Apple Silicon and Intel**. A universal binary is a build target, not a promise that every version or Mac has been tested. See the [evidence matrix](docs/compatibility.md).

QuietBar currently has one mode-level toggle. It does not offer individual app or icon selection. The native mode may also hide AirDrop, Focus and Now Playing as part of the same system group.

## Install or build

Download the universal DMG from [1.2.0 Preview 1](https://github.com/miha1744/QuietBar/releases/tag/v1.2.0-preview.1), drag QuietBar to Applications, eject the image and launch the installed copy. This is an **experimental, unnotarized preview**. No Terminal commands need to be entered to use the packaged app.

To build from source on a Mac with Xcode Command Line Tools installed, run from the repository directory:

```sh
./build.sh
```

The script creates `dist/QuietBar.app`, a universal ZIP and a DMG. Open the DMG, drag QuietBar to Applications, eject the image, then launch the installed copy. The script does not install or launch it for you. Run `./build.sh --help` for output paths and signing options.

Local builds are **ad hoc signed and unnotarized**. Hardened runtime is available with `--hardened-runtime`; it does not provide Developer ID or notarization. If macOS blocks a trusted copy, Apple describes the **System Settings → Privacy & Security → Open Anyway** flow. That option may not be available on every Mac. See [Apple’s instructions](https://support.apple.com/en-us/102445).

## Use QuietBar

The current app interface is in Russian. Open its menu bar item to return to settings.

**Native mode:** choose **«Скрыть значки»** (Hide icons). Choose **«Показать значки»** (Show icons) to restore them. Moving the pointer near the clock temporarily restores the group so Notification Center remains accessible. Quitting QuietBar releases the filter.

**Experimental Jump mode:** preparation restarts the current user’s Jump agent and can interrupt your connection. Keep local access available for the first trial.

1. Install Jump Desktop Connect in `/Applications`. In its settings, enable **General → Start Jump Desktop when my computer starts** yourself. See [Jump’s settings reference](https://docs.jumpdesktop.com/connect/settings-reference/).
2. Choose **«Подготовить Jump»** (Prepare Jump). If prompted, use **«Настроить разрешения…»** to grant Terminal Screen Recording and Accessibility through macOS settings. QuietBar opens Terminal automatically; no commands need to be entered. Keep Jump’s own permissions enabled too.
3. Return to QuietBar and prepare again. **«Запуск Jump подготовлен»** means the launched agent remains alive. Reconnect and separately check changing screen content, mouse control, keyboard input and the indicator on this Mac.
4. Choose **«Вернуть обычный запуск»** (Restore normal launch) to undo preparation. Wait for restoration to finish; reconnect if required.

Terminal receives powerful permissions in the experimental mode. QuietBar checks them before taking over the user agent. It does not edit the macOS permission database, disable SIP or change Jump’s system daemon. [Architecture and recovery limits](docs/architecture.md) explain the exact scope.

To start QuietBar at login, keep it in a permanent location and enable its login checkbox. macOS may require approval under **General → Login Items**.

## Next steps

The priority is real Jump validation on SIP-enabled Macs, including reconnect and recovery. Per-app or per-item rules are a possible future direction for compatible native APIs; they are not implemented. The legacy launcher remains specific to Jump Desktop Connect.

## License and credits

QuietBar is available under the [MIT License](LICENSE). The native assessment API activation is adapted from [Brent Ceulemans’ stash](https://github.com/brentc22/stash), also MIT licensed. Its copyright and license are preserved in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

## Contribute

See the [development guide](docs/development.md) for build checks and the
[contribution guide](CONTRIBUTING.md) for focused fixes and useful compatibility reports.
Review [security and privacy](SECURITY.md) before sharing diagnostics.
