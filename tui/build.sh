cd /Users/ikun_cxkpro/Projects/WearableInstall/tui
dart pub get
cd macos_bridge
./scripts/package_bundle.sh --ad-hoc
cd ..
dart compile exe bin/wristload_tui.dart -o build/wristload_tui
./build/wristload_tui