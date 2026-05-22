#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATIC_IPS_FILE="$ROOT/terraform/unifi/static_ips.tf"
STATE_DIR="$ROOT/terraform/unifi"
TMP_DIR="${TMPDIR:-/tmp}/homelab-unifi-static-ip-audit.$$"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

if [ ! -f "$STATIC_IPS_FILE" ]; then
  echo "Missing static IP declaration file: $STATIC_IPS_FILE" >&2
  exit 1
fi

if ! command -v tofu >/dev/null 2>&1; then
  echo "OpenTofu is required for reading local state." >&2
  exit 1
fi

awk '
  function clean_value(line) {
    sub(/^[^=]*=[[:space:]]*"/, "", line)
    sub(/".*$/, "", line)
    return line
  }

  /^[[:space:]]*static_ip_assignments[[:space:]]*=[[:space:]]*\{/ {
    in_map = 1
    next
  }

  in_map && /^  \}/ {
    in_map = 0
    next
  }

  in_map && /^    [A-Za-z0-9_]+[[:space:]]*=[[:space:]]*\{/ {
    key = $1
    name = ""
    mac = ""
    fixed_ip = ""
    next
  }

  key && /^[[:space:]]*name[[:space:]]*=/ {
    name = clean_value($0)
    next
  }

  key && /^[[:space:]]*mac[[:space:]]*=/ {
    mac = clean_value($0)
    next
  }

  key && /^[[:space:]]*fixed_ip[[:space:]]*=/ {
    fixed_ip = clean_value($0)
    next
  }

  key && /^    \}/ {
    print key "\t" name "\t" mac "\t" fixed_ip
    key = ""
  }
' "$STATIC_IPS_FILE" | sort > "$TMP_DIR/declared.tsv"

(
  cd "$STATE_DIR"
  tofu state list
) | sed -n 's/^unifi_user\.static_ips\["\([^"]*\)"\]$/\1/p' | sort > "$TMP_DIR/state.keys"

cut -f1 "$TMP_DIR/declared.tsv" > "$TMP_DIR/declared.keys"
comm -23 "$TMP_DIR/declared.keys" "$TMP_DIR/state.keys" > "$TMP_DIR/missing.keys"
comm -13 "$TMP_DIR/declared.keys" "$TMP_DIR/state.keys" > "$TMP_DIR/stale.keys"

declared_count="$(wc -l < "$TMP_DIR/declared.keys" | tr -d ' ')"
tracked_count="$(wc -l < "$TMP_DIR/state.keys" | tr -d ' ')"
missing_count="$(wc -l < "$TMP_DIR/missing.keys" | tr -d ' ')"
stale_count="$(wc -l < "$TMP_DIR/stale.keys" | tr -d ' ')"

echo "UniFi static IP IaC/state audit"
echo "================================"
echo "Declared reservations: $declared_count"
echo "Tracked in state:      $tracked_count"
echo "Missing from state:    $missing_count"
echo "Stale state entries:   $stale_count"
echo

if [ "$missing_count" -gt 0 ]; then
  echo "Declared reservations missing from local state:"
  printf '%s\t%s\t%s\t%s\n' "KEY" "NAME" "MAC" "FIXED_IP"
  while IFS= read -r key; do
    awk -F '\t' -v lookup="$key" '$1 == lookup { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$TMP_DIR/declared.tsv"
  done < "$TMP_DIR/missing.keys"
  echo

  echo "Import command templates:"
  while IFS= read -r key; do
    mac="$(awk -F '\t' -v lookup="$key" '$1 == lookup { print $3 }' "$TMP_DIR/declared.tsv")"
    printf "# MAC %s\n" "$mac"
    printf "tofu import 'unifi_user.static_ips[\"%s\"]' '<unifi-client-object-id>'\n" "$key"
  done < "$TMP_DIR/missing.keys"
  echo
fi

if [ "$stale_count" -gt 0 ]; then
  echo "State entries with no matching declaration:"
  cat "$TMP_DIR/stale.keys"
  echo
fi

echo "This script only reads terraform/unifi/static_ips.tf and local OpenTofu state."
