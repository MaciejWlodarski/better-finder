#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
PREVIEW_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}better-finder-preview.XXXXXX")"
trap 'rm -rf -- "${PREVIEW_TMP_DIR}"' EXIT
PREVIEW_OUTPUT="${PWD}/.build/previews"
PREVIEW_FLAGS=()
if [[ "${BETTERFINDER_PREVIEW_CI:-0}" == 1 ]]; then
    # Only run through the bounded CI wrapper, which owns these temporary paths.
    : "${BETTERFINDER_PREVIEW_OUTPUT:?}" "${BETTERFINDER_TEST_ROOT:?}" "${CFFIXED_USER_HOME:?}"
    PREVIEW_OUTPUT="${BETTERFINDER_PREVIEW_OUTPUT}"
    PREVIEW_FLAGS=(-D BETTERFINDER_TESTING)
fi
PREVIEW_APP="${PREVIEW_TMP_DIR}/BetterFinderPreview.app"
mkdir -p "${PREVIEW_OUTPUT}" "${PWD}/.build/preview-module-cache" "${PREVIEW_APP}/Contents/MacOS"
# Fixed stage IDs only; the wrapper never publishes arbitrary log content.
preview_stage() { print -r -- "$1" > "${PREVIEW_OUTPUT}/stage.txt"; }
preview_stage prepare-bundle
cp Resources/Info.plist "${PREVIEW_APP}/Contents/Info.plist"
plutil -replace CFBundleExecutable -string NativePreview "${PREVIEW_APP}/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.betterfinder.preview "${PREVIEW_APP}/Contents/Info.plist"
rm -f -- "${PREVIEW_OUTPUT}/verification.txt"
# Keep the real App/Scene and command definitions; the harness supplies main().
sed '/^@main$/d' Sources/BetterFinder/BetterFinderApp.swift > "${PREVIEW_TMP_DIR}/App.swift"
preview_stage compile-harness
xcrun swiftc -parse-as-library "${PREVIEW_FLAGS[@]}" \
    -module-cache-path "${PWD}/.build/preview-module-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/BetterFinder/Models/*.swift Sources/BetterFinder/Engine/*.swift Sources/BetterFinder/Views/*.swift \
    "${PREVIEW_TMP_DIR}/App.swift" scripts/preview_app.swift -o "${PREVIEW_APP}/Contents/MacOS/NativePreview"
preview_stage sign-harness
codesign --force --sign - --timestamp=none "${PREVIEW_APP}"
if [[ "${BETTERFINDER_PREVIEW_CI:-0}" == 1 ]]; then
    # Direct child process: inherits the isolated environment and can be killed
    # by the wrapper's process-group deadline, unlike a LaunchServices child.
    preview_stage launch-native
    "${PREVIEW_APP}/Contents/MacOS/NativePreview"
else
    open -n -W -F --stdout "${PREVIEW_TMP_DIR}/preview.log" --stderr "${PREVIEW_TMP_DIR}/preview.err" \
        --env "BETTERFINDER_PREVIEW_OUTPUT=${PREVIEW_OUTPUT}" "${PREVIEW_APP}"
    cat "${PREVIEW_TMP_DIR}/preview.log" "${PREVIEW_TMP_DIR}/preview.err"
fi
[[ -f "${PREVIEW_OUTPUT}/verification.txt" ]] && [[ "$(<"${PREVIEW_OUTPUT}/verification.txt")" == PASS* ]]
