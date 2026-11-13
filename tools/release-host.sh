#!/bin/bash
# Builds, signs, notarizes and staples the Mac host for a GitHub release.
#
#   tools/release-host.sh [version]
#   tools/release-host.sh --identity     (only shows which signing identity would be used, then stops)
#
# version: the marketing version (default: MARKETING_VERSION in project.yml).
# Leaves build/release/Clamshell-Host-<version>.zip and Clamshell-Host-<version>.zip.sha256.
# Refuses to run with uncommitted changes (git status not clean) unless ALLOW_DIRTY=1.
# The build number (CFBundleVersion) is the UTC time, YYYYMMDDHHMM, unless CLAMSHELL_BUILD_NUMBER is set.
#
# Needs: Xcode, xcodegen, exactly one "Developer ID Application" identity for the team in the keychain, and an
# App Store Connect API key for notarization: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH from the
# environment or, for any not set, from ~/.config/clamshell/asc.env (plain NAME=value lines).
# Nothing here uploads anything except the zip sent to Apple's notary service.
set -euo pipefail

# --- Signing: change the team to build your own copy -----------------------------------------
TEAM_ID="${CLAMSHELL_TEAM_ID:-RLC58VS9R6}"
# Optional: the SHA-1 or full name of one identity, when the team has several Developer ID identities.
SIGN_OVERRIDE="${CLAMSHELL_SIGN_IDENTITY:-}"
# ---------------------------------------------------------------------------------------------

SCHEME="ClamshellHost"
APP_NAME="Clamshell Host"
ASC_ENV_FILE="$HOME/.config/clamshell/asc.env"

cd "$(dirname "$0")/.."
ROOT="$PWD"

# The one "Developer ID Application: ... (TEAM_ID)" identity in the keychain, found at run time, so no
# name is written here. Sets SIGN_SHA1 and SIGN_NAME, or stops when there is none or more than one.
resolve_identity() {
  local lines count
  lines="$(security find-identity -v -p codesigning \
           | grep -E '^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]{40}[[:space:]]+"Developer ID Application: .*\('"$TEAM_ID"'\)"$' || true)"
  if [[ -n "$SIGN_OVERRIDE" ]]; then
    lines="$(grep -F -- "$SIGN_OVERRIDE" <<<"$lines" || true)"
  fi
  count="$(grep -c . <<<"$lines" || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "error: no valid \"Developer ID Application\" signing identity for team $TEAM_ID in the keychain" >&2
    exit 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "error: $count \"Developer ID Application\" identities for team $TEAM_ID; set CLAMSHELL_SIGN_IDENTITY to the SHA-1 of the one to use:" >&2
    awk '{print "  " $2}' <<<"$lines" >&2
    exit 1
  fi
  SIGN_SHA1="$(awk '{print $2}' <<<"$lines")"
  SIGN_NAME="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$lines")"
}
resolve_identity

if [[ "${1:-}" == "--identity" ]]; then
  echo "signing identity: SHA-1 ${SIGN_SHA1:0:6}..., team $TEAM_ID"
  exit 0
fi

if [[ -n "$(git status --porcelain)" && "${ALLOW_DIRTY:-}" != "1" ]]; then
  echo "error: the working tree has uncommitted changes; release from a clean commit, or set ALLOW_DIRTY=1" >&2
  git status --short >&2
  exit 1
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' project.yml | head -1)"
fi
[[ -n "$VERSION" ]] || { echo "error: no version given and none found in project.yml" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "error: version '$VERSION' has characters a file name should not" >&2; exit 1; }
# The build number only has to grow from release to release. The UTC time does, even across a fresh history.
BUILD_NUMBER="${CLAMSHELL_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

# Reads NAME from the environment, else from the env file. Never sources the file, never prints the value.
asc_setting() {
  local name="$1" value="${!1:-}"
  if [[ -z "$value" && -f "$ASC_ENV_FILE" ]]; then
    value="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$ASC_ENV_FILE" | tail -1 | cut -d= -f2- \
             | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"(.*)"$/\1/')"
  fi
  if [[ -z "$value" ]]; then
    echo "error: $name is not set. Export it, or add $name=... to $ASC_ENV_FILE" >&2
    exit 1
  fi
  printf '%s' "$value"
}
ASC_KEY_ID="$(asc_setting ASC_KEY_ID)"
ASC_ISSUER_ID="$(asc_setting ASC_ISSUER_ID)"
ASC_KEY_PATH="$(asc_setting ASC_KEY_PATH)"
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
[[ -r "$ASC_KEY_PATH" ]] || { echo "error: ASC_KEY_PATH does not point to a readable .p8 file" >&2; exit 1; }


