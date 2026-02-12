# Pingtunnel Client

A simple, cross-platform client for the pingtunnel proxy/VPN.

It lets you:
- Manage multiple connections from one place.
- Connect in Proxy or VPN mode.
- Use optional encryption for the tunnel.

## Install

### Android (APK)
1. Download the universal APK.
2. Install it on your device.

### Debian/Ubuntu (.deb)
```bash
sudo apt install ./pingtunnel-client_*.deb
```

If you used `dpkg -i`, fix dependencies with:
```bash
sudo apt -f install
```

### RPM-based distros (.rpm)
```bash
sudo rpm -i pingtunnel-client-*.rpm
```

## Versioning

- Keep `app/pubspec.yaml` `version:` as the human release version and bump it manually (for example `0.6.0+1`) in a release commit.
- CI sets `--build-number` from `GITHUB_RUN_NUMBER` for monotonic Android `versionCode`.
- On tag builds, CI sets `--build-name` from the tag (`vX.Y.Z` or `X.Y.Z`).
- Release tags should follow semantic versioning so app version metadata stays predictable.

## Requirements (Linux)

- `policykit-1` is required for VPN mode (route/TUN changes).
- For top-bar tray controls, install `libayatana-appindicator3-1` (or `libappindicator3-1`).
- Your system may show an authorization prompt when enabling VPN mode.

## Usage

1. Open the app.
2. Paste a connection URI to add it to the list.
3. Select a connection.
4. Tap **Connect** to start.
5. Tap **Test Tunnel** to verify.
6. On Linux, closing the window keeps the app running in the top bar menu.

Sample URI:
```
pingtunnel://example.com?key=123456&mode=proxy&lport=1080
```

Encrypted sample URI:
```
pingtunnel://example.com?encrypt=aes256&encrypt_key=encryption-key-here&mode=proxy&lport=1080
```

### Proxy vs VPN
- **Proxy**: only apps using the local SOCKS proxy are tunneled.
- **VPN**: routes system traffic through the tunnel.

### Encryption
- If **Encryption** is **Off**: provide the **Key**.
- If **Encryption** is **On**: provide the **Encrypt Key**.

## Troubleshooting

- **VPN mode fails on Linux**: ensure `policykit-1` is installed, and allow the authorization prompt.
- **No traffic in VPN mode**: confirm the connection is selected and the tunnel is connected before testing.
