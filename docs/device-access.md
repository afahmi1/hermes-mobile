# Device access

Each Hermes Mobile sign-in receives a revocable 180-day device grant. The bridge shares its configured bots, conversations, tools and approval prompts with every paired phone. Only pair a phone you trust with that access. Pairing requires the bridge’s tailnet HTTPS address and a single-use code that expires in five minutes. Google OAuth authenticates the Tailscale connection.

## Pair a phone

On the bridge host, using the same Hermes home and Python as the service, run the following command. Copy the displayed code into **Pairing code** on the phone. An owner-signed-in phone can also create a code under **Settings → Device access**. The bridge stores a digest of each code.

```sh
python3 Bridge/hermes_mobile_bridge.py --pair-code
```

A paired phone can chat, queue work and approve tools. Changing project instructions, files and assignments requires an authorized operator or owner grant. Managing devices from the app requires the existing verified owner sign-in. The local host commands work in either workspace mode.

## Revoke a device

```sh
python3 Bridge/hermes_mobile_bridge.py --list-devices
python3 Bridge/hermes_mobile_bridge.py --revoke-device DEVICE_ID
```

Owner sign-ins can also revoke another phone in **Settings → Device access**. Revocation closes that device’s active event streams. Out-of-process revocations and expiry are checked every second while streams are open. A turn already admitted on Hermes continues to run. Older signed tokens become individually revocable when they next contact the upgraded bridge. Newly issued grants use a versioned signature that also prevents older bridges from accepting them after a downgrade.

## Switch gateways

Use **Settings → Add Gateway** and sign in to the other bridge. Choose a saved address to switch. Each scheme, host and port has its own device-only Keychain entry. Switching detaches the old client and keeps its local protected history for the next visit. Signing out revokes the active device grant and clears that login’s caches and settings. If the server is unreachable, the app can clear this phone’s sign-in locally and the owner can revoke it on the host. Other saved gateways are available from the sign-in screen.

The bridge returns the active device ID and supported features at authenticated `GET /m/capabilities`. Existing clients can continue using password login. Deploy the entire `Bridge/` and `Status/` directories in the same checkout to keep the service modules together. The registry is `$HERMES_HOME/mobile/devices/devices.sqlite3`.