OUT="$ROOT/build/release"
WORK="$OUT/work-$VERSION"
APP="$WORK/$APP_NAME.app"
ZIP="$OUT/Clamshell-Host-$VERSION.zip"
rm -rf "$WORK" "$ZIP" "$ZIP.sha256"
mkdir -p "$WORK"

step() { printf '\n== %s\n' "$*"; }

step "Version $VERSION ($BUILD_NUMBER), team $TEAM_ID, identity ${SIGN_SHA1:0:6}..."

# The project goes in $WORK, so one in the repo root is left alone. Its INFOPLIST_FILE is relative
# to the repo root, so the build below passes the full path.
step "Generating the Xcode project"
xcodegen generate --spec project.yml --project "$WORK" --quiet

step "Building $SCHEME (Release, Developer ID, hardened runtime)"
LOG="$WORK/xcodebuild.log"
if ! xcodebuild \
    -project "$WORK/Clamshell.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGN_SHA1" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    INFOPLIST_FILE="$ROOT/Host/Info.plist" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    clean build > "$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | head -20 >&2
  echo "error: build failed, full log in $LOG" >&2
  exit 1
fi
ditto "$WORK/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"
echo "built: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

step "Checking the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
grep -qxF "Authority=$SIGN_NAME" <<<"$DETAILS" || { echo "error: not signed by the resolved identity" >&2; exit 1; }
grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$DETAILS" || { echo "error: not signed for team $TEAM_ID" >&2; exit 1; }
# The leaf certificate must be the one resolved above, by its SHA-1.
CERTS="$WORK/certs"; mkdir -p "$CERTS"
(cd "$CERTS" && codesign -d --extract-certificates "$APP" 2>/dev/null)
LEAF_SHA1="$(shasum -a 1 "$CERTS/codesign0" | awk '{print toupper($1)}')"
[[ "$LEAF_SHA1" == "$SIGN_SHA1" ]] || { echo "error: signed with a different certificate than the resolved identity" >&2; exit 1; }
grep -E "flags=.*runtime" <<<"$DETAILS" >/dev/null || { echo "error: hardened runtime is off" >&2; exit 1; }
grep -E "^Timestamp=" <<<"$DETAILS" >/dev/null || { echo "error: no secure timestamp" >&2; exit 1; }
grep -E "^(Identifier|Authority|Timestamp|TeamIdentifier)=|flags=" <<<"$DETAILS"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if grep -q "<key>" <<<"$ENTITLEMENTS"; then
  echo "entitlements:"; plutil -p - <<<"$ENTITLEMENTS" || true
else
  echo "entitlements: none"
fi

step "Sending to Apple's notary service (waits for the result)"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
set +e
xcrun notarytool submit "$WORK/notarize.zip" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait --timeout 1h --output-format json > "$WORK/notary.json" 2> "$WORK/notary.err"
NOTARY_EXIT=$?
set -e
STATUS="$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || echo unknown)"
SUBMISSION="$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || echo unknown)"
echo "submission $SUBMISSION: $STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
  cat "$WORK/notary.err" >&2
  if [[ "$SUBMISSION" != "unknown" ]]; then
    xcrun notarytool log "$SUBMISSION" \
      --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" "$WORK/notary-log.json" >/dev/null 2>&1 \
      && cat "$WORK/notary-log.json" >&2
  fi
  echo "error: notarization did not pass (notarytool exit $NOTARY_EXIT)" >&2
  exit 1
fi

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Gatekeeper"
spctl -a -vv -t exec "$APP"

step "Packing"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"

step "Done"
echo "$ZIP"
echo "$ZIP.sha256"
echo "The stapled app is at $APP (not installed anywhere)."
