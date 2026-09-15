#!/usr/bin/env bash
# Tests for the pure helper functions in btkeys.sh.
# Run: ./test_btkeys.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=btkeys.sh
BTKEYS_LIB_ONLY=1 source "$HERE/btkeys.sh"

pass=0
fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  ok   %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

check_fails() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  FAIL %s (expected non-zero exit)\n' "$name"
        fail=$((fail + 1))
    else
        printf '  ok   %s\n' "$name"
        pass=$((pass + 1))
    fi
}

echo "reg_to_hex"
check "mixed percent-encoded and ASCII" \
    "80F0996F29CF2B503858960A91FEDA3C" \
    "$(reg_to_hex '%80%F0%99o)%CF+P8X%96%0A%91%FE%DA<')"
check "pure ASCII" "414243" "$(reg_to_hex 'ABC')"
check "pure percent-encoded" "00FF10" "$(reg_to_hex '%00%FF%10')"
check "escaped literal percent" "255A" "$(reg_to_hex '%25Z')"
check "lowercase hex escapes are normalised up" "ABCD" "$(reg_to_hex '%ab%cd')"
check "space is a real byte" "204120" "$(reg_to_hex ' A ')"
check "empty input" "" "$(reg_to_hex '')"

echo "to_linux_mac"
check "lowercase 12 hex" "D8:B3:2F:F7:A7:E2" "$(to_linux_mac 'd8b32ff7a7e2')"
check "uppercase 12 hex" "AA:BB:CC:DD:EE:FF" "$(to_linux_mac 'AABBCCDDEEFF')"
check "already colon separated passes through" "AA:BB:CC:DD:EE:FF" "$(to_linux_mac 'aa:bb:cc:dd:ee:ff')"
check_fails "rejects short mac" to_linux_mac 'd8b32f'
check_fails "rejects non-hex" to_linux_mac 'zzzzzzzzzzzz'

echo "is_link_key"
check_fails "rejects 30 hex chars" is_link_key "$(printf 'A%.0s' {1..30})"
check_fails "rejects empty" is_link_key ""
check_fails "rejects non-hex" is_link_key "ZZF0996F29CF2B503858960A91FEDA3C"
if is_link_key "80F0996F29CF2B503858960A91FEDA3C"; then
    echo "  ok   accepts 32 hex chars"; pass=$((pass + 1))
else
    echo "  FAIL accepts 32 hex chars"; fail=$((fail + 1))
fi

echo "le_hex_to_dec (registry stores ERand/EDIV little-endian)"
check "2-byte little-endian"  "1"     "$(le_hex_to_dec '0100')"
check "2-byte little-endian b" "4660" "$(le_hex_to_dec '3412')"
check "8-byte little-endian"  "1"     "$(le_hex_to_dec '0100000000000000')"
check "all zero"              "0"     "$(le_hex_to_dec '0000000000000000')"

echo "reverse_hex (Windows stores the IRK in the opposite byte order)"
check "reverses byte pairs" "DDCCBBAA" "$(reverse_hex 'AABBCCDD')"
check "single byte"         "AA"       "$(reverse_hex 'AA')"

echo "ini_set"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/classic" <<'INI'
[General]
Name=Mouse
[LinkKey]
Key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Type=4
PINLength=0
INI
check "replaces an existing key in place" \
"[General]
Name=Mouse
[LinkKey]
Key=BBBB
Type=4
PINLength=0" \
"$(ini_set "$TMP/classic" LinkKey Key BBBB)"

check "does not touch a same-named key in another section" \
"[General]
Name=NEW
[LinkKey]
Key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Type=4
PINLength=0" \
"$(ini_set "$TMP/classic" General Name NEW)"

cat > "$TMP/nokey" <<'INI'
[General]
Name=Mouse
[LongTermKey]
EncSize=16
INI
check "adds a missing key at the end of its section" \
"[General]
Name=Mouse
[LongTermKey]
EncSize=16
Key=CCCC" \
"$(ini_set "$TMP/nokey" LongTermKey Key CCCC)"

cat > "$TMP/mid" <<'INI'
[LongTermKey]
EncSize=16
[General]
Name=Mouse
INI
check "adds a missing key before the next section, not at EOF" \
"[LongTermKey]
EncSize=16
Key=CCCC
[General]
Name=Mouse" \
"$(ini_set "$TMP/mid" LongTermKey Key CCCC)"

cat > "$TMP/nosection" <<'INI'
[General]
Name=Mouse
INI
check "creates the section when it is absent" \
"[General]
Name=Mouse
[IdentityResolvingKey]
Key=DDDD" \
"$(ini_set "$TMP/nosection" IdentityResolvingKey Key DDDD)"

cat > "$TMP/prefix" <<'INI'
[LongTermKey]
KeyLength=7
Key=AAAA
INI
check "KeyLength= is not mistaken for Key=" \
"[LongTermKey]
KeyLength=7
Key=BBBB" \
"$(ini_set "$TMP/prefix" LongTermKey Key BBBB)"


echo "apply_entry (kind string must match what the plan stores)"
cat > "$TMP/apply_classic" <<'INI'
[General]
Name=Mouse
[LinkKey]
Key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Type=4
PINLength=0
INI
apply_entry "$TMP/apply_classic" "BR/EDR" "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
check "BR/EDR replaces LinkKey.Key and adds no LE section" \
"[General]
Name=Mouse
[LinkKey]
Key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
Type=4
PINLength=0" \
"$(cat "$TMP/apply_classic")"

cat > "$TMP/apply_le" <<'INI'
[General]
Name=Pen
[LongTermKey]
Key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Authenticated=0
EncSize=16
EDiv=1
Rand=2
INI
apply_entry "$TMP/apply_le" "LE" "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" 12345 678 16 "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
check "LE rewrites LTK fields and adds the IRK section" \
"[General]
Name=Pen
[LongTermKey]
Key=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
Authenticated=0
EncSize=16
EDiv=678
Rand=12345
[IdentityResolvingKey]
Key=DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD" \
"$(cat "$TMP/apply_le")"


echo "abbrev_key"
check "shortens a 32-char key"  "80F099..DA3C" "$(abbrev_key '80F0996F29CF2B503858960A91FEDA3C')"
check "short input passes through" "AABB" "$(abbrev_key 'AABB')"
check "empty becomes a dash"       "-"    "$(abbrev_key '')"


echo "fit"
check "pads short input to width"   "abc  "  "$(fit 'abc' 5)"
check "exact width is untouched"    "abcde"  "$(fit 'abcde' 5)"
check "truncates with a marker"     "abc.."  "$(fit 'abcdefgh' 5)"


echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
