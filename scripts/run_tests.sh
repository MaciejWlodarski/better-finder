#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}better-finder-tests.XXXXXX")"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT
TEST_MODULE_CACHE="${BETTERFINDER_MODULE_CACHE:-${TEST_TMP_DIR}/module-cache}"
mkdir -p "${TEST_MODULE_CACHE}"
xcrun swiftc -parse-as-library \
    -module-cache-path "${TEST_MODULE_CACHE}" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/BetterFinder/Models/*.swift Sources/BetterFinder/Engine/*.swift \
    Sources/BetterFinder/Views/FormatHelpers.swift Sources/BetterFinder/Views/NativeFileDragSource.swift \
    Tests/BetterFinderTests/*.swift \
    -o "${TEST_TMP_DIR}/regression-tests"
"${TEST_TMP_DIR}/regression-tests"

xcrun swift -module-cache-path "${TEST_MODULE_CACHE}" scripts/test_file_operations.swift
