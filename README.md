# Android TV Clean Setup

One script that gives an Android TV or Google TV a clean, Apple TV-style home screen and turns off the usual tracking and telemetry.

The script:

1. Backs up the TV.
2. Installs the bundled [CleanYourTV](https://github.com/Gathin23/cleanyourtv) launcher.
3. Makes it the default Home app.
4. Disables telemetry, feedback, ad services, and preloaded junk with `pm disable-user`.
5. Records everything so you can undo it.

Nothing is uninstalled. No root is needed.

> The bundled launcher is a prebuilt CleanYourTV CI APK. Its source and hash are in [`launcher/SOURCE.md`](launcher/SOURCE.md).

## Give this to your friend

On the computer:

```bash
git clone https://github.com/kidtaroi/android-tv-clean-setup.git
cd android-tv-clean-setup

export TV_HOST=192.168.1.50
./setup.sh --host "$TV_HOST"
```

The script asks for confirmation, then does the backup, launcher install, Home handover, and debloat.

If the TV uses wireless debugging with a pairing code:

```bash
./setup.sh --host 192.168.1.50 \
  --pair 37123 --code 123456
```

If the connect port is not 5555, put it in the host:

```bash
./setup.sh --host 192.168.1.50:39223
```

On the TV, the friend needs to enable Developer options and wireless debugging:

1. **Settings → System → About**.
2. Click **Build** seven times.
3. Go back to **Developer options**.
4. Turn on **Wireless debugging** (or **Network debugging**).
5. Keep the TV awake while the script runs.

After a reboot, wireless debugging is usually off again. Turn it back on before running the script a second time.

## Chromecast with Google TV 4K

```bash
./setup.sh --host "$TV_HOST" --list lists/chromecast-gtv-4k.txt
```

That list keeps casting, voice search, and the stock Home path intact. It does not disable setupwraith.

## Debloat only

If you want to keep the current launcher and only disable the junk:

```bash
./setup.sh --host "$TV_HOST" --debloat-only
```

Or use the shortcut:

```bash
./debloat.sh --host "$TV_HOST"
```

## Undo

```bash
./setup.sh --host "$TV_HOST" --restore
```

The newest backup is used. To choose one:

```bash
./setup.sh --host "$TV_HOST" \
  --state ~/.android-tv-clean-setup/20261021-201500-192.168.1.50_5555 \
  --restore
```

The backup directory holds the installed, enabled, and disabled package lists from before the change, plus `disabled-by-us.txt` and the old Home component. Keep it until you have reboot-tested the TV.

## What is disabled

The default list is [`lists/generic-telemetry.txt`](lists/generic-telemetry.txt):

- Feedback and telemetry
- Advertising ID and Privacy Sandbox services
- Federated learning and on-device personalization
- Network diagnostics reporting
- Preloaded games, Google TV / Play Movies, print spooler, and TalkBack
- Google ambient screensaver

The script skips:

- The app that currently owns Home
- System UI, Settings, Shell, and the package installer
- Play services and the Play Store
- Google Assistant, TTS, Cast receiver, and the Android TV remote service
- The firmware update service

`com.google.android.tungsten.setupwraith` is also skipped unless you pass `--allow-setupwraith`. Disabling it can break phone casting and, on some Google TV builds, remove the saved Wi-Fi network.

## List format

One package per line. Blank lines and `#` comments are ignored. A leading `package:` is accepted.

```text
com.google.android.feedback
com.google.android.play.games
```

## Check first

```bash
./setup.sh --host "$TV_HOST" --dry-run
```

The script still connects and writes a backup, but it does not disable anything or install the launcher.

## Requirements

- `adb` from the Android platform tools.
- Developer options and debugging enabled on the TV.
- The computer and TV on the same LAN.

On macOS or Linux, run the script in a terminal. On Windows, use Git Bash or WSL with `adb` on the path.

## License

The script and documentation are MIT licensed. See [LICENSE](LICENSE). The bundled CleanYourTV APK is MIT licensed and belongs to the CleanYourTV project; see [`launcher/SOURCE.md`](launcher/SOURCE.md).
