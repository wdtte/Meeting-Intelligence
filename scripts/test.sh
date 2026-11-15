#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# CLT Swift 6.4 ships TestingMacros but swiftbuild does not discover its nested
# plugin directory. Explicitly load it when present; other toolchains use defaults.
swift_path="$(xcrun --find swift)"
testing_plugin="${swift_path:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=()
if [[ -f "$testing_plugin" ]]; then
  flags=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test --disable-xctest "${flags[@]}" "$@"
