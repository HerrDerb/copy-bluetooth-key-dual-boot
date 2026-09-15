#!/usr/bin/env bash
#
# btkeys.sh - copy Bluetooth pairing keys from a Windows install to Linux.
#
# On a dual-boot machine each OS re-pairs a Bluetooth device with a fresh link
# key, and the device only remembers the most recent one. Copying the key that
# Windows negotiated into the BlueZ database makes both OSes present the same
# key, so the device stays paired on both sides.
#
# Requires: root, reglookup, an already-existing Linux pairing for each device
# (pair once on Linux first, so BlueZ has a device directory to update).
#
#   sudo ./btkeys.sh                # auto-detect everything, ask before writing
#   sudo ./btkeys.sh --dry-run      # show what would change, touch nothing
#   sudo ./btkeys.sh --all          # copy every device without prompting
#
# Background: https://www.castoriscausa.com/posts/2021/02/28/bluetooth-dual-boot/

# Re-exec under bash when invoked as `sh btkeys.sh`: this script needs arrays,
# [[ ]] and pipefail, none of which dash provides.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

BT_DIR="/var/lib/bluetooth"
REG_HIVE_REL="Windows/System32/config/SYSTEM"
BT_REG_BASE="Services/BTHPORT/Parameters/Keys"

# --------------------------------------------------------------------------
# Pure helpers. No side effects, no globals - test_btkeys.sh exercises these.
# --------------------------------------------------------------------------

# reglookup prints binary values as printable ASCII with every other byte
# percent-encoded, e.g. "%80%F0%99o)%CF+P8X%96%0A%91%FE%DA<". Turn that mixed
# representation back into a plain uppercase hex string.
reg_to_hex() {
    local input="$1" output="" i=0 c hex
    while [ "$i" -lt "${#input}" ]; do
        c="${input:$i:1}"
        if [ "$c" = "%" ]; then
            # A percent escape is already hex; just normalise the case.
            hex="${input:$((i + 1)):2}"
            output+="${hex^^}"
            i=$((i + 3))
        else
            printf -v hex '%02X' "'$c"
            output+="$hex"
            i=$((i + 1))
        fi
    done
    printf '%s' "$output"
}

# D8B32FF7A7E2 (or d8:b3:2f:f7:a7:e2) -> D8:B3:2F:F7:A7:E2
to_linux_mac() {
    local mac="${1//:/}"
    [[ "$mac" =~ ^[0-9a-fA-F]{12}$ ]] || return 1
    mac="${mac^^}"
    printf '%s' "${mac:0:2}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"
}

# A BR/EDR link key and an LE LTK are both 16 bytes.
is_link_key() {
    [[ "${1:-}" =~ ^[0-9A-F]{32}$ ]]
}

# ERand and EDIV are stored little-endian in the registry; BlueZ wants decimal.
le_hex_to_dec() {
    local hex="$1" be=""
    [[ "$hex" =~ ^([0-9a-fA-F]{2})+$ ]] || return 1
    be="$(reverse_hex "$hex")"
    printf '%d' "$((16#$be))"
}

