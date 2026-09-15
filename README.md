# btkeys.sh

Copy Bluetooth pairing keys from a Windows install to Linux, so a dual-boot
machine keeps its devices paired on both sides.

**Disclaimer:** use at your own risk. The script rewrites live BlueZ pairing
state.

---

## Why this is needed

Each OS negotiates its own link key when you pair a device, and the device only
remembers the most recent one. Pair in Windows and the device stops working in
Linux, and the other way round. Copying the key Windows negotiated into the
BlueZ database makes both systems present the same key, so the device stays
paired for both.

---

## Pairing order

**Pair on Linux first, then on Windows.**

1. Boot Linux, pair the device normally. This creates the BlueZ directory the
   script writes into.
2. Boot Windows, pair the same device.
3. Boot back into Linux and run the script.

Devices with no Linux pairing are listed as skipped, not created. The script
cannot invent a BlueZ device directory for you.

---

## Prerequisites

- Root (`sudo`)
- `reglookup` (installed automatically via apt, dnf or pacman if missing)
- A Windows partition that is readable, so not BitLocker-locked. Already
  mounted is fine, it is reused and left alone.

---

## Usage

```bash
sudo ./btkeys.sh --dry-run    # show what would change, write nothing
sudo ./btkeys.sh              # pick one device interactively, default is 1
sudo ./btkeys.sh --all        # copy every device without prompting
sudo ./btkeys.sh --device /dev/nvme0n1p3   # skip partition auto-detection
sudo ./btkeys.sh --help
```

Start with `--dry-run`. It prints the full plan, including the exact values it
would write, and touches nothing.

No reboot is needed. The script stops `bluetooth.service` while it writes and
restarts it on exit. If a device still refuses to connect, power it off and on
so it re-negotiates with the shared key.

---

## What it does

1. Checks for `reglookup` and installs it if missing.
2. Restores `/var/lib/bluetooth` to mode 700 if it was left world-readable.
   Earlier versions of this script loosened it, which exposed every link key on
   the machine to all local users.
3. Finds the Windows system hive. An already-mounted NTFS filesystem is reused;
   otherwise every NTFS partition is probed and mounted read-only in a temp
   directory, then unmounted on exit.
4. Picks the active control set by probing `ControlSet001`, `002` and `003`, so
   a machine that booted from a rollback set still works.
5. Matches the Windows adapter MAC against the directories under
   `/var/lib/bluetooth`. A single match is used automatically, several prompt.
6. Reads both pairing types: BR/EDR link keys (a binary registry value named
   after the remote MAC) and LE keys (a subkey holding LTK, ERand, EDIV,
   KeyLength and IRK).
7. Builds a plan and prints it as a table, with the reason for every device it
   is not touching.
8. Writes the selected devices, after backing each `info` file up to
   `info.btkeys.bak`.

Byte-order details the script handles for you: `reglookup` prints binary values
as a mix of printable ASCII and percent escapes; ERand and EDIV are stored
little-endian and BlueZ wants decimal; the IRK is stored in the opposite byte
order to BlueZ.

---

## Tests

```bash
./test_btkeys.sh
```

Covers the pure helpers (`reg_to_hex`, `to_linux_mac`, `is_link_key`,
`le_hex_to_dec`, `reverse_hex`, `ini_set`, `apply_entry`, `abbrev_key`, `fit`). The test suite
sources the script with `BTKEYS_LIB_ONLY=1`, which makes it stop before any
side effects.

---

## Troubleshooting

- **Device not working after the copy**: check the pairing order. Linux first,
  then Windows.
- **"no partition containing ... found"**: pass the partition explicitly with
  `--device`.
- **"no ... key in this hive"**: nothing has ever been paired in Windows on
  this adapter.
- **"not paired on Linux yet"**: pair the device once in Linux, then re-run.
- **BitLocker**: unlock the partition before running.
- **Undo a change**: restore the backup, for example
  `sudo cp /var/lib/bluetooth/<adapter>/<device>/info.btkeys.bak \
  /var/lib/bluetooth/<adapter>/<device>/info`, then restart
  `bluetooth.service`.

---

## References

- [Shared Bluetooth devices in dual-boot PC](https://www.castoriscausa.com/posts/2021/02/28/bluetooth-dual-boot/)
- [Arch Wiki: Dual boot Bluetooth](https://wiki.archlinux.org/title/Bluetooth#Dual_boot_pairing)
