# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability** (https://github.com/TheRealJadenKwek/clamshell/security/advisories/new).

Include what an attacker can do, the steps to reproduce it, and the app versions (iPhone build and Mac host version). You will get a reply on the advisory.

## Threat model

Whoever holds the pairing key has full control of the Mac (screen, keyboard and pointer), exactly as with a keyboard and trackpad plugged into it, including typing at the lock screen while Clamshell Host is running. The key is the only credential, so keep the QR code and pairing link private. **New key** in the Mac panel makes a new key and revokes every paired iPhone at once; use it if the code or link may have leaked.

The key is kept in the Mac's login Keychain and in the iPhone's Keychain. If the Mac's Keychain cannot be read, the host does not listen until it can, or until **New key** is clicked. The Mac panel shows the code only after a click on **Show pairing code** and hides it again after a minute or when the panel closes.

Anyone without the key, on the same network or on the path, cannot connect to the host or read or change the traffic, which is TLS 1.2 with the key as a pre-shared key; they can only see that a host is listening on port 47800 and its Bonjour name. They can open connections that never finish the handshake: the host keeps at most 8 of those at a time, for at most 5 seconds each, and drops the oldest when another arrives. A flood of them on the local network can delay or block a phone from connecting while it lasts; it cannot affect a phone that is already connected, and it gains nothing without the key.

Forward secrecy: current builds negotiate `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, so recorded traffic cannot be decrypted later even by someone who obtains the key. When either side is an older build that offers only `TLS_PSK_WITH_AES_128_GCM_SHA256`, the pair falls back to that suite, which has no forward secrecy: someone who recorded such a session and later obtains the key could decrypt it. Updating both apps ends the fallback, and making a new key ends that exposure for future sessions.

A paired phone is trusted with the keyboard and pointer, not with the host itself. The host accepts at most 64 KB per message from a phone (a larger one ends the session) and about a megabyte of text waiting to be typed (a longer paste is typed up to there and stopped), drops pointer and scroll values that are not finite and clamps the rest, and types long text in short steps, so **Disconnect**, **New key** and **Quit** take effect at once. After **Disconnect** the host refuses every phone until **Resume**, or until it is quit and opened again.

Software already running as your user on the Mac is outside the threat model: it can already do what you can do.
