#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -parse-as-library -module-cache-path /private/tmp/muse-tests-module-cache Shared/ReplyAudio.swift Shared/RelayModels.swift Tests/ConnectivityStub.swift MuseWatch/Models.swift MuseWatch/MuseStore.swift Tests/StoreTests.swift -o /private/tmp/muse-store-tests
/private/tmp/muse-store-tests
