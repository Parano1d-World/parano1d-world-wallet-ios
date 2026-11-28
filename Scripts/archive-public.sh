#!/bin/bash
# Creates a signed App Store archive of the public edition (iPhone, iPad, Apple
# Watch; Mac via "Designed for iPad"). No upload is performed.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Xcode on a Mac is required.' >&2; exit 1; }
: "${KOAJENT_TEAM_ID:?Set KOAJENT_TEAM_ID to the KoAjent organization Team ID.}"
[[ "${PARANO1D_DEVICE_ACCEPTED:-}" == 1 ]] || { echo 'Complete the device checklist in PUBLIC-EDITION.md, then set PARANO1D_DEVICE_ACCEPTED=1.' >&2; exit 1; }
: "${PARANO1D_PRIVACY_POLICY_URL:?Set PARANO1D_PRIVACY_POLICY_URL to the published https privacy policy.}"
: "${PARANO1D_EXPORT_RESULT:?Set PARANO1D_EXPORT_RESULT to exempt or approved, matching App Store Connect.}"
case "$PARANO1D_EXPORT_RESULT" in
  exempt) compliance=(INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO) ;;
  approved) : "${PARANO1D_EXPORT_COMPLIANCE_CODE:?Enter the approved compliance code.}"
            compliance=(INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=YES "INFOPLIST_KEY_ITSEncryptionExportComplianceCode=$PARANO1D_EXPORT_COMPLIANCE_CODE") ;;
  *) echo 'Use exempt or approved.' >&2; exit 1 ;;
esac
python3 Scripts/check-public-edition.py
[[ -d Native/ParanoidCore.xcframework && -d Node/ParanoidNode.xcframework && -d Node/NodeParameters ]] || { echo 'Run bash Scripts/build-public.sh first.' >&2; exit 1; }
xcodegen generate --spec project-public.yml
mkdir -p TestResults
archive="$PWD/TestResults/Parano1dPublic.xcarchive"
xcodebuild -project Parano1dPublic.xcodeproj -scheme Parano1dPublic -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$KOAJENT_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  PARANO1D_PRIVACY_POLICY_URL="$PARANO1D_PRIVACY_POLICY_URL" PARANO1D_TERMS_URL="${PARANO1D_TERMS_URL:-}" PARANO1D_SUPPORT_URL="${PARANO1D_SUPPORT_URL:-}" \
  "${compliance[@]}" -archivePath "$archive" archive
[[ -d "$archive/Products/Applications/Parano1dWallet.app/Watch/Parano1dWatch.app" ]] || { echo 'Archive is missing the Apple Watch app.' >&2; exit 1; }
bash Scripts/check-release-bundle.sh "$archive" || { echo "Archive failed the release check; do not upload it." >&2; exit 1; }
printf '%s\n' "Archive created: $archive" 'Upload it from Xcode Organizer or with xcodebuild -exportArchive using method app-store-connect. No upload was performed.'
