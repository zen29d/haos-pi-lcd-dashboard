# HAOS Pi LCD Dashboard

A status screen for Home Assistant OS on a Waveshare 1.47" SPI LCD (320 × 172, landscape).

## Hardware

### Wiring (Raspberry Pi 4 / 5)

| LCD | Pi pin | GPIO (BCM) |
| --- | ---: | --- |
| VCC | 1 | 3.3 V |
| GND | 6 | GND |
| DIN | 19 | GPIO 10 (MOSI) |
| CLK | 23 | GPIO 11 (SCLK) |
| CS | 24 | GPIO 8 (CE0) |
| DC | 22 | GPIO 25 |
| RST | 13 | GPIO 27 |
| BL | 12 | GPIO 18 |

DC, RST and BL can be moved to other GPIOs; set the matching options below.

### Enable SPI

Home Assistant OS has no setting for SPI. It is enabled by the line `dtparam=spi=on` in `config.txt` on the boot partition, and the normal **Terminal & SSH** app (port 22) cannot reach that file because it runs in its own container. Use one of these:

**Option 1: edit the card on a computer** (easiest when the Pi boots from an SD card)

Shut the Pi down and put the SD card or SSD in a computer. The boot partition (`hassos-boot`, FAT) is marked as an EFI System partition, so macOS and Windows do not mount it automatically:

- macOS: `diskutil list external`, then `sudo diskutil mount diskNs1` for the disk showing `EFI hassos-boot` (it fails without `sudo`). It appears as `/Volumes/hassos-boot`. Run `dot_clean -m /Volumes/hassos-boot` before ejecting to remove the hidden `._` files macOS adds.
- Windows: `diskpart`, then `list disk`, `select disk N`, `select partition 1`, `assign letter=Z`.
- Linux: usually mounted automatically.

Add or uncomment `dtparam=spi=on` in `config.txt`, eject, put the card back and boot.

**Option 2: host SSH on port 22222** (when the boot disk is hard to remove, such as an NVMe SSD; also needed for the optional early boot screen)

1. Create a key pair on your computer: `ssh-keygen -t ed25519 -f ~/.ssh/haos_host`
2. Format a USB stick as FAT32 with the volume label `CONFIG`.
3. Copy the public key to the root of the stick as `authorized_keys` (no extension).
4. Plug the stick into the Pi and run `ha os import` in the Terminal & SSH app, or reboot.
5. `ssh -i ~/.ssh/haos_host -p 22222 root@homeassistant.local`
6. Edit `/mnt/boot/config.txt` so that `dtparam=spi=on` is present and not commented out, then `ha host reboot`.

After rebooting, `/dev/spidev0.0` must exist on the host. The app will not start without it.

## Pages

**System** shows CPU, memory, temperature, the host IP and link, uptime, load and RAM.

**Devices** shows every physical device in Home Assistant grouped by type. Each group shows a device count and one summary:

| Group | Which devices | Summary |
| --- | --- | --- |
| Lights | have a `light` entity | how many are on |
| Power | have a `switch`, or a power, energy or outlet sensor | total watts now |
| Climate | only temperature and humidity sensors | average °C and % |
| Air | PM2.5, CO₂, VOC sensors or a `fan` | worst indoor PM2.5 (orange above 35) |
| Servers | in an area whose name contains "server" or "rack", or reporting through MQTT | hottest temperature |
| Motion | motion, occupancy, presence, door or window sensors | Clear / Motion / N open |
| Phones | Companion app devices (off by default) | how many are home |

Service entries (HACS cards, apps, Sun, Backup and similar), hubs and devices without useful entities are not counted. Sensors in an area named "outdoor" are ignored for the Air summary when indoor sensors exist.

To move a device, give it a Home Assistant label: `lcd-lights`, `lcd-power`, `lcd-climate`, `lcd-air`, `lcd-servers`, `lcd-motion` or `lcd-phones`. The label `lcd-hide` leaves it out.

A group with an offline device (all of its entities `unavailable`) turns orange and says how many.

## Status and updates

The header badge reflects the whole installation:

| Badge | When |
| --- | --- |
| **Offline** (red) | the host has no default route |
| **Error** (red) | a Repair with severity error or critical, or an integration that fails to load |
| **Warning** (orange) | a Repair with severity warning, an offline device, or the CPU temperature at or above *Temperature critical* |
| **Online** (teal) | none of the above |

