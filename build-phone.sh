#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
xcodebuild -project iPhone/Trackypady.xcodeproj -scheme Trackypady -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iOS-Simulator CODE_SIGNING_ALLOWED=NO build
