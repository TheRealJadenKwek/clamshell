#!/bin/zsh
# Waits for the App Store Connect app record, then uploads build/Clamshell.ipa,
# adds the owner as internal tester and waits for Apple to finish processing.
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
cd "$(dirname "$0")/.."
python3 tools/testflight.py wait "${1:-10}" || exit 1
python3 tools/testflight.py group || echo "group step failed (will retry after upload)"
(cd fastlane && fastlane upload) > build/upload.log 2>&1
echo "fastlane upload exit $? (altool often exits 1 after a good upload; the build check below decides)"
grep -E "UPLOAD SUCCEEDED|Successfully uploaded|ERROR ITMS|error:" build/upload.log | sed -E 's/\x1b\[[0-9;]*m//g' | head -10
python3 tools/testflight.py group
python3 tools/testflight.py waitbuild
echo "waitbuild exit $?"
python3 tools/testflight.py status
