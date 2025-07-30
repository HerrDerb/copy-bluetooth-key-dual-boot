# copyBluetoothKeyFromWin.sh

**Disclaimer:** Use at your own risk. 

### Purpose
This script copies Bluetooth pairing keys from a Windows partition to a Linux system for dual-boot scenarios. It allows you to keep your Bluetooth device pairings (e.g., headphones, mice, keyboards) working seamlessly between Linux and Windows.

---

## **IMPORTANT: Pairing Order**
**You must pair your Bluetooth device with Linux first, then with Windows.**

1. Boot into Linux and pair your Bluetooth device as usual.
2. Boot into Windows and pair the same device.
3. Return to Linux and run this script to copy the pairing key from Windows to Linux.

If you do not follow this order, the keys may not be compatible and the device may not work on both systems.

---

## Prerequisites
- Bluetooth already paired on both Linux and Windows (see above)
- Access to your Windows partition (not BitLocker-encrypted, or you must unlock it first)
- `reglookup` utility (the script will install it if missing)

---

## Usage
1. **Boot into Linux.**
3. **Run the script as root (recommended):**
   ```bash
   sudo bash copyBluetoothKeyFromWin.sh
   ```
4. **Follow the interactive prompts:**
   - Select your Windows partition to mount
   - Select your Bluetooth adapter (if more than one)
   - Choose to copy all keys or a single device
   - The script will extract, convert, and update the Linux Bluetooth info files
5. **Reboot your system** for the changes to take effect.

---

## What the Script Does
- Mounts your Windows partition read-only
- Installs `reglookup` if not yet exist
- Extracts Bluetooth pairing keys from the Windows registry
- Converts the key format for Linux
- Updates the correct info file in `/var/lib/bluetooth/`
- Handles permissions and cleanup

---

## Troubleshooting
- **Device not working after reboot?**
  - Double-check the pairing order (Linux first, then Windows)
- **Permission errors?**
  - Always run the script with `sudo` to ensure access to system files
- **BitLocker-encrypted Windows partition?**
  - You must unlock it before running the script

---

## References
- [Shared Bluetooth devices in dual-boot PC](https://www.castoriscausa.com/posts/2021/02/28/bluetooth-dual-boot/)
- [Arch Wiki: Dual boot Bluetooth](https://wiki.archlinux.org/title/Bluetooth#Dual_boot_pairing)

---

