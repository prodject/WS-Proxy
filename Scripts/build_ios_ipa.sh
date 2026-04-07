#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="${ROOT_DIR}/WS-Proxy.xcodeproj"
SCHEME="${SCHEME:-WSProxy}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${BUILD_DIR}/WSProxy.xcarchive}"
IPA_NAME="${IPA_NAME:-WSProxy.ipa}"
APP_NAME="${APP_NAME:-WSProxy.app}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required but not installed" >&2
    exit 1
fi

xcodegen generate --spec "${ROOT_DIR}/project.yml"

rm -rf "${BUILD_DIR}" "${ROOT_DIR}/Payload" "${ROOT_DIR}/${IPA_NAME}"
mkdir -p "${BUILD_DIR}"

xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=iOS" \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    clean archive

APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "App bundle not found at ${APP_PATH}" >&2
    exit 1
fi

mkdir -p "${ROOT_DIR}/Payload"
cp -R "${APP_PATH}" "${ROOT_DIR}/Payload/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${ROOT_DIR}/Payload" "${ROOT_DIR}/${IPA_NAME}"
rm -rf "${ROOT_DIR}/Payload"

echo "${ROOT_DIR}/${IPA_NAME}"
