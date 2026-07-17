import SwiftUI
import AVFoundation
import ApplicationServices

/// First-launch guided tour: meet the character, grant permissions, learn
/// the gestures. Taught by Palmo itself.
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var page = 0
    @State private var cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            BuddyView(mood: page == pages - 1 ? .happy : .idle)
                .frame(width: page == 2 ? 70 : 110, height: page == 2 ? 70 : 110)
                .padding(.top, page == 2 ? 16 : 30)

            ScrollView {
                Group {
                    switch page {
                    case 0: intro
                    case 1: permissions
                    case 2: gestures
                    default: finish
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? AnyShapeStyle(Brand.gradient)
                                            : AnyShapeStyle(.quaternary))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == pages - 1 ? "Let's go!" : "Continue") {
                    if page == pages - 1 {
                        settings.onboardingDone = true
                        onDone()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
        .background(.regularMaterial)
    }

    private let pages = 4

    private var intro: some View {
        VStack(spacing: 10) {
            Text("Hi, I'm \(Brand.name)!")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(Brand.tagline)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("I watch for your hand through the camera — wave to summon a menu, pinch to click, and chat with me anytime. Everything I see stays on your Mac.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 6)
        }
    }

    private var permissions: some View {
        VStack(spacing: 16) {
            Text("Two quick permissions")
                .font(.system(.title, design: .rounded).weight(.bold))
            permissionRow(icon: "camera.fill", title: "Camera",
                          detail: "So I can see your hand. Frames never leave this Mac.",
                          granted: cameraGranted) {
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { cameraGranted = ok }
                }
            }
            permissionRow(icon: "cursorarrow.motionlines", title: "Accessibility",
                          detail: "So pinches can move and click your real cursor.",
                          granted: axTrusted) {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                axTrusted = AXIsProcessTrustedWithOptions(opts)
            }
        }
        .padding(.horizontal, 36)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = AXIsProcessTrusted()
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    private func permissionRow(icon: String, title: String, detail: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Brand.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant", action: action).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var gestures: some View {
        VStack(spacing: 8) {
            Text("The gestures")
                .font(.system(.title, design: .rounded).weight(.bold))
            gestureRow("hand.raised.fill", "Open palm", "Hold your palm up to summon the app orbs")
            gestureRow("hand.pinch.fill", "Pinch", "Pinch an orb to launch it — or pinch-tap to click in mouse mode")
            gestureRow("cursorarrow", "Pinch + drag", "Grab the gray orb and drag it like a trackpad")
            gestureRow("hand.point.up.braille.fill", "Fist + move", "Make a fist and move up or down to scroll")
            gestureRow("hand.thumbsup.fill", "Thumbs up", "Play or pause whatever's playing")
            gestureRow("hand.wave.fill", "Peace sign", "Snap a screenshot to your Desktop")
        }
        .padding(.horizontal, 36)
    }

    private func gestureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Brand.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var finish: some View {
        VStack(spacing: 12) {
            Text("You're all set!")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Find me anytime in the menu bar. Chat with me too — I run entirely on your Mac with Apple Intelligence. Private, offline, free.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 44)
            Toggle("Start \(Brand.name) at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }))
                .toggleStyle(.switch)
                .padding(.top, 8)
        }
    }
}
