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

If the repository remains private, each installation needs a fine-grained GitHub token restricted to this repository with Contents read access. It is optional for public repositories and stays in the local Keychain under a separate service. It is never embedded in a feed, app bundle, source file or URL. Making the repository public requires an explicit visibility decision; the updater does not change repository permissions.
