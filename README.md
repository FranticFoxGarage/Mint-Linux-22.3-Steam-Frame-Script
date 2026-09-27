# frame-linux-fix

DISCLAIMER: VIBE CODED!!! Tested on my own machine but keep that in mind going forward!
Workarounds for the Steam Frame on desktop Linux. Tested on Linux Mint 22.3 (kernel 7.0, NVIDIA). Should work on other apt-based distros like Ubuntu, Debian and Pop!_OS.

## What it fixes

**Wireless adapter won't connect.** Kernels before 7.2 are missing Realtek's fixes for Valve's adapter, so it fails with `failed to insert STA entry for the AP (error -22)`. The script installs the [morrownr/rtw89](https://github.com/morrownr/rtw89) driver through DKMS with newer firmware. It also sets a Wi-Fi region (6 GHz is blocked without one) and turns off USB power saving for the adapter.

**SteamVR doesn't start when you launch a game from the headset** ([SteamVR-for-Linux #962](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/962)). The game starts on the PC and the headset never gets it.

**Closing a game from the headset leaves it running on the PC.**

For the last two, a small background helper watches Steam's logs. When a VR game starts while the headset is connected and SteamVR is not running, it closes the game and starts SteamVR. Then launch the game again from the headset. When you close the game from the headset, the headset's stream to SteamVR ends but the game keeps running on the PC, so the helper closes the game and SteamVR once the stream has been gone for 10 seconds with the wireless adapter, or 20 seconds over home Wi-Fi. If the stream comes back in that time, nothing is closed. When the game closes on the PC, it quits SteamVR. When SteamVR closes or crashes, it closes the game.

The helper only acts on games Steam lists as VR games, so 2D games are left alone. It also ignores VR games started while the headset is not connected, so desktop mode still works.

## Usage

```
chmod +x frame-linux-fix.sh
./frame-linux-fix.sh
```

Run it as your normal user, not with sudo. It asks for your password when it needs it.

| Command | What it does |
|---|---|
| `install` | Installs everything |
| `repair` | Updates the driver and reinstalls everything. Use this if something stops working. |
| `status` | Shows what it detects: adapter, driver, USB speed, Secure Boot, Steam folder, your VR games, helper log |
| `uninstall` | Removes everything the script added |

Reboot after install and uninstall.

Plug the adapter into a USB 3.0 port on the back of the PC directly on the motherboard. Front panel ports and hubs may not work.

## Secure Boot

If Secure Boot is on, the script checks whether the DKMS signing key is enrolled. If not, it asks you to pick a one-time password. On the next reboot a blue MOK management screen appears. Choose Enroll MOK, Continue, Yes, enter the password, then Reboot.
> [!WARNING]
> Secure boot is OFF on my machine - if yours is ON, THIS IS NOT TESTED SO PROCEED WITH CAUTION 

## When to uninstall

When your distro ships kernel 7.2 or newer, the driver part may not be needed. `status` tells you when your kernel reaches 7.2. When Valve fixes #962, the helper is not needed either. Run `uninstall` and test without it.

## What it installs

System (removed by uninstall):

- DKMS module `rtw89` and its source in `/usr/src/rtw89-<version>`
- Updated firmware in `/lib/firmware/rtw89` (backed up first, restored on uninstall)
- `/etc/modprobe.d/rtw89.conf` (blocks the kernel's own rtw89 driver)
- `/etc/modprobe.d/frame-linux-fix-region.conf` (skipped if you already set a region)
- `/etc/udev/rules.d/50-steam-frame-dongle.rules`
- `/var/lib/frame-linux-fix/` (driver source, firmware backup, state)

Your user (removed by uninstall):

- `~/.local/bin/frame-vr-helper.sh`
- `~/.config/autostart/frame-vr-helper.desktop`
- `~/.local/state/frame-vr-helper.log`

Build tools (git, dkms, build-essential, kernel headers) are left installed.

## Known issues it does not fix

- Video freezes for a moment while audio keeps going. This is a SteamVR encoder bug on Linux ([#965](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/965)).
- "Connection failed" popups while the adapter is plugged in and the headset is off. Steam retries the connection every minute. Unplug the adapter when you are not in VR.
- Other distros (Fedora, Arch) are not handled automatically. Install git, make, gcc, dkms and headers for your kernel first, and the script will use them.
