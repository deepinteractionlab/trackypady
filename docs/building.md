# Building Trackypady locally

Use the official TestFlight app and signed Mac download for normal use. Source builds are for inspection and independent local experimentation; they have their own build numbers and do not use DIL release services.

## Requirements

An Apple silicon Mac, macOS 14 or later, Xcode 26.3 with its iOS platform support, Python 3 and Git. This source is being checked with Swift 6.2.4. Xcode 27.1 compatibility is not established. Building/running on a physical iPhone requires your own Apple development signing configuration; simulator builds do not.

Clone the public repo and select your Xcode for this shell (substitute your installed path):

```sh
git clone https://github.com/deepinteractionlab/trackypady.git
cd trackypady
export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'
xcodebuild -version
swift --version
zsh test.sh
```

Expected: the Swift tests finish successfully; optional live-Codex checks may skip. Tests do not require GitHub authentication or official build-number allocations.

## Mac local app

```sh
python3 scripts/build-local-bridge.py
```

The helper creates `.build/Local/Trackypady Bridge Local.app`, signs it ad hoc for this Mac and does not install or open it. It does not create a DMG, notarize, use DIL certificates or allocate an official number. To run it deliberately:

```sh
open '.build/Local/Trackypady Bridge Local.app'
```

Quit the official bridge before live testing. The local app has a separate bundle identifier and pairing Keychain namespace, but both use the same Bluetooth protocol. Give the local app Bluetooth and Accessibility permission if requested, and pair explicitly. Ad hoc builds can require permissions again after rebuilding. Returning to the official apps means quitting the local bridge and pairing with the official bridge if needed.

## iPhone simulator

```sh
zsh build-phone.sh
open iPhone/Trackypady.xcodeproj
```

In Xcode, choose a simulator and Run. Expected: **Trackypady Local** opens to its pairing screen; use **Try gesture demo**. Simulator operation does not establish physical Bluetooth or haptic behavior.

## Physical iPhone

Open the same project, choose your development team in Signing & Capabilities and replace `org.example.trackypady.local.app` with a unique identifier under your control. Connect/select your device and Run. Local build number defaults to `1`; change `CURRENT_PROJECT_VERSION` in `iPhone/Version.xcconfig` independently as needed. Never upload these local builds as official Trackypady releases.

The source project deliberately has no DIL-associated-domain entitlement or DIL team requirement. Scan QR codes **inside the local app**; the public website and iPhone Camera universal links belong to the official app. The local scheme is `trackypady-local`, so website “Open app” links do not target the local build. Running both variants on one device can affect pairing; select/re-pair deliberately.

## Normal edit loop

Change source → run `zsh test.sh` → compile the relevant app → run the demo or targeted live behavior. For example, after changing gesture recognition in `Sources/TouchCore`, run tests and use the simulator demo; verify touch timing and haptics on actual hardware before relying on those changes. Rebuild the local Mac package after bridge edits. Build output remains under `.build/`; remove only that folder to start a clean compilation.

Local builds do not contain an official build reservation or receipt. Version screens identify them as `local-public-source`; some official provenance fields are unavailable. Release binaries have their own recorded source; see [source snapshot notes](source-snapshot.md). DIL’s official numbering, signing, packaging and release automation are not included.
