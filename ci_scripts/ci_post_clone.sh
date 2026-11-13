#!/bin/sh
# Xcode Cloud：克隆完仓库后先用 XcodeGen 生成 Freefall.xcodeproj（工程文件不进仓库，见 .gitignore）。
# 出处：https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
