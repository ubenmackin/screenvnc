# Privacy Policy

*Last updated: Nov 2026*

## Our Commitment

We don't track you, and no ScreenVNC server ever receives your data. Ever.

## Summary

- **No personal data collection** - We don't collect names, emails, or phone numbers
- **No servers** - We operate no servers; the only data that leaves your device is connection profile metadata backed up through your own Apple iCloud account, and only when iCloud is enabled
- **Passwords never leave your device** - Connection passwords stay in this device's Keychain and never sync anywhere
- **No tracking** - We have no analytics, telemetry, or user tracking

## What Information ScreenVNC Stores

### On Your Device

Your connection profiles stay on your device with zero tracking.

1. **Connection profiles**
   - Host, port, username, and display/connection settings for your saved hosts
   - Stored as a JSON file in the app's Application Support folder (ScreenVNC does not use SwiftData); per-host display preferences stored in UserDefaults
   - No web history is collected and no websites visited are recorded
   - You can add or delete saved profiles in-app

2. **Passwords**
   - Connection passwords are stored only in the iOS Keychain, marked device-only so they never sync to iCloud or any other device
   - Passwords are excluded from profile backups entirely, which is why restored hosts always ask for credentials again on first connect

### Off Your Device

**iCloud profile backup (only when iCloud is enabled)** - Your connection profile metadata (host, port, username, and connection settings) replicates through Apple's iCloud Key-Value Store so it can be restored after a reinstall or when moving to a new device. This traffic flows only between your devices and Apple's iCloud infrastructure; ScreenVNC runs no servers and never transmits anything itself, and passwords are never part of this backup.

## What Information is Shared

- **With Apple (only when iCloud is enabled):** connection profile metadata, via Apple's iCloud Key-Value Store and governed by your Apple iCloud terms
- **With anyone else, including us:** Never. Passwords stay exclusively in your device Keychain and are never shared with Apple or any third party.

## What We DON'T Do

ScreenVNC **never**:
- Collects personal information
- Tracks your location
- Stores data on ScreenVNC servers
- Shares data with third parties
- Uses analytics or telemetry
- Requires registration

## Children's Privacy

ScreenVNC is meant for users 17+, and does not knowingly collect information from children.
The app has no age verification because it collects no personal information from anyone.

## Changes to This Policy

If we update this policy:
- The "Last updated" date will change
- No retroactive changes can affect data (since we don't collect any)

## Contact

ScreenVNC is available for free. For privacy questions, please ask via [GitHub issues](https://github.com/ubenmackin/screenvnc/issues).
