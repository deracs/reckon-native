# Publication audit — 20 October 2026

Scope: this new native-app repository and its packaged app. The original Reckon monorepo and its existing Git history are not included or declared safe for publication.

The native repository has fresh Git history. The backend snapshot copies only source files used by the native bundle, with file hashes for provenance. It excludes the original repository’s environment files, data files, test recordings, caches, Git history, and unrelated applications. The native tests and sample dashboard use synthetic accounts, amounts, transaction descriptions, and credentials. Real bank screenshots are not part of the repository.

Saved Akahu tokens stay in macOS Keychain. The installer, build scripts, and release workflow do not read or embed them. The optional local credential importer reads an external environment file and passes the two tokens to Keychain over stdin. It does not write them into the app or repository. The workflow uses synthetic credentials only.

Balance observations, account IDs and names, visit comparisons, alert limits, and alert state stay in the encrypted `~/Library/Application Support/nz.reckon.native/balance-history.enc` file. Its encryption key stays in Keychain. Neither is included in source or the release bundle. This audit does not decrypt or export that history.

Compiler caches and local build products can contain developer paths. They are excluded from Git. The initial app binary contained compiler object paths under the developer’s home folder. Release packaging now strips that debug metadata and maps source paths to a generic build path, and the packaged app is checked for the current builder’s personal home path. Dependencies, caches, local app bundles, logs, signing keys, archives, and environment files are ignored. Only newly generated, checked app ZIPs and checksums are release assets.

The privacy checker examines the Git file list, source contents and (when requested) every file in the app bundle. It flags credential patterns, live Akahu account and transaction ID shapes, private file types, and the builder’s personal home path. A local audit additionally compares the source and app against secret values from the existing Reckon environment file without printing those values. Git commits use the author’s GitHub username and noreply email. The repository URL and source provenance identify that public GitHub account; those identifiers are intentional.

This is a targeted source and artifact audit, not a guarantee that any future file is safe. Automated patterns cannot identify every name, amount, free-text note, or secret format. Review any new fixtures, screenshots, crash logs, release attachments and Git history before changing visibility. If a secret is ever committed or uploaded, deleting it in a later commit is insufficient: revoke it and remove it from history and attachments.

The source snapshot contains the author’s Reckon implementation and third-party dependencies. The build includes third-party license notices. Decide on a source-code license before offering this repository as an open-source project. The current personal app is ad-hoc signed; public distribution should also add Developer ID signing and notarization.

## Software updates — 20 October 2026

Sparkle checks only architecture-specific signed feeds in this repository. Update requests contain the app version and normal network metadata, not bank data or a system profile. The app validates Ed25519 archive signatures before extraction and restricts archive URLs to this repository's GitHub release-asset API.

A dedicated update-signing private key is stored in the maintainer's Keychain and in the repository's GitHub Actions signing secret. It is a software-release credential, separate from the user's Akahu credentials. Only the public verification key and signatures enter source, feeds and app bundles. CI compares the secret against the bundle public key and scans the package for accidental secret inclusion. Third-party Sparkle framework links are permitted only when they resolve within the bundle; the privacy check still rejects escaping links.

The owner authorised making this native repository public after the source and releases were checked. A final audit examined all reachable Git history, all branches and tags, against saved bank secrets and the signing key. Commit author emails use GitHub noreply. GitHub account ownership, source provenance, and public open-source dependency credits are intentionally visible. Bank screenshots, raw records, local encrypted history and bank credentials remain excluded. The original Reckon monorepo was not published.

Public updates require no GitHub token. The updater therefore has no private-repository credential or Keychain read. Tests use demo mode or synthetic fixtures; these do not touch the user's Keychain. Current ad-hoc app signatures change per binary, so macOS may request bank Keychain access after an actual app replacement. Avoiding that across updates requires a stable code-signing identity, normally Developer ID; it is not appropriate to weaken the Keychain access policy.

## Demo screenshots and repeat audit — 21 October 2026

The README screenshots show Reckon 0.7.4 with `--demo`. Each screenshot retains the **SAMPLE DATA** label. Account names and amounts come from `Sources/ReckonCore/SampleDashboard.swift`. The demo balance history uses synthetic observations from `BankDashboardStore`.

Demo mode returns before the app reads Keychain, loads local history, or starts its backend. The capture used a separate demo app copy. The screenshots contain only the demo dropdown. The dropdown captures exclude the preview title bar and its screen-share indicator. They exclude EXIF, Photoshop, and display-profile metadata.

The repeat audit used a fresh mirror of the public repository at commit `67ddd459dbcfaa28a5bf3fd856c0f8669cafeed2`. It covered:

- The public branch and all eight public tags: 12 reachable commits and 138 file blobs.
- All four published releases: 0.6.2, 0.7.1, 0.7.2, and 0.7.4.
- All eight release apps for Apple silicon and Intel, with 580 bundle files in total, plus eight checksum attachments.
- Release descriptions and attachments. The repository had no issues or pull requests at the time of the audit.
- The three new screenshots, including visual review, source fixtures, and image metadata.

Each release archive and checksum attachment matched GitHub's published SHA-256 digest. The archive checks found no extra files outside the app and macOS archive metadata. The bundle signatures verified. Source history and release files passed checks for saved secret values from the local environment file. Checks also covered credential patterns, bank account numbers, live Akahu account and transaction IDs, personal home paths, and private data files.

The staged documentation and screenshots also passed the repository privacy check. The audit found no personal bank records or Akahu credentials in the checked public material. The original Reckon monorepo remains private. The scope and limits above still apply to future changes and uploads.
