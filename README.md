# AeroSpace Beta [![Build](https://github.com/nikitabobko/AeroSpace/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/nikitabobko/AeroSpace/actions/workflows/build.yml)

<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="40%" align="right">

AeroSpace is an i3-like tiling window manager for macOS

Videos:
- [YouTube 91 sec Demo](https://www.youtube.com/watch?v=UOl7ErqWbrk)
- [YouTube Guide by Josean Martinez](https://www.youtube.com/watch?v=-FoWClVHG5g)

Docs:
- [AeroSpace Guide](https://nikitabobko.github.io/AeroSpace/guide)
- [AeroSpace Commands](https://nikitabobko.github.io/AeroSpace/commands)
- [AeroSpace Goodies](https://nikitabobko.github.io/AeroSpace/goodies)

## About this fork

This is a personal fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace) with a few Hyprland-like additions.
It is **not affiliated with upstream**, it is **experimental**, and it has only been built and tested on **macOS 26.6 (arm64)**.
Use upstream if you want a supported release.

Layout of the repository: `main` (this branch) integrates all features of the fork, every feature also lives on its own `feat/*` branch based on upstream (to keep rebasing onto upstream cheap), and upstream itself is tracked as a remote (`git remote add upstream https://github.com/nikitabobko/AeroSpace`), not as a branch here.
The upstream README follows below, unchanged.

Everything below is off by default; with the default config the behaviour is upstream's.
All keys are documented in the [guide](./docs/guide.adoc) and in [default-config.toml](./docs/config-examples/default-config.toml).

### Features

**Dwindle tiling.** A new tiling window splits the focused window along its longer side (a binary tree, like Hyprland's dwindle layout). While enabled, the opposite-orientation normalization is not applied. `layout horizontal vertical` flips the orientation of a split (Hyprland's togglesplit).

```toml
dwindle = true

[mode.main.binding]
alt-slash = 'layout horizontal vertical'
```

**Left/right modifier bindings.** `lcmd`, `rcmd`, `lalt`, `ralt`, `lctrl`, `rctrl`, `lshift`, `rshift` in bindings, e.g. to keep the right Option key free for typing special characters. Based on the commit series by [N1ark](https://github.com/N1ark) (upstream PR [#1714](https://github.com/nikitabobko/AeroSpace/pull/1714) is a related, more invasive approach; this fork takes the smaller series). Side-specific bindings use a `CGEvent` tap instead of Carbon hotkeys, so they do not work while macOS Secure Input is active (for example in a password field).

```toml
[mode.main.binding]
lalt-h = 'focus left'    # ralt-h is left alone
```

**Modifier + drag to move and resize.** Hold the modifier and left-drag anywhere on a window to move it, right-drag to resize it. Tiled windows get drop zones: dropping on a tile's edge splits that tile on that side, dropping on its centre swaps the two windows. While moving, the tiles stay where they are and the change is applied once on release (a preview shows the target); resizing is live. Floating windows just move or resize. Only the exact modifier set triggers.

```toml
mouse-modifier = 'alt'    # 'alt' | 'cmd' | 'ctrl' | 'ctrl-alt' | ''  (off)
```

**Trackpad workspace swipe.** A multi-finger horizontal swipe switches the workspace of the monitor under the cursor. macOS sends empty gesture events in the middle of a swipe, so the swipe is tracked from the touch data instead (the approach of [SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace), MIT). Turn off the macOS gesture with the same finger count in System Settings > Trackpad > More Gestures.

```toml
[gestures]
workspace-swipe = true
workspace-swipe-fingers = 3        # 3 | 4
workspace-swipe-threshold = 15     # percent of the trackpad width
workspace-swipe-natural = true     # fingers right = previous workspace
workspace-swipe-skip-empty = true
workspace-swipe-wrap = false
```

**Focus follows mouse without raising.** `'no-raise'` focuses the window under the cursor without bringing it to the front (floating windows are not raised either). It uses private SkyLight calls, the technique known from [yabai](https://github.com/koekeishiya/yabai) (MIT); it works with SIP enabled. Focus is deliberately not moved when it would be stolen from something AeroSpace does not manage: an unmanaged window has focus (launcher or dialog panels), or another window covers the cursor (overlays, Mission Control, hosted content). `mode = 'raise'` is the classic raising behaviour, and apps that ignore no-raise focus can be listed in `raise-apps`.

```toml
focus-follows-mouse.mode = 'no-raise'   # 'off' | 'no-raise' | 'raise'
focus-follows-mouse.delay-ms = 0
focus-follows-mouse.raise-apps = []     # bundle ids that always raise
focus-follows-mouse.debug-log = false   # decisions -> ~/Library/Logs/AeroSpace/ffm.log
# shorthand: focus-follows-mouse = 'no-raise'
```

**Clickable menu bar workspaces.** A second menu bar item shows the occupied, visible and focused workspaces as pills; click focuses a workspace, right click or Option-click opens a menu.

```toml
menu-bar-clickable = true
menu-bar-scroll-switch = true    # scroll over it = previous/next non-empty workspace
menu-bar-max-width = 0           # points, 0 = auto
```

**Hidden-window placement for Mission Control.** Upstream parks windows of inactive workspaces in one screen corner. With `'directional'`, workspaces before the visible one are parked beyond the left edge and later ones beyond the right edge, so Mission Control shows them in a spatial order; `'directional-corner'` parks them at the bottom corners instead, so only a corner pixel stays visible. `hidden-window-sliver` is how many points of a parked window stay on screen.

```toml
hidden-window-placement = 'directional'    # 'corner' | 'directional' | 'directional-corner'
hidden-window-sliver = 1                   # integer points (0..20)
```

Findings: this works best with System Settings > Desktop & Dock > "Group windows by application" **on**. Without grouping, Mission Control's order looked mirrored and became random with three or more workspaces. Fractional slivers do not work (macOS pulls fractional window positions back by about 40 pt), so the value is integer-only.

### Building without Xcode

Upstream's release build needs Xcode. This fork also builds with the SwiftPM toolchain only:

1. Install [swiftly](https://www.swift.org/install/macos/) and the Swift version pinned in `.swift-version` (`swiftly install` in the repo root). Run Swift through it: `swiftly run swift build`.
2. Create a stable self-signed code signing identity once, so that the Accessibility permission survives rebuilds (an ad-hoc signature changes with every build and macOS drops the grant). The script looks for an identity named `aerospace-codesign-certificate` (the name upstream's release script uses):

   ```sh
   d=$(mktemp -d)
   /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
     -keyout $d/k.pem -out $d/c.pem -subj "/CN=aerospace-codesign-certificate" \
     -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
   /usr/bin/openssl pkcs12 -export -inkey $d/k.pem -in $d/c.pem -out $d/c.p12 -passout pass:tmp
   security import $d/c.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
   security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db $d/c.pem
   security find-identity -v -p codesigning    # must list the identity
   rm -rf $d
   ```
3. `script/build-local-app.sh` does a SwiftPM release build for the host architecture, assembles `AeroSpace.app` by hand (Info.plist, entitlements, an icon made with `iconutil`, the CLI embedded in `Contents/Resources/bin`) and signs it with that identity. The result is `.local-app/AeroSpace.app`; copy it to `/Applications`. There are no docs, man pages or shell completion in this build. Options: `--codesign-identity`, `--build-version`, `--out`.

Tests: upstream's XCTest-based tests (`AppBundleTests`) need Xcode. The fork's own logic is covered by a [Swift Testing](https://github.com/swiftlang/swift-testing) target, `ForkTests`, which runs without XCTest:

```sh
swiftly run swift build --target ForkTests && swiftly run swift test --skip-build --disable-xctest --filter ForkTests
```

### Credits

- [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko and contributors (MIT): everything not listed here.
- [Skyland](https://github.com/waxdred/skyland) (MIT): the dwindle window insertion, the modifier mouse drag and the trackpad gestures were ported or adapted from it.
- [yabai](https://github.com/koekeishiya/yabai) (MIT): the technique for focusing a window without raising it.
- [SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace) (MIT): the approach for tracking trackpad swipes.
- [N1ark](https://github.com/N1ark): the left/right modifier bindings commit series.

## Key features

- Tiling window manager based on a [tree paradigm](https://nikitabobko.github.io/AeroSpace/guide#tree)
- [i3](https://i3wm.org/) inspired
- Fast workspaces switching without animations and without the necessity to disable SIP
- AeroSpace employs its [own emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) instead of relying on native macOS Spaces due to [their considerable limitations](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)
- Plain text configuration (dotfiles friendly). See: [default-config.toml](https://nikitabobko.github.io/AeroSpace/guide#default-config)
- CLI first (manpages and shell completion included)
- Doesn't require disabling SIP (System Integrity Protection)
- [Proper multi-monitor support](https://nikitabobko.github.io/AeroSpace/guide#multiple-monitors) (i3-like paradigm)

## Installation

Install via [Homebrew](https://brew.sh/) to get autoupdates (Preferred)

```
brew install --cask nikitabobko/tap/aerospace
```

In multi-monitor setup please make sure that monitors [are properly arranged](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement).

Other installation options: https://nikitabobko.github.io/AeroSpace/guide#installation

> [!NOTE]
> By using AeroSpace, you acknowledge that it's not [notarized](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
>
> Notarization is a "security" feature by Apple.
> You send binaries to Apple, and they either approve them or not.
> In reality, notarization is about building binaries the way Apple likes it.
>
> I don't have anything against notarization as a concept.
> I specifically don't like the way Apple does notarization.
> I don't have time to deal with Apple.
>
> [Homebrew installation script](https://github.com/nikitabobko/homebrew-tap/blob/main/Casks/aerospace.rb) is configured to
> automatically delete `com.apple.quarantine` attribute, that's why the app should work out of the box, without any warnings that
> "Apple cannot check AeroSpace for malicious software"

## Community, discussions, issues

AeroSpace project doesn't accept Issues directly - we ask you to create a [Discussion](https://github.com/nikitabobko/AeroSpace/discussions) first.
Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for more details.

Community discussions happen at GitHub Discussions.
There you can discuss bugs, propose new features, ask your questions, show off your setup, or just chat.

There are 7 channels:
-   [#all](https://github.com/nikitabobko/AeroSpace/discussions).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions.atom?discussions_q=sort%3Adate_created).
    Feed with all discussions.
-   [#announcements](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements.atom?discussions_q=category%3Aannouncements+sort%3Adate_created).
    Only maintainers can post here.
    Highly moderated traffic.
-   [#announcements-releases](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases.atom?discussions_q=category%3Aannouncements-releases+sort%3Adate_created).
    Announcements about non-patch releases.
    Only maintainers can post here.
-   [#feature-ideas](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas.atom?discussions_q=category%3Afeature-ideas+sort%3Adate_created).
-   [#general](https://github.com/nikitabobko/AeroSpace/discussions/categories/general).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/general.atom?discussions_q=sort%3Adate_created+category%3Ageneral).
-   [#potential-bugs](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs.atom?discussions_q=category%3Apotential-bugs+sort%3Adate_created).
    If you think that you have encountered a bug, you can discuss your bugs here.
-   [#questions-and-answers](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers.atom?discussions_q=category%3Aquestions-and-answers+sort%3Adate_created).
    Everyone is welcome to ask questions.
    Everyone is encouraged to answer other people's questions.

## Project status

Public Beta. AeroSpace can be used as a daily driver, but expect breaking changes until 1.0 is reached.

What stops us from 1.0 release:
- [x] https://github.com/nikitabobko/AeroSpace/issues/131 Performance. Implement thread-per-application to circumvent macOS blocking AX API.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1215 _Big refactoring_. Rewrite mutable double-linked core tree data structure to immutable single-linked persistent tree.
  Important for: stability and potential performance
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/1216 The big refactoring will help us to fix stability issue that windows may randomly jump to the focused workspace
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/68 The big refactoring will help us to support macOS native tabs
- [x] https://github.com/nikitabobko/AeroSpace/issues/278 Implement shell-like combinators.
  Ignore a lot of crazy fuss in the issue,
  We are most probably going with the minimal approach to only introduce common shell-combinators: `||`, `&&`, `;` and `eval` command to send multiple commands in one go.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1012 Investigate a possibility to use `CGEvent.tapCreate` API for global hotkeys
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/28 Maybe it will allow to distinguish left and right modifiers. Maybe not

Big and important issues which will go after 1.0 release:
- [ ] https://github.com/nikitabobko/AeroSpace/issues/2 sticky windows
- [ ] https://github.com/nikitabobko/AeroSpace/issues/260 Dynamic TWM

## Development

A notes on how to setup the project, build it, how to run the tests, etc. can be found here: [dev-docs/development.md](./dev-docs/development.md)

## Project values

**Values**
- AeroSpace is targeted at advanced users and developers
- Keyboard centric
- Breaking changes (configuration files, CLI, behavior) are avoided as much as possible, but it must not let the software stagnate.
  Thus breaking changes can happen, but with careful considerations and helpful message.
  [Semver](https://semver.org/) major version is bumped in case of a breaking change (It's all guaranteed once AeroSpace reaches 1.0 version, until then breaking changes just happen)
- AeroSpace doesn't use GUI, unless necessarily
  - AeroSpace will never provide a GUI for configuration.
    For advanced users, it's easier to edit a configuration file in text editor rather than navigating through checkboxes in GUI.
  - Status menu icon is ok, because visual feedback is needed
- Provide _practical_ features. Fancy appearance features are not _practical_ (e.g. window borders, transparency, animations, etc.)
- "dark magic" (aka "private APIs", "code injections", etc.) must be avoided as much as possible
  - Right now, AeroSpace uses only a single private API to get window ID of accessibility object `_AXUIElementGetWindow`.
    Everything else is [macOS public accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h).
  - AeroSpace will never require you to disable SIP (System Integrity Protection).
  - The goal is to make AeroSpace easily maintainable, and resistant to macOS updates.

**Non Values**
- Play nicely with existing macOS features.
  If limitations are imposed then AeroSpace won't play nicely with existing macOS features
  (For example, AeroSpace doesn't acknowledge the existence of macOS Spaces, and it uses [emulation of its own workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces))
- Ricing.
  AeroSpace provides only a very minimal support for ricing - gaps and a few callbacks for integrations with bars.
  The current maintainer doesn't care about ricing.
  Ricing issues are not a priority, and they are mostly ignored.
  The ricing stance can change only with the appearance of more maintainers.

## macOS compatibility

* AeroSpace binary runs on: macOS 13+
* AeroSpace debug build from sources is supported on: macOS 14+
* AeroSpace release build from sources is supported on: macOS 15+ (Requires: Swift 6.4, Xcode 26.6+)

## Sponsorship

AeroSpace is developed and maintained in my free time.
If you find it useful, [consider sponsoring](https://github.com/sponsors/nikitabobko#sponsors).

## People who have write access

In alphabetical order:

- [@mobile-ar](https://github.com/mobile-ar)
- [@nikitabobko](https://github.com/nikitabobko)
- [@rickyz](https://github.com/rickyz)

## Tip of the day

```bash
defaults write -g NSWindowShouldDragOnGesture -bool true
```

Now, you can move windows by holding `ctrl`+`cmd` and dragging any part of the window (not necessarily the window title)

Source: [reddit](https://www.reddit.com/r/MacOS/comments/k6hiwk/keyboard_modifier_to_simplify_click_drag_of/)

## Related projects

In alphabetical order:

- [Amethyst](https://github.com/ianyh/Amethyst) -
  Beginners friendly GUI-configurable tiling window manager with automatic layouts à la xmonad.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) -
  Instant space switching by synthesizing trackpad gesture with an artificially high velocity.
- [rift](https://github.com/acsandmann/rift) -
  Virtual workspaces + private APIs.
- [yabai](https://github.com/koekeishiya/yabai) -
  A window manager that provides tight integration with native macOS Spaces and goes all the way to private APIs and code injection.
  yabai is a source of inspiration for a lot of other OSS projects.
