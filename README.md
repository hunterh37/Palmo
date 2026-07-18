<div align="center">

# 🖐️ Palmo

### Your Mac, in the palm of your hand.

**Palmo** is a cute, delightful assistant that lives on your Mac. Wave to summon it, pinch the air to launch apps, make a fist to scroll — and chat with it anytime. It runs **entirely on-device**: your camera frames and your conversations never leave your machine.

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![On-device AI](https://img.shields.io/badge/AI-100%25%20on--device-34C759)](https://www.apple.com/apple-intelligence/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#-license)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#-contributing)

</div>

---

## ✨ What is Palmo?

Palmo turns your Mac's webcam into a hands-free control surface. Hold your palm up to the camera and a **3D orb menu** floats into view — pinch an orb to launch an app, toggle media, or start a conversation. No wearables, no cloud, no accounts. Just your hand and your Mac.

Under the hood, Palmo pairs Apple's **Vision** framework for real-time hand tracking with Apple's **on-device Foundation Models** for a warm little chat buddy that remembers your conversations — all without a single byte leaving your computer.

> **Privacy first, by design.** Hand tracking runs locally through Apple's Vision framework. The assistant runs locally through Apple Intelligence. Camera frames are never uploaded or stored, and your chat history stays on your Mac.

---

## 🎯 Features

- **🫲 Palm-to-summon orb menu** — Raise an open palm and a 3D orb menu materializes. Pinch to select.
- **🖱️ Trackpad-style mouse control** — Drive the real macOS cursor with a pinch-and-drag gesture, complete with pinch-to-click.
- **📜 Gesture commands** — Fist to scroll, peace sign for a screenshot, thumbs-up for play/pause — all remappable in Settings.
- **💬 Palmo, your on-device buddy** — A cheerful, hand-shaped assistant powered by Apple's Foundation Models. Fully offline, free, and persistent across launches.
- **🧠 Claude Code session orbs** — Optional hooks surface your live Claude Code sessions as floating orbs, so you can see at a glance when a session finishes.
- **🪟 Collapse mode** — Shrink Palmo into a small always-on-top overlay pinned to the corner of your screen.
- **🎨 Liquid Glass design** — A native macOS 26 interface with an animated liquid-glass backdrop and floating glass panels.
- **🧭 Guided onboarding** — Palmo teaches you the gestures itself on first launch.

---

## 👋 Gestures

| Gesture | Action |
| :-- | :-- |
| ✋ Open palm up | Summon the orb menu |
| 🤏 Pinch | Select an orb / click |
| ✊ Fist | Scroll the frontmost window |
| ✌️ Peace sign | Take a screenshot |
| 👍 Thumbs-up | Play / Pause media |

_All command gestures are remappable in **Settings → Gestures**._

---

## 🚀 Getting Started

### Requirements

- macOS **26.0** or later
- A Mac with a camera
- **Apple Intelligence** enabled (for the on-device assistant)
- Xcode **26+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build from source

### Build from source

```bash
# 1. Clone
git clone https://github.com/DicyaninLabs/Palmo.git
cd Palmo

# 2. Generate the Xcode project
xcodegen generate

# 3. Open and run
open HandOrbMenu.xcodeproj
```

Then press **⌘R** in Xcode. On first launch, Palmo will walk you through granting camera access and (optionally) Accessibility permission for cursor control.

### Package a distributable `.dmg`

```bash
./Scripts/make-dmg.sh
```

This builds a universal (Apple Silicon + Intel) Release build and produces `dist/Palmo.dmg`. Set `SIGN_ID` to your `Developer ID Application` identity to codesign for distribution.

---

## 🔐 Permissions

Palmo asks only for what it needs, and explains why:

- **Camera** — to detect your hand for gesture control. Frames are processed locally and never stored.
- **Accessibility** — only if you enable mouse control, so Palmo can move the cursor and post clicks.

---

## 🏗️ Architecture

Palmo is a native SwiftUI app built around a small set of focused engines:

- **`HandVisionPipeline`** — captures webcam frames via AVFoundation and runs Apple's Vision hand-pose model, reducing each hand to normalized joints plus derived gesture facts (pinch, fist, open palm, extended-finger count).
- **`HandMenuModel`** — the app's brain: owns the capture session, drives the orb engine, and publishes UI state on the main actor.
- **`OrbMenu` / `OrbSceneView`** — the floating 3D orb menu and its rendering.
- **`MouseControlEngine`** — trackpad-style relative cursor control via `CGEvent`.
- **`GestureCommandEngine`** — hold-to-confirm air-gesture commands with cooldowns so nothing misfires.
- **`AssistantEngine`** — Palmo's chat brain, backed by Apple's on-device `FoundationModels`, with a persistent transcript.
- **`ClaudeSessionStore`** — watches a state directory that Claude Code hooks write into, surfacing live sessions as orbs.

Everything forward-facing flows through a single **`Brand`** source of truth, and the whole UI floats on a shared **Liquid Glass** design system.

---

## 🤝 Contributing

Contributions are warmly welcome! Whether it's a new gesture, a bug fix, or a design tweak:

1. Fork the repo and create a feature branch.
2. Make your change (keep it native SwiftUI and privacy-preserving).
3. Open a pull request with a clear description.

Please keep Palmo's core promise intact: **nothing leaves the user's Mac.**

---

## 📄 License

Released under the **MIT License**. See [`LICENSE`](LICENSE) for details.

---

<div align="center">
<br/>

Crafted with 🖐️ by

<a href="https://dicyaninlabs.com">
<img src="docs/assets/dicyanin-labs-logo.png" alt="Dicyanin Labs" width="180"/>
</a>

<sub>[dicyaninlabs.com](https://dicyaninlabs.com)</sub>

</div>
