# Shush

Shush is a small, native Swift 6 macOS menu-bar app that controls the default microphone input with the F5/Dictation key.

It uses only Apple frameworks:

- Core Audio to mute the default input device (with an input-gain fallback for devices that do not expose a mute control)
- Core Graphics and Accessibility to filter the F5/Dictation key system-wide
- SwiftUI `MenuBarExtra` for the menu-bar interface
- AppKit for sounds, app lifecycle actions, and System Settings integration

## Requirements

- macOS 13 or newer
- Xcode 15 or newer

## Build and run

Before the first build, add your Apple Account in **Xcode → Settings → Accounts**, select your team, click **Manage Certificates**, and create an **Apple Development** certificate. A stable signature is required because macOS privacy authorization is tied to the signing identity; ad-hoc signing causes Accessibility permission to break whenever the binary changes.

Then run a complete release build, local install, and restart:

```sh
./build.sh
```

The script builds into `.build` with Xcode-managed Apple Development signing, installs the signed result at `/Applications/Shush.app`, refreshes its Launch Services registration, and launches it. You can override the configured team with `SHUSH_DEVELOPMENT_TEAM`.

Or run from Xcode:

1. Open `Shush.xcodeproj` in Xcode.
2. Select the **Shush** scheme and run it.
3. Grant Shush access in **System Settings → Privacy & Security → Accessibility** so it can filter the key globally and prevent Dictation from opening. Input Monitoring is not required.

On macOS 26, menu-bar apps can also be hidden by the system. If Shush is running but absent from the menu bar, open **System Settings → Menu Bar** and enable Shush.

If the Dictation key is not recognized, enable **Debug Mode**, press it once, and choose **Copy Keyboard Diagnostics**. The copied report includes the raw system-key code seen by the event tap without recording any typed text.

The menu-bar icon shows the current state:

- `mic.fill`: microphone is live
- `mic.slash.fill`: microphone is muted
- `mic.badge.xmark`: the current input device cannot be controlled

The **Dictation Key Mode** section of the menu offers two behaviors:

- **Toggle**: press F5 once to mute or unmute.
- **Push to Talk**: the microphone is muted by default, unmuted while F5 is held, and muted again when the key is released.

The selected mode is remembered between launches. Selecting **Push to Talk** immediately mutes the microphone, including when Shush launches in that mode.

Shush first uses the device's Core Audio mute property. If a device does not expose one, Shush stores its current input gain and temporarily sets the gain to zero. The stored gain is restored when unmuting.

## Development

Build from Terminal:

```sh
xcodebuild -project Shush.xcodeproj -scheme Shush -configuration Debug build
```

Run tests:

```sh
xcodebuild -project Shush.xcodeproj -scheme Shush -configuration Debug test
```
