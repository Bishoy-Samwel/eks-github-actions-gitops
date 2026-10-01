#!/usr/bin/env bash
#
# Write an AWS CLI profile from a downloaded access-keys CSV, without ever printing
# the secret to stdout, a log, or shell history.
#
# Why this exists: AWS shows an access key pair exactly once and offers it as a CSV
# download. The usual next step — copy-pasting those two values into `aws configure` —
# leaves the secret in your terminal scrollback and your shell history. This reads the
# file directly instead.
#
# Usage:
#   ./setup-aws-profile.sh --csv ~/Downloads/accessKeys.csv --profile myapp
#   ./setup-aws-profile.sh --csv <path> --profile myapp --region eu-central-1
#
# Options:
#   --csv PATH       access-keys CSV downloaded from the IAM console (required)
#   --profile NAME   profile name to write (default: myapp)
#   --region REGION  region to set on the profile (default: eu-central-1)
#   --force          overwrite an existing profile with the same name
#
# Exit codes: 0 ok · 1 usage error · 2 file problem · 3 AWS config write failed · 4 verify failed

set -euo pipefail

CSV=""
PROFILE="myapp"
REGION="eu-central-1"
FORCE=0

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)     CSV="${2:-}";     shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region)  REGION="${2:-}";  shift 2 ;;
    --force)   FORCE=1;          shift ;;
    -h|--help) usage ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[ -n "$CSV" ]     || usage
[ -n "$PROFILE" ] || usage

[ -f "$CSV" ] || die "no such file: $CSV" 2

# Refuse to clobber an existing profile unless asked. Overwriting `default` by accident
# breaks whatever else on this machine was using it.
if [ "$FORCE" -eq 0 ] && aws configure list --profile "$PROFILE" >/dev/null 2>&1; then
  if grep -q "^\[$PROFILE\]$" "$HOME/.aws/credentials" 2>/dev/null; then
    die "profile '$PROFILE' already exists. Re-run with --force to overwrite." 1
  fi
fi

# A world- or group-readable key file is a leaked key file. Fix it and say so.
CSV_MODE="$(stat -c '%a' "$CSV" 2>/dev/null || stat -f '%Lp' "$CSV" 2>/dev/null || echo unknown)"
if [ "$CSV_MODE" != "unknown" ] && [ "$((0$CSV_MODE & 077))" -ne 0 ]; then
  printf 'warning: %s is mode %s; tightening to 600\n' "$CSV" "$CSV_MODE"
  chmod 600 "$CSV"
fi

# Extract in a child python process. Its stdout is captured into a variable and never
# echoed. Parsing handles the UTF-8 BOM Excel adds to the first column name, plus
# trailing whitespace from a copy-paste.
readarray -t KEYS < <(
  python3 - "$CSV" <<'PY'
import csv, sys

with open(sys.argv[1], newline="", encoding="utf-8-sig") as fh:
    rows = list(csv.DictReader(fh))

if not rows:
    sys.exit("CSV has no data rows")

row = rows[0]
ak = (row.get("Access key ID") or "").strip()
sk = (row.get("Secret access key") or "").strip()

# Validate shape before writing. A truncated or mis-pasted value produces an
# InvalidClientTokenId at apply time, which is a much worse place to discover it.
if not ak.startswith("AKIA") or len(ak) != 20:
    sys.exit(f"access key ID does not look like an access key (prefix={ak[:4]!r} len={len(ak)})")
if len(sk) != 40:
    sys.exit(f"secret access key has unexpected length: {len(sk)}")

print(ak)
print(sk)
PY
) || die "could not parse $CSV" 2

AK="${KEYS[0]:-}"
SK="${KEYS[1]:-}"

[ -n "$AK" ] && [ -n "$SK" ] || die "no key values parsed from $CSV" 2

for pair in \
  "aws_access_key_id $AK" \
  "aws_secret_access_key $SK" \
  "region $REGION"
do
  # shellcheck disable=SC2086
  set -- $pair
  aws configure set "$1" "$2" --profile "$PROFILE" >/dev/null \
    || die "failed to write $1 to profile '$PROFILE'" 3
done

printf 'wrote profile %s (region %s) to ~/.aws/{credentials,config}\n' "$PROFILE" "$REGION"

# Confirm which profile now resolves, and who it resolves to. This is the only check
# that proves the whole chain works; aws configure list just echoes back what we wrote.
aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 \
  || die "profile written but STS rejected it — check the keys and that the user has policies" 4

aws sts get-caller-identity --profile "$PROFILE" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("identity ok:", d["Arn"])'

cat <<EOF

Delete the CSV now. It holds the secret in plaintext:

    rm "$CSV"

Then verify before committing to anything:
    export AWS_PROFILE=$PROFILE
    aws configure list --profile $PROFILE
EOF
