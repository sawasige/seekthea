#!/bin/sh
set -e

PBXPROJ="${CI_PRIMARY_REPOSITORY_PATH}/Seekthea/Seekthea.xcodeproj/project.pbxproj"
sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/" "$PBXPROJ"
echo "Build: ${CI_BUILD_NUMBER}"
