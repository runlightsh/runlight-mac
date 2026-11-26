# Runlight for Mac

Your Runlight sites, one click from the menu bar. See today's visitors for every site at a glance, open
any of them for the detail, and get a notification when one of them suddenly gets busy, with the source
that sent the traffic.

Runlight for Mac talks only to your own Runlight. No account, no cloud, and nothing about you or your
visitors leaves your Mac.

## What it does

- **Every site at a glance.** Visitors today for each site, the change against the same time yesterday,
  and a small chart of the day so far. Switch to the last 7 or 30 days.
- **The total in your menu bar,** beside the Runlight icon. Turn it off if you'd rather see just the icon.
- **Details for any site.** Click a site for a larger chart, visitors, visits, pageviews, bounce rate,
  and the average visit, who's on the site right now, and its top pages, sources, and goals.
- **Spike alerts.** A notification when a site gets far more visitors than usual for the time of day,
  naming the source, like "DailyPhotoTips is spiking: 420 visitors in the last hour, 6× usual. Top
  source: photzy.com." Alerts for jumps in goal conversions too. Choose how big a jump counts, set quiet
  hours, and pick which sites alert.
- **Your dashboard in its own window.** Open the full Runlight dashboard for any site without a browser
  tab.
- **Light and dark,** following your Mac or set your own.
- **Easy on your Mac.** It pauses while your Mac sleeps or is offline, and checks less often in Low Power
  Mode.

## Install

1. Download `Runlight.dmg` from the [latest release](https://github.com/runlightsh/runlight-mac/releases/latest).
2. Open it and drag Runlight to your Applications folder.
3. Open Runlight. Its icon appears in the menu bar at the top of your screen.

Runlight for Mac needs macOS 14 Sonoma or later.

## Connect your Runlight

You need two things: the address of your Runlight and a read-only token.

1. **Make a token.** In your Runlight dashboard, open Settings, then MCP & API, and create a read-only
   token. Copy it; it's shown only once.
2. **Add the connection.** Click the Runlight icon in the menu bar, then Add Runlight Connection. Enter
   the address and paste the token.

The address is wherever your Runlight answers:

| Your Runlight | Address to enter |
|---|---|
| The standalone server | Its address, like `https://stats.example.com` |
| Inside your app, mounted at `/runlight` | Your site, like `https://example.com` |
| The WordPress plugin, the Craft plugin, or the Drupal module | Your site, like `https://example.com` |

You can connect more than one Runlight. The token is kept in your Mac's Keychain, and a read-only token
can only read your numbers, never change anything.

## Settings

- **Sites:** switch sites on or off, and drag them into the order you want.
- **Alerts:** turn spike alerts on, choose how big a jump counts, set quiet hours, and choose which
  sites alert.
- **General:** appearance, the number in the menu bar, where sites open, and opening Runlight when you
  log in.

## Privacy

Runlight for Mac has no account, no analytics of its own, and no server. It sends requests only to the
Runlight installs you connect, and keeps your tokens in the Keychain.

## Building from source

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
scripts/check.sh
```

The app is built to `build/Build/Products/Debug/Runlight.app`.

## License

MIT. See [LICENSE](LICENSE).
