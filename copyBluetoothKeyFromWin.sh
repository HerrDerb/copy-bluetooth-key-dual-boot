if [ -z "$BASH_VERSION" ]; then
    # Ensure the script is always run with bash (for arrays, etc.)
    exec bash "$0" "$@"
fi
#!/bin/bash


# copyBluetoothKeyFromWin.sh
# ---------------------------------------------
# This script copies Bluetooth pairing keys from a Windows machine to a Linux machine for dual-boot scenarios.
#
# Steps performed:
# 1. Setup: Ensures mount point exists, installs reglookup if needed, and sets permissions on /var/lib/bluetooth.
# 2. Mount: Lists available disks, lets you select the Windows partition, and mounts it read-only.
# 3. Extract: Finds all Bluetooth MACs paired in Windows, lets you select one (auto-selects if only one).
# 4. Key Copy: Lists all paired remote MACs for the selected adapter, lets you copy all or a single key.
#    Converts the Windows registry key format to the Linux info file format and writes it to the correct file.
# 5. Cleanup: Reminds you to restore permissions if needed.
#
# Also see: https://www.castoriscausa.com/posts/2021/02/28/bluetooth-dual-boot/



# Exit immediately if a command exits with a non-zero status
set -e


# Constants
MOUNT_POINT="/mnt/windows"  # Where the Windows partition will be mounted
REG_FILE="Windows/System32/config/SYSTEM"  # Windows SYSTEM registry hive
LINUX_BT_PATH="/var/lib/bluetooth"  # Linux Bluetooth config directory


# --- Functions ---

