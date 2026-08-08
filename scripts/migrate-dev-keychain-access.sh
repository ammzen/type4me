#!/bin/bash
set -euo pipefail

APP_PATH="${1:-/Applications/Type4Me Dev.app}"
LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")
TEAM_ID=$(codesign -dvvv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')

if [ "$BUNDLE_ID" != "com.type4me.dev" ]; then
    exit 0
fi
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "not set" ]; then
    echo "WARNING: Dev signer has no Apple Team ID; Keychain access cannot persist securely across binary changes." >&2
    exit 0
fi

MARKER_DIR="$HOME/Library/Application Support/Type4Me Dev"
MARKER_PATH="$MARKER_DIR/keychain-team-$TEAM_ID.migrated"
if [ -f "$MARKER_PATH" ] && [ "${FORCE_KEYCHAIN_ACL_MIGRATION:-0}" != "1" ]; then
    echo "Keychain access already migrated for team $TEAM_ID."
    exit 0
fi

ITEMS=()
while IFS= read -r item; do
    ITEMS+=("$item")
done < <(security dump-keychain -a 2>/dev/null | awk '
    /"acct"/ { gsub(/.*="/, ""); gsub(/"$/, ""); acct=$0 }
    /"svce".*"com\.type4me\.(grouped|scalar)"/ {
        gsub(/.*="/, ""); gsub(/"$/, "");
        if (acct) print $0 "|" acct;
        acct=""
    }
')

if [ ${#ITEMS[@]} -eq 0 ]; then
    echo "No existing Type4Me Keychain items need migration."
    exit 0
fi

request_keychain_password() {
    if [ -n "${KC_PASS:-}" ]; then
        printf '%s' "$KC_PASS"
        return
    fi
    if [ -t 0 ]; then
        local value
        read -r -s -p "Login Keychain password for one-time Type4Me ACL migration: " value
        echo >&2
        printf '%s' "$value"
        return
    fi
    osascript <<'APPLESCRIPT'
tell application "System Events"
    activate
    set response to display dialog "Type4Me 需要登录钥匙串密码，将现有 API 凭据授权给稳定的 Apple Development Team。此操作只执行一次，密码不会保存。" default answer "" with hidden answer buttons {"取消", "迁移"} default button "迁移" cancel button "取消" with title "迁移 Type4Me Dev 钥匙串权限"
    return text returned of response
end tell
APPLESCRIPT
}

KEYCHAIN_PASSWORD="$(request_keychain_password)"
cleanup() {
    unset KEYCHAIN_PASSWORD
}
trap cleanup EXIT
if [ -z "$KEYCHAIN_PASSWORD" ] \
    || ! security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN"; then
    echo "ERROR: Could not unlock the Login Keychain; ACL migration was not completed." >&2
    exit 1
fi

PARTITIONS=("apple-tool:" "apple:" "teamid:$TEAM_ID")
PRODUCTION_TEAM_ID=""
if [ -d "/Applications/Type4Me.app" ]; then
    PRODUCTION_TEAM_ID=$(codesign -dvvv "/Applications/Type4Me.app" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' || true)
fi
if [ -n "$PRODUCTION_TEAM_ID" ] && [ "$PRODUCTION_TEAM_ID" != "not set" ] \
    && [ "$PRODUCTION_TEAM_ID" != "$TEAM_ID" ]; then
    PARTITIONS+=("teamid:$PRODUCTION_TEAM_ID")
fi
PARTITION_LIST=$(IFS=,; printf '%s' "${PARTITIONS[*]}")

UPDATED=0
for item in "${ITEMS[@]}"; do
    service="${item%%|*}"
    account="${item#*|}"
    if security set-generic-password-partition-list \
        -s "$service" -a "$account" \
        -S "$PARTITION_LIST" \
        -k "$KEYCHAIN_PASSWORD" \
        "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
        UPDATED=$((UPDATED + 1))
    fi
done
if [ "$UPDATED" -ne "${#ITEMS[@]}" ]; then
    echo "ERROR: Keychain ACL migration updated $UPDATED/${#ITEMS[@]} items." >&2
    exit 1
fi

mkdir -p "$MARKER_DIR"
touch "$MARKER_PATH"
echo "Keychain ACL migration complete: $UPDATED items now trust team $TEAM_ID."
