# QNX 8.0 on Raspberry Pi 4 / 5 (QNX Everywhere)

Docs: `https://www.qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti/intro.html` (install.html, configure.html, interacting-with-the-system.html), headless guide `https://qnx.software/en/blog/2026/set-up-a-headless-qnx-raspberry-pi`.

## Hardware
- Raspberry Pi 4 or 5; current QSTI docs say **8 GB RAM or more** (older docs accepted 2/4 GB — try if that's what you have, but expect the desktop/AI samples to want RAM).
- microSD **≥32 GB**, a well-known brand (SanDisk, Samsung, Kingston).
- Official PSU (5.1 V / 3 A for Pi 4). Use the **HDMI 0** port for a display. Bluetooth keyboards unsupported.
- Optional but strongly recommended for headless work: **USB–TTL serial adapter** (3.3 V).

## 1. Get the image
1. Host: SDP 8.0 installed (see `toolchain-and-build.md`).
2. Software Center → install **`com.qnx.qnx800.quickstart.rpi4`** (Pi 5: `com.qnx.qnx800.quickstart.rpi5`).
3. The image lands in the SDP install's `images` directory as `qnx_sdp8.0_rpi4_quickstart_YYYYMMDD.img` (find it: `find ~/qnx800* -name 'qnx_sdp8.0_rpi*_quickstart_*.img'`).

## 2. Flash
- Recommended: Raspberry Pi Imager (`sudo snap install rpi-imager` on Ubuntu ≥20.04). Device: Raspberry Pi 4 (or 5); OS: **Use custom** → the .img; Storage: the SD card. When asked "Use OS customisation?" → **NO** (the QNX image doesn't use Pi OS customisation), then YES to write.
- Command line alternative (double-check the device name with `lsblk` first — writing to the wrong disk destroys it):
  ```bash
  sudo dd if=qnx_sdp8.0_rpi4_quickstart_YYYYMMDD.img of=/dev/sdX bs=4M status=progress conv=fsync
  ```
- Raspberry Pi docs suggest updating the Pi's bootloader EEPROM firmware first (do it from Raspberry Pi OS if the Pi is old).

## 3. Configure before first boot (FAT32 boot partition)
After flashing, re-insert the card; the boot partition mounts on the host.
- **Wi-Fi**: create/edit `wpa_supplicant.conf` on the boot partition:
  ```
  network={
    ssid="YourSSID"
    key_mgmt=WPA-PSK
    psk="YourPassword"
  }
  ```
  The Wi-Fi interface on QNX is `bcm0`. Ethernet (genet) works with DHCP out of the box — the most reliable first boot is wired.
- **network** file on the boot partition: network variables (hostname, etc.). Its timestamp must be **newer** than the copy on the system partition for changes to apply (on the Pi it's `/boot/network`; set the clock with `date -s` if needed).
- Headless blog alternative: `qnx_config.txt` with `HOSTNAME=qnxpi-yourname`. The two documents disagree — check which file exists on your card.
- Default hostname **`qnxpi`** → reachable as **`qnxpi.local`** via mDNS. Rename it if more than one QNX Pi is on the network (two Pis = name clash).

## 4. Boot and log in
- First boot: splash → "QNX Welcome" desktop (if a display is attached). Allow about a minute for networking.
- Users: **`qnxuser` / `qnxuser`**; **`root` / `root`** (change both with `passwd`).
- SSH from Linux: `ssh qnxuser@qnxpi.local` (or the IP: find it with `ping qnxpi.local`, your router's DHCP table, or `ifconfig` on the Pi's display/serial console).
- SSH from Windows: `ssh -m hmac-sha2-256 qnxuser@qnxpi.local` (or put `MACs hmac-sha2-256` in `~/.ssh/config`).
- Root: `su` from qnxuser. **Root SSH login is disabled** by default; to enable (dev only): set `PermitRootLogin yes` in `/usr/etc/ssh/sshd_config`, then `slay -f sshd; /usr/bin/sshd -f /usr/etc/ssh/sshd_config` from a local console.
- Older Momentics/IDE SSH may need legacy `ssh-rsa` algorithms enabled in your SSH config.
- Suggested host `~/.ssh/config` entry:
  ```
  Host qnxpi
      HostName qnxpi.local
      User qnxuser
  ```
  then `ssh-copy-id qnxpi` for key login.

## 5. Serial console (rescue path)
- Pi header: **TX = pin 8 (GPIO14), RX = pin 10 (GPIO15), GND = pin 6 or 14**; cross TX↔RX to the adapter; **do not connect the adapter's power pin**.
- 115200 baud, 8N1, no flow control. Linux: `ls /dev/ttyUSB*` then `sudo screen /dev/ttyUSB0 115200` (or `picocom -b 115200 /dev/ttyUSB0`). Windows: PuTTY on the COM port.
- Serial login drops you into a **root shell without a password** (keep this in mind for physical-security claims).
- The console is the BSP's mini UART: `devc-serminiuart -b115200 -c500000000 -e -F -u1 0xfe215000,125`.
- Verified adapters: Raspberry Pi Debug Probe, DTech DT-6553.

## 6. First checks on target
```sh
uname -a                 # QNX ... 8.0 ... aarch64
pidin | head -40         # running drivers/services
ifconfig                 # genet0 / bcm0 addresses
slog2info | tail         # boot log
df -h; mount             # filesystems (find persistent storage for your apps)
use pidin                # built-in usage text
ls /dev                  # i2c*, spi*, gpio, ser*, sd*
```

## 7. Raspberry Pi 4 BSP drivers (8.0 BSP reference commands)
| Function | Driver / command |
|---|---|
| Startup | `startup-bcm2711-rpi4 -v -D miniuart -W 2500 -u reg` (`-W ms` enables watchdog; start `wdtkick` early) |
| GPIO | `io-gpio -d gpio_hw_bcm2711 -p 0xFE200000` (lib `gpio_hw_bcm2711.so`; ability `io-gpio/all`); utility `gpio-bcm2711` |
| I2C | `i2c-bcm2711 -p0xfe804000` |
| SPI | `spi-bcm2711` (config file `/etc/system/config/spi/spi.conf` required) |
| Serial console | `devc-serminiuart …` (PL011 `devc-serpl011` also available) |
| SD card | `devb-sdmmc-bcm2711 mem name=below1G sdio addr=0xfe340000,irq=158 disk name=sd` → `/dev/sd0`, e.g. `mount -t dos /dev/sd0t12 /fs/sd` |
| Network | `io-sock -m phy -m fdt -m phy_fdt -d genet -m pci -d em -d ix -d re -m usb -d axe -d axge -d cdce -d smsc` (+ `dhcpcd`) |
| PCI | `pci-server -c --bus-scan-limit=1` (start before USB) |
| USB host | `io-usb-otg -t memory=below1G -d bcm2711-xhci pindex=0,memory=below1G`; mass storage `devb-umass cam pnp mem name=below1G disk name=umass` → `/dev/umass0t12` |
| Watchdog | `startup -W <ms>` + `wdtkick -W0x24:<val> -W0x1c:0x5A000020`, `val = (timeout_ms * 67) \| 0x5a000000` (2500 ms → 0x5A028E4C) |
| Other | `mbox-bcm2711` (VideoCore mailbox) |
**Not in the Pi 4 BSP**: hardware PWM driver, camera driver (Pi Camera Module 3 works only through the *experimental* QNX Sensor Framework in the newer quick-start image / AI camera sample). Put PWM, fast ADC, motor control and hard-timed sampling on an MCU (STM32/Teensy/ESP32) and talk to it over UART/SPI/I2C.

Note: only GPIO/I2C/SPI/UART/Ethernet/USB/SD/watchdog are documented. Before designing around another peripheral, check the BSP page and `ls /dev` on the target.

## 8. Pi 5
QSTI/CTI and an RPi5 BSP (bcm2712) exist since January 2026. The Pi 5's I/O goes through the RP1 chip, so driver names and pins differ from the Pi 4 — re-verify each peripheral. QNX Hypervisor's RPi sample config is for the Pi 4B.

## 9. Troubleshooting
- Not on the network: use Ethernet; wait a minute; check `ifconfig` on serial; mDNS blocked on some networks → use the IP.
- Wi-Fi not joining: check `wpa_supplicant.conf` quoting; confirm the interface `bcm0` exists; 2.4 vs 5 GHz.
- Black screen: HDMI 0, official PSU; on small displays disable pixel-to-pixel, enable underscan.
- Card won't boot: re-flash, try another brand, avoid Imager's OS customisation.
- Two Pis named `qnxpi`: rename one before booting both.
