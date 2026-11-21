# Android TV Debloat

A single reversible script for debloating Android TV and Google TV over ADB.

It disables packages with `pm disable-user --user 0`. It does not uninstall anything, root the TV, or replace the launcher. A backup is written before the first change, and `--restore` re-enables the packages.

## Quick start

```bash
git clone https://github.com/kidtaroi/android-tv-debloat.git
cd android-tv-debloat

export TV_HOST=192.168.1.50
./debloat.sh --host "$TV_HOST"
```

The default list is [`lists/generic-telemetry.txt`](lists/generic-telemetry.txt). Read it first and remove any app you use.

### Chromecast with Google TV 4K

```bash
./debloat.sh --host "$TV_HOST" \
  --list lists/chromecast-gtv-4k.txt
```

This list keeps the stock launcher, setupwraith, casting, voice search, and the Android TV remote service.

## Pairing

If the TV uses wireless debugging with a pairing code:

```bash
./debloat.sh --host 192.168.1.50 \
  --pair 37123 --code 123456
```

If the connect port is not 5555, pass it with the host:

```bash
./debloat.sh --host 192.168.1.50:39223
```

## Undo

```bash
./debloat.sh --host "$TV_HOST" --restore
```

Use a specific backup:

```bash
./debloat.sh --host "$TV_HOST" \
  --state ~/.android-tv-debloat/20261021-201500-192.168.1.50_5555 \
  --restore
```

The backup directory contains the installed, enabled, and disabled package lists from before the change, plus `disabled-by-us.txt`. Keep it until you have reboot-tested the TV.

## Options

```text
--host IP[:PORT]        TV address, or set TV_HOST
--serial SERIAL         Use an existing ADB serial
--pair PORT             Wireless-debugging pairing port
--code CODE             Six-digit pairing code
--list FILE             Package list
--state DIR             Backup directory to write or restore
--restore               Re-enable packages from the backup
--dry-run               Print changes without applying them
--allow-setupwraith     Allow disabling Google TV's setupwraith
--force                 Allow protected packages
```

## What it skips

The script never disables:

- The app that currently owns Home.
- System UI, Settings, Shell, or the package installer.
- Play services or the Play Store.
- The Android TV remote service, Google Assistant, TTS, or the Cast receiver.
- The firmware update service.

`com.google.android.tungsten.setupwraith` is also skipped unless you pass `--allow-setupwraith`. Disabling it can break phone casting and, on some Google TV builds, remove the saved Wi-Fi network.

## List format

One package per line. Blank lines and `#` comments are ignored. A leading `package:` is accepted, so you can paste `pm list packages` output.

```text
com.google.android.feedback
com.google.android.play.games
```

## After a firmware update

A firmware update can re-enable packages. Reconnect ADB and run the same command again:

```bash
./debloat.sh --host "$TV_HOST" --list lists/chromecast-gtv-4k.txt
```

The script skips packages that are already disabled.

## Requirements

- `adb` from the Android platform tools.
- Developer options and debugging enabled on the TV.
- The computer and TV on the same LAN.

ADB over Wi-Fi does not survive a reboot on most Google TV devices. Turn wireless debugging on again when you need it, and turn it off when you finish.

## License

MIT. See [LICENSE](LICENSE).
