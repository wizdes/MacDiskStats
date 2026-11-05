#!/bin/bash
# Packs a signed MacDiskStats.app into a DMG. Adapted from
# QuickEdit/scripts/make-dmg.sh.
#   scripts/make-dmg.sh APP OUT.dmg [--no-notarize]
# Steps: notarize and staple the app (through a temporary zip that is then
# removed), copy it with an Applications link into a UDZO DMG, sign the DMG,
# notarize and staple it, mount it read-only to check the app and the link,
# and fail if a zip is left. Any stop while the DMG is mounted detaches it.
# --no-notarize: no notarizing, stapling or DMG signing.
# Environment: MDS_DEVID (signing identity), NOTARY_PROFILE (notarytool profile).
set -Eeuo pipefail

step='input checks'
trap 'result=$?; printf "FAIL: %s (exit %s)\n" "$step" "$result" >&2' ERR
pass() { printf 'PASS: %s\n' "$step"; }
fail() { printf 'FAIL: %s: %s\n' "$step" "$1" >&2; exit 1; }

app="${1:-}"
dmg="${2:-}"
notarize=true
case "${3:-}" in
    "") ;;
    --no-notarize) notarize=false ;;
    *) fail 'usage: scripts/make-dmg.sh APP OUT.dmg [--no-notarize]' ;;
esac
[ "$#" -le 3 ] || fail 'usage: scripts/make-dmg.sh APP OUT.dmg [--no-notarize]'
[[ -n "$app" && -d "$app" && -x "$app/Contents/MacOS/MacDiskStats" ]] || fail "not a MacDiskStats app: ${app:-<none>}"
[[ "$dmg" == *.dmg ]] || fail "the output must end in .dmg: ${dmg:-<none>}"
signing_identity="${MDS_DEVID:-}"
if "$notarize" && [[ -z "$signing_identity" ]]; then fail "MDS_DEVID is required for notarized DMG"; fi
profile="${NOTARY_PROFILE:-fastpad-notary}"
app_name="$(basename "$app")"
out_dir="$(cd "$(dirname "$dmg")" && pwd)"
dmg="$out_dir/$(basename "$dmg")"
# A zip with the same release name must not be left next to the DMG.
same_name_zip="${dmg%.dmg}.zip"
pass

step='tool checks'
for tool in codesign ditto hdiutil xcrun spctl shasum python3 find; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done
pass

step='clean work folder'
work="$out_dir/.make-dmg-work"
[[ "$work" == */.make-dmg-work && "$out_dir" != / ]] || fail "refusing to delete unexpected path: $work"
rm -rf -- "$work"
mkdir -p "$work"
rm -f -- "$dmg"
pass

submit_for_notarization() {
    local artifact="$1" submission submission_id status
    if ! submission="$(xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait --output-format json)"; then
        printf '%s\n' "$submission" >&2
        submission_id="$(printf '%s' "$submission" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
        if [[ -n "$submission_id" ]]; then xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2 || true; fi
        fail 'notarytool submit failed'
    fi
    submission_id="$(printf '%s' "$submission" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"
    status="$(printf '%s' "$submission" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
    if [[ "$status" != Accepted ]]; then
        if [[ -n "$submission_id" ]]; then xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2 || true; fi
        fail "notary status: ${status:-unknown}"
    fi
    printf 'NOTARY: %s Accepted (%s)\n' "$(basename "$artifact")" "$submission_id"
}

if "$notarize"; then
    step='notary profile check'
    xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null \
        || fail "notary profile '$profile' is unavailable"
    pass

    step='create temporary notary zip'
    mkdir -p "$work/notary"
    notary_zip="$work/notary/${app_name%.app}.zip"
    ditto -c -k --keepParent "$app" "$notary_zip"
    [[ -s "$notary_zip" ]] || fail "zip missing: $notary_zip"
    pass

    step='notarize app'
    submit_for_notarization "$notary_zip"
    pass

    step='staple app'
    xcrun stapler staple "$app"
    pass

    step='validate stapled app'
    xcrun stapler validate "$app"
    spctl --assess --type execute -vv "$app"
    pass

    step='remove temporary notary zip'
    rm -- "$notary_zip"
    rmdir -- "$work/notary"
    pass
else
    printf 'PASS: notarize and staple skipped (--no-notarize)\n'
fi

step='create DMG'
staging="$work/staging"
mkdir -p "$staging"
ditto "$app" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "${app_name%.app}" -srcfolder "$staging" -ov -format UDZO "$dmg"
[[ -s "$dmg" ]] || fail "DMG missing: $dmg"
rm -rf -- "$staging"
pass

if "$notarize"; then
    step='sign DMG'
    codesign --force --timestamp --sign "$signing_identity" "$dmg"
    codesign --verify --strict --verbose=2 "$dmg"
    pass

    step='notarize DMG'
    submit_for_notarization "$dmg"
    pass

    step='staple DMG'
    xcrun stapler staple "$dmg"
    pass

    step='validate stapled DMG'
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -vv "$dmg"
    pass
else
    printf 'PASS: DMG signing skipped (--no-notarize)\n'
fi

verify_mounted_app() {
    local mounted_app="$mount_dir/$app_name"
    [[ -d "$mounted_app" ]] || { printf 'Missing app in DMG: %s\n' "$mounted_app" >&2; return 1; }
    [[ -L "$mount_dir/Applications" && "$(readlink "$mount_dir/Applications")" == /Applications ]] || {
        printf 'Missing Applications link in DMG\n' >&2
        return 1
    }
    codesign --verify --deep --strict "$mounted_app" || return 1
    if "$notarize"; then
        xcrun stapler validate "$mounted_app" || return 1
    fi
}

step='verify DMG contents'
mount_dir="$(mktemp -d "$work/dmg-mount.XXXXXX")"
detach_on_exit() { hdiutil detach -force "$mount_dir" >/dev/null 2>&1 || true; }
trap detach_on_exit EXIT
trap 'exit 130' INT TERM
if ! hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount_dir" "$dmg"; then
    fail 'could not attach DMG'
fi
verified=true
if ! verify_mounted_app; then verified=false; fi
if ! hdiutil detach -quiet "$mount_dir"; then fail 'could not detach DMG'; fi
trap - EXIT INT TERM
rmdir -- "$mount_dir"
[[ "$verified" == true ]] || fail 'DMG contents failed verification'
pass

step='zip guard'
[[ -z "$(find "$work" -name '*.zip' -print -quit)" ]] || fail "a zip is left under $work"
[[ ! -e "$same_name_zip" ]] || fail "a zip is left next to the DMG: $same_name_zip"
rm -rf -- "$work"
pass

step='SHA-256'
shasum -a 256 "$dmg"
pass
printf 'dmg: %s (%s bytes)\n' "$dmg" "$(stat -f %z "$dmg")"
