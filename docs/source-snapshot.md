# Source snapshot

This candidate comes from accepted development source reviewed on November 23, 2026. It includes the same bridge runtime source as Bridge 0.1.0 (52) and the same iPhone/shared runtime source as iPhone 0.1.0 (37), plus the subsequent Apple encryption declaration. Public build adaptations are listed below; this is not a byte-for-byte reproduction of either signed binary.

- Remove private build-allocation/verification hooks and DIL signing/team configuration.
- Use local build number `1`, local app identities and a `local-public-source` diagnostic channel.
- Use a separate local Keychain pairing namespace and iPhone URL scheme; omit the official associated-domains entitlement.
- Provide local build/test helpers; do not include official packaging, installation or publishing automation.
- Place Mac bundle templates/icon under `MacSupport/` to avoid the existing website `support/` path on case-insensitive disks.
- Relocate original haptic test fixtures to `Tests/Fixtures/Haptics`.
- Add public documentation and licensing material after review.

The published Bridge52 tag predates this source snapshot and remains unchanged. Its GitHub-generated source archive represents the earlier website tree, not this application's source. A reviewed public source commit will be identified when this candidate is published.
