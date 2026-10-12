# Lid Awake

Lid Awake is a macOS menu bar switch that keeps a Mac awake while its lid is closed and it is connected to AC power. It restores normal sleep on battery and asks macOS to sleep if AC is disconnected while the lid is closed.

## Build

Requirements: macOS 13 or later, Apple silicon, and a working Xcode or Command Line Tools Swift toolchain.

```sh
./Scripts/build.sh && open "build/Lid Awake.app"
```

Choose **Keep Awake While Plugged In** in the menu bar. The first enable asks for administrator authentication to install the system power monitor. The helper continues running if the menu bar app quits.

The local build is ad-hoc signed and is not notarized. macOS may require you to approve opening it. This repository does not include a prebuilt binary.

## Behavior

- While enabled on AC, the monitor disables macOS system sleep, including idle sleep. The display can still turn off.
- On battery, the monitor restores normal lid sleep. If it observes AC power being disconnected while the lid is closed, it restores the sleep setting and requests immediate sleep.
- Reconnecting AC while the switch remains enabled restores the awake setting.
- Turning the switch off restores the system sleep setting captured when the switch was enabled. **Remove Background Monitor…** removes the helper and restores that saved setting.
- Power changes are checked every few seconds. Keep the Mac on a hard, ventilated surface while it runs with the lid closed; it may get warm and use more power.

The helper is installed per macOS system and the menu bar app opens at login only if the user configures that separately. This source build stores its state under the `Lid Awake (Public Build)` support directories so it does not overwrite state from a separately installed build. Only one Lid Awake monitor should be enabled at a time because all builds control the same macOS sleep setting. The code targets Apple silicon and macOS 13 or later.

## Test

Run the power monitor harness on macOS with Python 3:

```sh
python3 -m unittest discover -s Tests -v
```

The harness runs a temporary copy of the monitor with stubbed power and lid inputs. It does not change the Mac's power settings or request sleep.

## Remove

Choose **Remove Background Monitor…** in the menu bar app and confirm the administrator prompt. This restores the captured sleep setting and removes the privileged helper.
