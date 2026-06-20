#!/bin/sh
set -e

INFO_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
SOURCE_INFO_PLIST="${SRCROOT}/${INFOPLIST_FILE}"
STATE_FILE="${SRCROOT}/PCompanion.version"
PROJECT_FILE="${SRCROOT}/notchprompt.xcodeproj/project.pbxproj"

increment_patch_version() {
    awk -v version="$1" '
        BEGIN {
            n = split(version, parts, ".")
            major = (n >= 1 && parts[1] != "") ? parts[1] : 1
            minor = (n >= 2 && parts[2] != "") ? parts[2] : 0
            patch = (n >= 3 && parts[3] != "") ? parts[3] : 10
            printf "%d.%d.%d", major, minor, patch + 1
        }
    '
}

if [ -f "$STATE_FILE" ]; then
    CURRENT_VERSION="$(cat "$STATE_FILE" | tr -d '[:space:]')"
else
    CURRENT_VERSION="${MARKETING_VERSION:-1.1}"
fi

NEXT_VERSION="$(increment_patch_version "$CURRENT_VERSION")"
printf "%s\n" "$NEXT_VERSION" > "$STATE_FILE"

stamp_project_settings() {
    if [ ! -f "$PROJECT_FILE" ]; then
        return
    fi

    /usr/bin/perl -0pi -e "s/(MARKETING_VERSION = )[^;]+(;)/\${1}${NEXT_VERSION}\${2}/g; s/(CURRENT_PROJECT_VERSION = )[^;]+(;)/\${1}${NEXT_VERSION}\${2}/g" "$PROJECT_FILE"
}

stamp_plist() {
    PLIST_PATH="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEXT_VERSION}" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${NEXT_VERSION}" "$PLIST_PATH"

    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_VERSION}" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${NEXT_VERSION}" "$PLIST_PATH"

    ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
    if [ "$ACTUAL_VERSION" != "$NEXT_VERSION" ]; then
        echo "Failed to stamp ${PRODUCT_NAME} version at ${PLIST_PATH}" >&2
        exit 1
    fi
}

stamp_project_settings

if [ "${GENERATE_INFOPLIST_FILE:-NO}" = "NO" ] && [ -n "${INFOPLIST_FILE:-}" ] && [ -f "$SOURCE_INFO_PLIST" ]; then
    stamp_plist "$SOURCE_INFO_PLIST"
fi

if [ -f "$INFO_PLIST" ]; then
    stamp_plist "$INFO_PLIST"
fi

echo "Stamped ${PRODUCT_NAME} version ${NEXT_VERSION}"
