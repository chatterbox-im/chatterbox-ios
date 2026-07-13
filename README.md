# chatterbox-ios

SwiftUI iOS client for [chatterbox](https://github.com/chatterbox-im/chatterbox) — an XMPP chat app with OMEMO end-to-end encryption.

The Rust library (XMPP, OMEMO, SQLite message store) is compiled via UniFFI into a static `Chatterbox.xcframework` and called directly from Swift.

Run `./bootstrap.sh` to build the framework from the Rust repo, then open `ChatterboxiOS/ChatterboxiOS.xcodeproj`.
