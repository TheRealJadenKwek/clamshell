# Privacy Policy

Effective November 12, 2026.

This policy covers Clamshell (the iPhone app, listed on the App Store as Clamshell Remote) and Clamshell Host (the Mac app). Both are open source; the code in this repository is what they do.

## Summary

Clamshell collects nothing. There are no accounts, no analytics, no advertising, no tracking and no servers. Your Mac's screen, its sound and your input travel only between your own iPhone and your own Mac, directly and encrypted.

## What the iPhone app uses

- **Local network:** to find and connect to your Mac, on your Wi-Fi or over a VPN you run (for example Tailscale).
- **Camera:** only to scan the pairing code shown on your Mac. Scanning happens on the iPhone; no picture is saved or sent anywhere.
- **Keyboard:** when you type with the iPhone's own keyboard, iOS keyboard features (autocorrect learning, dictation, and any third-party keyboard you installed) process what you type, as they do in any app. The Mac keyboard style draws its own keys and avoids that.

## What the Mac app uses

- **Screen Recording:** to show the Mac's screen, and its sound when you turn on Mac sound, on your iPhone.
- **Accessibility:** to play your iPhone's keyboard and trackpad input on the Mac.
- **Local network:** to accept the connection from your iPhone.

## What is stored, and where

- **Pairing key:** a random key made by Clamshell Host. On the Mac it is in your login Keychain. On the iPhone it is in the Keychain, on that device only. It is never sent to us or anyone else.
- **Settings:** your choices (keyboard, trackpad, display size and so on) stay on the iPhone.
- **Mac log:** Clamshell Host keeps a log on the Mac (`~/Library/Logs/Clamshell/host.log`) to help fix problems. It records connections, the iPhone's name, the iPhone's layout and touch measurements, and display changes. It never records the pairing key or what you type. It stays on your Mac.

## What is sent, and to whom

- Between your iPhone and your Mac: the Mac's screen as video, the Mac's sound if you turn it on, the pointer position, your keyboard and trackpad input, the iPhone's name and layout, and the iPhone's clipboard text only when you choose **Type iPhone clipboard on the Mac**. This traffic goes directly between your two devices and is encrypted with your pairing key.
- To the developer or any third party: nothing. Neither app contains analytics, crash reporting, advertising or third-party code that sends data.

If you use a VPN such as Tailscale to connect from elsewhere, that service carries the encrypted traffic under its own policy; it cannot read it.

## Children

Clamshell does not collect personal information from anyone, including children.

## Changes

If this policy changes, the new version will be published in this repository with a new date.

## Contact

Open an issue at https://github.com/TheRealJadenKwek/clamshell/issues.
