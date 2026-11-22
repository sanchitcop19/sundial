#!/bin/sh
# Every TestFlight upload needs a build number higher than the last one.
# Xcode Cloud's own run counter only ever goes up, so use it.
set -eu
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/" \
    SundialMobile.xcodeproj/project.pbxproj
fi