# AABBCCDD -> DDCCBBAA
reverse_hex() {
    local hex="${1^^}" out="" i
    [[ "$hex" =~ ^([0-9A-F]{2})+$ ]] || return 1
    for ((i = ${#hex} - 2; i >= 0; i -= 2)); do
        out+="${hex:$i:2}"
    done
    printf '%s' "$out"
}

# 32 hex chars is too wide for a table; show enough to eyeball a difference.
abbrev_key() {
    local k="${1:-}"
    if   [ -z "$k" ];        then printf '%s' '-'
    elif [ "${#k}" -le 12 ]; then printf '%s' "$k"
    else printf '%s..%s' "${k:0:6}" "${k: -4}"
    fi
}

# Pad or truncate to exactly $2 columns, so table cells line up.
fit() {
    local str="${1:-}" width="$2"
    if [ "${#str}" -le "$width" ]; then
        printf '%-*s' "$width" "$str"
    else
        printf '%s..' "${str:0:$((width - 2))}"
    fi
}

# Set key=value inside [section] of a BlueZ info file, creating either the key
# or the whole section if needed. Prints the new file to stdout.
ini_set() {
    local file="$1" section="$2" key="$3" value="$4"
    awk -v want="$section" -v key="$key" -v value="$value" '
        function flush_pending() {
            if (in_want && !done) { print key "=" value; done = 1 }
        }
        /^\[/ {
            flush_pending()
            in_want = ($0 == "[" want "]")
            if (in_want) seen = 1
        }
        in_want && index($0, key "=") == 1 {
            if (!done) { print key "=" value; done = 1 }
            next
        }
        { print }
        END {
            flush_pending()
            if (!seen) { print "[" want "]"; print key "=" value }
        }
    ' "$file"
}

# Rewrite a BlueZ info file in place via ini_set, keeping owner and mode.
write_ini() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    tmp="$(mktemp)"
    ini_set "$file" "$section" "$key" "$value" > "$tmp"
    cat "$tmp" > "$file"   # preserve the original owner and mode
    rm -f "$tmp"
}

# Write one planned pairing into its info file. kind is "BR/EDR" or "LE";
# rand/ediv/encsize/irk are only used for LE.
apply_entry() {
    local file="$1" kind="$2" key="$3" rand="${4:-}" ediv="${5:-}" encsize="${6:-}" irk="${7:-}"
    if [ "$kind" = "BR/EDR" ]; then
        write_ini "$file" "LinkKey" "Key" "$key"
    else
        write_ini "$file" "LongTermKey" "Key"     "$key"
        write_ini "$file" "LongTermKey" "Rand"    "$rand"
        write_ini "$file" "LongTermKey" "EDiv"    "$ediv"
        write_ini "$file" "LongTermKey" "EncSize" "$encsize"
        [ -z "$irk" ] || write_ini "$file" "IdentityResolvingKey" "Key" "$irk"
    fi
}

# Sourced by the test suite: stop here, do not run the tool.
[ -n "${BTKEYS_LIB_ONLY:-}" ] && return 0

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'
else
    C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""
fi
info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()    { printf '  %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
dim()   { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { printf '\n%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
DRY_RUN=0
COPY_ALL=0
WIN_DEV=""
MOUNT_POINT=""

usage() {
    # Print the header comment block: everything from line 2 up to the first
    # line that is not a comment. No hardcoded line numbers to drift.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -a|--all)     COPY_ALL=1 ;;
        -d|--device)  WIN_DEV="${2:-}"; shift ;;
        -h|--help)    usage 0 ;;
        *)            printf 'unknown option: %s\n\n' "$1" >&2; usage 1 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run me as root, e.g. sudo $0 --dry-run"

# --------------------------------------------------------------------------
# Cleanup: always unmount what we mounted and leave BlueZ running.
# --------------------------------------------------------------------------
MOUNTED_BY_US=""
BLUETOOTH_WAS_ACTIVE=""

cleanup() {
    local rc=$?
    if [ -n "$MOUNTED_BY_US" ]; then
        umount "$MOUNTED_BY_US" 2>/dev/null && rmdir "$MOUNTED_BY_US" 2>/dev/null || true
    fi
    if [ "$BLUETOOTH_WAS_ACTIVE" = "yes" ]; then
        systemctl start bluetooth 2>/dev/null || true
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# 1. Dependencies
# --------------------------------------------------------------------------
step "Checking dependencies"
if ! command -v reglookup >/dev/null 2>&1; then
    info "  reglookup missing, installing..."
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y reglookup
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y reglookup
    elif command -v pacman  >/dev/null 2>&1; then pacman -S --noconfirm reglookup
    else die "install 'reglookup' with your package manager and re-run"
    fi
fi
ok "reglookup $(command -v reglookup)"

# The old version of this script left /var/lib/bluetooth world-writable, which
# exposes every link key on the machine. Running as root makes that
# unnecessary, so put the permissions back if we find them loosened.
BT_DIR_MODE="$(stat -c '%a' "$BT_DIR")"
if [ "$BT_DIR_MODE" != "700" ]; then
    warn "$BT_DIR is mode $BT_DIR_MODE (link keys readable by other users) - restoring 700"
    [ "$DRY_RUN" -eq 1 ] || chmod 700 "$BT_DIR"
fi

# --------------------------------------------------------------------------
# 2. Find and mount the Windows system partition
# --------------------------------------------------------------------------
step "Locating the Windows installation"

REG_HIVE=""

try_partition() {
    # Mount $1 read-only somewhere temporary and keep it if it holds the hive.
    local dev="$1" mnt
    mnt="$(mktemp -d /tmp/btkeys-win.XXXXXX)"
    if ! mount -o ro "$dev" "$mnt" 2>/dev/null; then
        rmdir "$mnt"; return 1
    fi
    if [ -f "$mnt/$REG_HIVE_REL" ]; then
        MOUNTED_BY_US="$mnt"
        MOUNT_POINT="$mnt"
        REG_HIVE="$mnt/$REG_HIVE_REL"
        return 0
    fi
    umount "$mnt"; rmdir "$mnt"; return 1
}

# An already-mounted Windows filesystem is reused as-is (and never unmounted).
while read -r mnt; do
    [ -f "$mnt/$REG_HIVE_REL" ] || continue
    MOUNT_POINT="$mnt"
    REG_HIVE="$mnt/$REG_HIVE_REL"
    ok "using already-mounted $mnt"
    break
done < <(findmnt -rno TARGET -t ntfs,ntfs3,fuseblk 2>/dev/null || true)

if [ -z "$REG_HIVE" ] && [ -n "$WIN_DEV" ]; then
    try_partition "$WIN_DEV" || die "$WIN_DEV does not contain $REG_HIVE_REL"
    ok "mounted $WIN_DEV read-only at $MOUNT_POINT"
fi

if [ -z "$REG_HIVE" ]; then
    # Probe every NTFS partition rather than making the user guess a number.
    while read -r dev; do
        dim "probing $dev ..."
        if try_partition "$dev"; then
            ok "found Windows on $dev, mounted read-only at $MOUNT_POINT"
            break
        fi
    done < <(lsblk -lnpo NAME,TYPE,FSTYPE | awk '$2=="part" && ($3=="ntfs" || $3=="ntfs3"){print $1}')
fi

[ -n "$REG_HIVE" ] || die "no partition containing $REG_HIVE_REL found (pass --device /dev/nvme0n1p3)"

# --------------------------------------------------------------------------
# 3. Pick a control set. Windows may boot from ControlSet002 after a rollback,
#    so do not hardcode 001.
# --------------------------------------------------------------------------
reg() { reglookup -p "$1" "$REG_HIVE" 2>/dev/null; }

CONTROL_SET=""
for cs in ControlSet001 ControlSet002 ControlSet003; do
    if reg "$cs/$BT_REG_BASE" | grep -q .; then
        CONTROL_SET="$cs"
        break
    fi
done
[ -n "$CONTROL_SET" ] || die "no $BT_REG_BASE key in this hive - has anything ever been paired in Windows?"
KEYS_PATH="$CONTROL_SET/$BT_REG_BASE"
ok "registry: $KEYS_PATH"

# --------------------------------------------------------------------------
# 4. Pick the adapter. The Windows adapter MAC and the BlueZ directory name are
#    the same physical radio, so we can match them automatically.
# --------------------------------------------------------------------------
step "Matching Bluetooth adapters"

mapfile -t WIN_ADAPTERS < <(
    reg "$KEYS_PATH" | awk -F',' -v base="/$KEYS_PATH/" '
        NR > 1 {
            path = $1
            sub(base, "", path)
            if (path ~ /^[0-9a-fA-F]{12}$/ && !(path in seen)) { print toupper(path); seen[path] = 1 }
        }'
)
[ "${#WIN_ADAPTERS[@]}" -gt 0 ] || die "no adapters found under $KEYS_PATH"

ADAPTERS=()
for a in "${WIN_ADAPTERS[@]}"; do
    linux_mac="$(to_linux_mac "$a")"
    if [ -d "$BT_DIR/$linux_mac" ]; then
        ADAPTERS+=("$a")
        ok "$linux_mac (present in Windows and in BlueZ)"
    else
        dim "$linux_mac - in Windows only, no BlueZ directory, skipping"
    fi
done

if [ "${#ADAPTERS[@]}" -eq 0 ]; then
    die "none of the Windows adapters exist under $BT_DIR - is the radio the same machine?"
elif [ "${#ADAPTERS[@]}" -eq 1 ]; then
    WIN_ADAPTER="${ADAPTERS[0]}"
else
    info "Several adapters match. Which one?"
    select choice in "${ADAPTERS[@]}"; do
        [ -n "$choice" ] && { WIN_ADAPTER="$choice"; break; }
    done
fi
LINUX_ADAPTER="$(to_linux_mac "$WIN_ADAPTER")"

# --------------------------------------------------------------------------
# 5. Collect the pairings. Windows stores BR/EDR link keys as values named
#    after the remote MAC, and LE keys as a subkey per remote MAC holding
#    LTK / ERand / EDIV / IRK.
# --------------------------------------------------------------------------
step "Reading pairings for $LINUX_ADAPTER"

ADAPTER_PATH="$KEYS_PATH/$WIN_ADAPTER"
ADAPTER_DUMP="$(reg "$ADAPTER_PATH")"

declare -A CLASSIC_KEY=()
LE_DEVICES=()

while IFS=',' read -r path type value _rest; do
    name="${path##*/}"
    [[ "$name" =~ ^[0-9a-fA-F]{12}$ ]] || continue
    case "$type" in
        KEY)  LE_DEVICES+=("${name^^}") ;;
        BINARY) CLASSIC_KEY["${name^^}"]="$value" ;;
    esac
done <<< "$ADAPTER_DUMP"

# Read one named value out of an LE device's subkey.
le_value() {
    local dev="$1" name="$2"
    reg "$ADAPTER_PATH/$dev" \
        | awk -F',' -v want="/$ADAPTER_PATH/$dev/$name" '$1 == want { print $3; exit }'
}

DEVICES=()
for mac in "${!CLASSIC_KEY[@]}"; do DEVICES+=("$mac"); done
for mac in "${LE_DEVICES[@]}";   do DEVICES+=("$mac"); done
[ "${#DEVICES[@]}" -gt 0 ] || die "no paired devices under $ADAPTER_PATH"

# --------------------------------------------------------------------------
# 6. Work out the change for each device, without writing yet.
# --------------------------------------------------------------------------
PLAN_MAC=(); PLAN_NAME=(); PLAN_KIND=(); PLAN_DESC=(); PLAN_OLD=()
PLAN_LTK=(); PLAN_RAND=(); PLAN_EDIV=(); PLAN_ENCSIZE=(); PLAN_IRK=()
IDLE_MAC=(); IDLE_NAME=(); IDLE_REASON=()

note_idle() { IDLE_MAC+=("$1"); IDLE_NAME+=("$2"); IDLE_REASON+=("$3"); }

# Read Key= out of one section of a BlueZ info file.
info_key() {
    awk -v want="[$2]" '
        $0 == want { f = 1; next }
        /^\[/      { f = 0 }
        f && index($0, "Key=") == 1 { sub(/^Key=/, ""); print; exit }
    ' "$1"
}

for win_mac in "${DEVICES[@]}"; do
    linux_mac="$(to_linux_mac "$win_mac")"
    info_file="$BT_DIR/$LINUX_ADAPTER/$linux_mac/info"

    if [ ! -f "$info_file" ]; then
        note_idle "$linux_mac" "-" "not paired on Linux yet (pair it here once first)"
        continue
    fi

    dev_name="$(awk -F= '/^Name=/{ sub(/^Name=/, ""); print; exit }' "$info_file")"
    : "${dev_name:=unknown}"

    if [ -n "${CLASSIC_KEY[$win_mac]+x}" ]; then
        key="$(reg_to_hex "${CLASSIC_KEY[$win_mac]}")"
        if ! is_link_key "$key"; then
            note_idle "$linux_mac" "$dev_name" "registry link key is not 16 bytes"
            continue
        fi
        current="$(info_key "$info_file" LinkKey)"
        if [ "$current" = "$key" ]; then
            note_idle "$linux_mac" "$dev_name" "already has the Windows key"
            continue
        fi
        PLAN_MAC+=("$linux_mac"); PLAN_NAME+=("$dev_name"); PLAN_KIND+=("BR/EDR")
        PLAN_DESC+=("LinkKey.Key = $key")
        PLAN_OLD+=("$current")
        PLAN_LTK+=("$key"); PLAN_RAND+=(""); PLAN_EDIV+=(""); PLAN_ENCSIZE+=(""); PLAN_IRK+=("")
        continue
    fi

    # LE device
    ltk="$(reg_to_hex "$(le_value "$win_mac" LTK)")"
    if ! is_link_key "$ltk"; then
        note_idle "$linux_mac" "$dev_name" "no usable LTK in the registry"
        continue
    fi
    rand="$(le_hex_to_dec "$(reg_to_hex "$(le_value "$win_mac" ERand)")" 2>/dev/null || echo 0)"
    ediv="$(le_hex_to_dec "$(reg_to_hex "$(le_value "$win_mac" EDIV)")" 2>/dev/null || echo 0)"
    encsize="$(le_hex_to_dec "$(reg_to_hex "$(le_value "$win_mac" KeyLength)")" 2>/dev/null || echo 16)"
    [ "$encsize" -ge 7 ] 2>/dev/null || encsize=16
    # BlueZ stores the IRK in the opposite byte order to the registry.
    irk_hex="$(reg_to_hex "$(le_value "$win_mac" IRK)")"
    irk=""
    is_link_key "$irk_hex" && irk="$(reverse_hex "$irk_hex")"

    current="$(info_key "$info_file" LongTermKey)"
    if [ "$current" = "$ltk" ]; then
        note_idle "$linux_mac" "$dev_name" "already has the Windows key"
        continue
    fi
    PLAN_MAC+=("$linux_mac"); PLAN_NAME+=("$dev_name"); PLAN_KIND+=("LE")
    PLAN_DESC+=("LongTermKey.Key = $ltk, EDiv = $ediv, Rand = $rand, EncSize = $encsize${irk:+, IdentityResolvingKey.Key = $irk}")
    PLAN_OLD+=("$current")
    PLAN_LTK+=("$ltk"); PLAN_RAND+=("$rand"); PLAN_EDIV+=("$ediv")
    PLAN_ENCSIZE+=("$encsize"); PLAN_IRK+=("$irk")
done

# --------------------------------------------------------------------------
# 7. Show the plan and choose what to apply.
# --------------------------------------------------------------------------
step "Pairings under $LINUX_ADAPTER"

# Name column is sized to the data so nothing wraps unnecessarily.
NAME_W=4
for n in "${PLAN_NAME[@]}" "${IDLE_NAME[@]}"; do
    [ "${#n}" -gt "$NAME_W" ] && NAME_W="${#n}"
done
[ "$NAME_W" -gt 28 ] && NAME_W=28

if [ "${#PLAN_MAC[@]}" -gt 0 ]; then
    printf '\n  %s%s  %s  %s  %s  %s  %s%s\n' "$C_BOLD" \
        " #" "$(fit NAME "$NAME_W")" "$(fit ADDRESS 17)" "$(fit TYPE 6)" \
        "$(fit 'WINDOWS KEY' 14)" "LINUX NOW" "$C_RESET"
    for i in "${!PLAN_MAC[@]}"; do
        printf '  %2d  %s  %s  %s  %s  %s\n' \
            "$((i + 1))" \
            "$(fit "${PLAN_NAME[$i]}" "$NAME_W")" \
            "$(fit "${PLAN_MAC[$i]}" 17)" \
            "$(fit "${PLAN_KIND[$i]}" 6)" \
            "$(fit "$(abbrev_key "${PLAN_LTK[$i]}")" 14)" \
            "$(abbrev_key "${PLAN_OLD[$i]}")"
    done
fi

if [ "${#IDLE_MAC[@]}" -gt 0 ]; then
    printf '\n  %sNot changing:%s\n' "$C_DIM" "$C_RESET"
    for i in "${!IDLE_MAC[@]}"; do
        printf '  %s      %s  %s  %s%s\n' "$C_DIM" \
            "$(fit "${IDLE_NAME[$i]}" "$NAME_W")" \
            "$(fit "${IDLE_MAC[$i]}" 17)" \
            "${IDLE_REASON[$i]}" "$C_RESET"
    done
fi

if [ "${#PLAN_MAC[@]}" -eq 0 ]; then
    printf '\n'
    ok "nothing to do - every device paired on both sides already matches"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    step "Would write"
    for i in "${!PLAN_MAC[@]}"; do
        printf '  %s%s  %s%s\n' "$C_BOLD" "${PLAN_MAC[$i]}" "${PLAN_NAME[$i]}" "$C_RESET"
        dim "  ${PLAN_DESC[$i]}"
    done
    step "Dry run - nothing written"
    exit 0
fi

# Default is a single device: this rewrites live pairing state, so the safe
# choice should be the one you get by pressing Enter.
SELECTED=()
if [ "$COPY_ALL" -eq 1 ]; then
    SELECTED=("${!PLAN_MAC[@]}")
else
    while true; do
        printf '\n%sWhich device?%s [1]   (a = all, q = cancel)\n> ' "$C_BOLD" "$C_RESET"
        read -r answer || answer="q"
        answer="${answer:-1}"
        case "$answer" in
            q|Q|quit|cancel) info "Nothing changed."; exit 0 ;;
            a|A|all)         SELECTED=("${!PLAN_MAC[@]}"); break ;;
            *)
                SELECTED=()
                valid=1
                for token in $answer; do
                    if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#PLAN_MAC[@]}" ]; then
                        SELECTED+=("$((token - 1))")
                    else
                        warn "not a device number: $token"
                        valid=0
                    fi
                done
                [ "$valid" -eq 1 ] && [ "${#SELECTED[@]}" -gt 0 ] && break
                ;;
        esac
    done
fi

# --------------------------------------------------------------------------
# 8. Apply. bluetoothd keeps these files in memory and rewrites them on exit,
#    so it has to be stopped first or the change is silently reverted.
# --------------------------------------------------------------------------
step "Applying"
if systemctl is-active --quiet bluetooth; then
    BLUETOOTH_WAS_ACTIVE="yes"
    systemctl stop bluetooth
    ok "stopped bluetooth.service (restarted automatically on exit)"
fi

for i in "${SELECTED[@]}"; do
    mac="${PLAN_MAC[$i]}"
    file="$BT_DIR/$LINUX_ADAPTER/$mac/info"
    cp -a "$file" "$file.btkeys.bak"
    apply_entry "$file" "${PLAN_KIND[$i]}" "${PLAN_LTK[$i]}" \
        "${PLAN_RAND[$i]}" "${PLAN_EDIV[$i]}" "${PLAN_ENCSIZE[$i]}" "${PLAN_IRK[$i]}"
    ok "$mac (${PLAN_NAME[$i]}) updated - backup at $(basename "$file").btkeys.bak"
done

step "Done"
info "bluetooth.service restarts as this script exits. No reboot needed."
info "If the device still will not connect, power it off and on to make it"
info "re-negotiate with the key it now shares with both systems."
