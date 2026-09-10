# Shush

Shush is a small, native macOS menu-bar app that controls the default microphone input with the F5/Dictation key.

It uses only Apple frameworks:

- Core Audio to mute the default input device (with an input-gain fallback for devices that do not expose a mute control)
- Core Graphics and Accessibility to capture the F5/Dictation key system-wide
- AppKit for the menu-bar interface

## Requirements

- macOS 13 or newer
- Xcode 15 or newer

## Build and run

For a complete release build, local install, and restart:

```sh
./build.sh
```

The script builds into `.build`, applies a local ad-hoc signature, installs the result at `/Applications/Shush.app`, refreshes its Launch Services icon registration, and launches it. It does not reset Accessibility permission.

Or run from Xcode:

1. Open `Shush.xcodeproj` in Xcode.
2. Select the **Shush** scheme and run it.
3. Grant Shush access in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring** when prompted. These permissions let Shush intercept the key globally and prevent Dictation from opening.

On macOS 26, menu-bar apps can also be hidden by the system. If Shush is running but absent from the menu bar, open **System Settings → Menu Bar** and enable Shush.

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