Repairs include the problems the Supervisor reports (unhealthy or unsupported system). Ignored Repairs are not counted.

The cyan ↑ badge counts every `update` entity that has an update available: Core, OS, Supervisor, apps, HACS and device firmware.

In the Advanced theme the Health tile spells out the issues (for example *2 issues · 1 repair · 1 offline*). Errors in the system log are shown there as information only and do not change the header badge.

## Control from Home Assistant

The app creates these on first start:

| Entity | Purpose |
| --- | --- |
| `input_boolean.lcd_display` | Turn the screen on or off. Use it on a dashboard or in automations. |
| `input_select.lcd_page` | **Auto** rotates the pages; **System** or **Devices** pins one. |
| `sensor.lcd_display_status` | `on`, `off` or `night`. |

Changes take effect within a second. During night mode the screen stays off even if the switch is on.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `theme` | `advanced` | `advanced`: tiles, bars and detail. `simple`: big numbers, no cards. |
| `night_mode` | `true` | Turn the screen off during the night window. |
| `night_start` / `night_end` | `23:00` / `07:00` | Local time, 24 h. The window may cross midnight. |
| `system_seconds` / `devices_seconds` | `20` / `10` | How long each page stays up in Auto. |
| `device_groups` | lights, power, climate, air, servers, motion | Groups on the Devices page, in order (up to six). |
| `refresh_interval` | `5` | Seconds between redraws. |
| `rotate_180` | `false` | Flip the image for an upside-down mount. |
| `temp_warning` | `70` | Temperature bar turns red. |
| `temp_critical` | `80` | Header shows Warning. |
| `spi_device` | `/dev/spidev0.0` | SPI bus. |
| `gpio_chip` | `/dev/gpiochip0` | GPIO chip (Pi 4 and Pi 5 on current HAOS). |
| `dc_pin` / `rst_pin` / `bl_pin` | `25` / `27` / `18` | BCM numbers. |

Restart the app after changing options.

## Boot and shutdown screens

The app starts early (`startup: services`), before Home Assistant Core. While Core starts it shows a progress bar with *Starting Home Assistant*, then *Loading integrations*, then switches to the dashboard. If Core restarts later, the screen shows *Home Assistant restarting*.

When the system shuts down, the app shows *Shutting down…*. Stopping or restarting only the app turns the screen off.

### Advanced: screen from the first seconds of boot

Without extra setup the screen stays dark for roughly the first minute after power-on, until the Supervisor starts the app. The `host/` folder in the repository has an optional script that draws the boot screen about 5 seconds after power-on and shows *Restarting…* or *Powered off · Safe to unplug* at the very end of a shutdown.

It needs root SSH access to the HAOS host (port 22222), which is a debug feature most installations do not have. Install it only if you are comfortable with that:

```sh
# from a computer with host SSH access, inside a clone of this repository
scp -P 22222 host/lcd_boot.py host/99-lcd-boot.rules root@homeassistant.local:/tmp/
ssh -p 22222 root@homeassistant.local '
  mkdir -p /mnt/data/lcd_boot &&
  mv /tmp/lcd_boot.py /mnt/data/lcd_boot/ &&
  mv /tmp/99-lcd-boot.rules /etc/udev/rules.d/ &&
  udevadm control --reload'
```

How it works: a udev rule starts `lcd_boot.py` as the transient systemd unit `lcd-boot` as soon as `/dev/spidev0.0` appears. The script uses only the Python standard library and streams artwork that the app pre-renders into its data folder, so start the app once before rebooting. When the app starts it asks the script to release the GPIO lines and continues the same progress bar. The unit is ordered before `docker.service`, so its stop action runs after every container has stopped and can tell a reboot from a power-off.

`/etc/udev/rules.d` and `/mnt/data` survive Home Assistant OS updates. To remove it:

```sh
rm /etc/udev/rules.d/99-lcd-boot.rules && rm -r /mnt/data/lcd_boot
```

## Troubleshooting

- **The app does not start**: check that `/dev/spidev0.0` exists on the host (SPI enabled) and that the pins in the options match your wiring.
- **Colours look inverted or the image is shifted**: this build targets the 1.47" 172 × 320 panel (inversion on, 34-pixel row offset). Other ST7789 sizes need code changes.
- **The helpers are missing**: they are created when Home Assistant is reachable. Check the app log for `Created input_boolean.lcd_display`.
- **A device is in the wrong group**: add an `lcd-<group>` label to it.
