#!/bin/sh
# Xcode Cloud: the .xcodeproj is generated from project.yml rather than
# committed, so generate it before Xcode Cloud looks for the scheme.
set -eu
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
xcodegen generate