# Converts a mixed percent-encoded and ASCII string (from Windows registry) to a pure uppercase hex string for Linux Bluetooth info file.
# Example: "%80%F0%99o)%CF+P8X%96%0A%91%FE%DA<" -> "80F0996F29CF2B503858960A91FEDA3C"
parse_key_for_linux_info() {
    local input="$1"
    local output=""
    local i=0
    while [ $i -lt ${#input} ]; do
        c="${input:$i:1}"
        if [ "$c" = "%" ]; then
            output+="${input:$((i+1)):2}"
            i=$((i+3))
        else
            printf -v hex "%02X" "'${input:$i:1}'"
            output+="$hex"
            i=$((i+1))
        fi
    done
    echo "$output"
}

# Extracts, parses, and sets the key for a given remote MAC.
process_and_set_key() {
    local bt_mac="$1"
    local remote_mac="$2"
    local local_mac="$3"
    local exit_on_fail="$4"
    # Extract the raw key from the Windows registry for this pairing
    RAW_KEY=$(reglookup -p "ControlSet001/Services/BTHPORT/Parameters/Keys/$bt_mac/$remote_mac" "$REG_PATH" | awk -F',' 'NR==2{print $3}')
    # Convert the Windows key format to a Linux-compatible hex string
    KEY_HEX=$(parse_key_for_linux_info "$RAW_KEY")
    if [ -z "$KEY_HEX" ]; then
        echo "No key found for $remote_mac. ->  ControlSet001/Services/BTHPORT/Parameters/Keys/$bt_mac/$remote_mac"
        if [ "$exit_on_fail" = "exit" ]; then
            exit 1
        else
            return 1
        fi
    fi
    # Convert remote MAC to Linux format (colon-separated, uppercase)
    LINUX_REMOTE_MAC=$(to_linux_mac "$remote_mac")
    # Write the key to the Linux info file
    set_link_key "$local_mac" "$LINUX_REMOTE_MAC" "$KEY_HEX" || {
        if [ "$exit_on_fail" = "exit" ]; then exit 1; else return 1; fi
    }
}

# Converts a 12-digit hex MAC (e.g. D8B32FF7A7E2) to colon-separated uppercase (e.g. D8:B3:2F:F7:A7:E2)
to_linux_mac() {
    echo "$1" | sed 's/../&:/g;s/:$//' | tr 'a-f' 'A-F'
}

# Sets the LinkKey in the Linux Bluetooth info file for a given local and remote MAC.
# - local_mac: local Bluetooth adapter MAC (colon-separated, uppercase)
# - remote_mac: remote device MAC (colon-separated, uppercase)
# - key_hex: hex string (no delimiters)
set_link_key() {
    local local_mac="$1"
    local remote_mac="$2"
    local key_hex="$3"
    local info_file="$LINUX_BT_PATH/$local_mac/$remote_mac/info"
    if [ ! -f "$info_file" ]; then
        echo "Linux Bluetooth info file not found: $info_file"
        return 1
    fi
    echo "Setting key for $remote_mac in $info_file..."
    sudo sed -i "/^\[LinkKey\]/,/^\[/ s/^Key=.*/Key=$key_hex/" "$info_file"
    if [ $? -ne 0 ]; then
        echo "Failed to set key for $remote_mac in $info_file."
        return 1
    fi
    echo "Key set successfully for $remote_mac."
}

# 1. Setup: Ensure mount point exists, reglookup is installed, and permissions are set
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point at $MOUNT_POINT..."
    sudo mkdir -p "$MOUNT_POINT"
fi

# Install reglookup if not present
if ! command -v reglookup &> /dev/null; then
    echo "Installing reglookup..."
    sudo apt-get update && sudo apt-get install -y reglookup
    echo "Cleaning up unused packages..."
    sudo apt autoremove -y
fi

# Set write permissions on Bluetooth config dir (required for key update)
echo "Setting write permissions on $LINUX_BT_PATH (may be insecure, revert after use)"
sudo chmod 777 "$LINUX_BT_PATH"

# 2. Mounting the Windows disk
echo "Searching for available disks..."
# List all partitions (type 'part')
DISKS=( $(lsblk -lnpo NAME,TYPE | awk '$2=="part"{print $1}') )
if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No disks found. Exiting."
    exit 1
fi
echo "Available disks/partitions:"
for i in "${!DISKS[@]}"; do
    echo "$i) ${DISKS[$i]}"
done
echo -n "Select the number of your Windows partition [0]: "
read -r DISK_IDX
DISK_IDX=${DISK_IDX:-0}
WIN_DEV="${DISKS[$DISK_IDX]}"
# Mount the selected Windows partition read-only
if ! mount | grep -q "$MOUNT_POINT"; then
    echo "Mounting $WIN_DEV to $MOUNT_POINT..."
    sudo mount -o ro "$WIN_DEV" "$MOUNT_POINT"
fi

# 3. List available Bluetooth devices from Windows registry
# Set path to Windows SYSTEM registry hive
REG_PATH="$MOUNT_POINT/$REG_FILE"
if [ ! -f "$REG_PATH" ]; then
    echo "Registry file not found at $REG_PATH. Exiting."
    exit 1
fi





# List Bluetooth MACs directly under Keys (parse reglookup -p output for direct children)
echo "Extracting Bluetooth MAC addresses from Windows registry..."
# Find all subkeys under .../Keys that are 12 hex digits (Bluetooth MACs)
BT_MACS=( $(reglookup -p 'ControlSet001/Services/BTHPORT/Parameters/Keys' "$REG_PATH" \
    | awk -F',' -v base="/ControlSet001/Services/BTHPORT/Parameters/Keys/" '
        BEGIN { seen["" ] = 1 }
        NR > 1 {
            path = $1
            sub(base, "", path)
            if (match(path, /^[0-9a-fA-F]{12}$/)) {
                if (!(path in seen)) {
                    print path
                    seen[path]=1
                }
            }
        }'
    ) )


# Handle MAC selection (auto-select if only one, else prompt)
if [ ${#BT_MACS[@]} -eq 0 ]; then
    echo "No Bluetooth devices found in Windows registry."
    exit 1
fi
if [ ${#BT_MACS[@]} -eq 1 ]; then
    BT_MAC="${BT_MACS[0]}"
    echo "Only one Bluetooth MAC found: $BT_MAC. Selecting automatically."
else
    echo "Found the following Bluetooth device MACs in Windows registry:"
    for i in "${!BT_MACS[@]}"; do
        echo "$i) ${BT_MACS[$i]}"
    done
    echo -n "Select the number of the Bluetooth MAC to use [0]: "
    read -r BT_IDX
    BT_IDX=${BT_IDX:-0}
    BT_MAC="${BT_MACS[$BT_IDX]}"
fi


# --- Functions ---
to_linux_mac() {
    echo "$1" | sed 's/../&:/g;s/:$//' | tr 'a-f' 'A-F'
}

set_link_key() {
    local local_mac="$1"
    local remote_mac="$2"
    local key_hex="$3"
    local info_file="$LINUX_BT_PATH/$local_mac/$remote_mac/info"
    if [ ! -f "$info_file" ]; then
        echo "Linux Bluetooth info file not found: $info_file"
        return 1
    fi
    echo "Setting key for $remote_mac in $info_file..."
    sudo sed -i "/^\[LinkKey\]/,/^\[/ s/^Key=.*/Key=$key_hex/" "$info_file"
    if [ $? -ne 0 ]; then
        echo "Failed to set key for $remote_mac in $info_file."
        return 1
    fi
    echo "Key set successfully for $remote_mac."
}


# 4. Extract and copy the key(s)
echo "Extracting keys for device $BT_MAC..."
# Find all paired remote MACs (subkeys that are 12 hex digits)
SUBKEYS=$(reglookup -p "ControlSet001/Services/BTHPORT/Parameters/Keys/$BT_MAC" "$REG_PATH" | grep -Eo "$BT_MAC/[0-9A-Fa-f]{12}" | awk -F'/' '{print $2}')
if [ -z "$SUBKEYS" ]; then
    echo "No paired devices found for $BT_MAC."
    exit 1
fi

# Ask user if they want to copy all keys or just one
echo "Do you want to copy all keys for this device, or just one?"
select COPY_MODE in "All" "Single"; do
    if [ "$COPY_MODE" = "All" ] || [ "$COPY_MODE" = "Single" ]; then
        break
    fi
done

# Convert Windows MAC to Linux format (colon-separated, uppercase)
LINUX_LOCAL_MAC=$(to_linux_mac "$BT_MAC")

if [ "$COPY_MODE" = "All" ]; then
    # Copy all paired keys for this adapter
    for REMOTE_MAC in $SUBKEYS; do
        process_and_set_key "$BT_MAC" "$REMOTE_MAC" "$LINUX_LOCAL_MAC" "continue"
    done
    echo "Done copying all keys. Please reboot your system for changes to take effect."
else
    # Let user select a single paired device
    echo "Found paired devices (remote MACs):"
    select REMOTE_MAC in $SUBKEYS; do
        if [ -n "$REMOTE_MAC" ]; then
            break
        fi
    done
    process_and_set_key "$BT_MAC" "$REMOTE_MAC" "$LINUX_LOCAL_MAC" "exit"
    echo "Done. Please reboot your system for changes to take effect."
fi
fi



