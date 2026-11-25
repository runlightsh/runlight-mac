# Runlight for Mac

Today's numbers for every Runlight site, one click from the menu bar. Spike alerts that name the
source, and goals, short links and site settings without opening the browser.

Connect any Runlight install with its address and a read-only token. No account, no cloud.

## Building

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
scripts/check.sh
```

The app is in `build/Build/Products/Debug/Runlight.app`.
