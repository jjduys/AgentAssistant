#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  Sources/PowerService.swift Sources/SleepController.swift Tests/PowerTests.swift \
  -o build/AgentAssistantPowerTests
build/AgentAssistantPowerTests
