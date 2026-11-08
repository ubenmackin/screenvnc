// Rendering — In-session reference sheet for touch, trackpad, and hardware gestures.
import SwiftUI

public struct GestureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Universal Multi-Touch") {
                    gestureRow(icon: "hand.tap", title: "Two-Finger Tap", detail: "Right-Click (context menu)")
                    gestureRow(icon: "hand.draw", title: "Two-Finger Drag", detail: "Scroll remote Mac (vertical & horizontal)")
                    gestureRow(icon: "arrow.up.left.and.arrow.down.right", title: "Pinch & Slide", detail: "Zoom around fingers and pan simultaneously")
                    gestureRow(icon: "hand.point.up.braille", title: "Three-Finger Tap", detail: "Middle-Click")
                    gestureRow(icon: "rectangle.and.hand.point.up.left", title: "Three-Finger Drag", detail: "Pan zoomed desktop")
                }

                Section("Direct Touch Mode") {
                    gestureRow(icon: "hand.point.up.fill", title: "Single Tap / Double-Tap", detail: "Left-click or double-click at exact spot")
                    gestureRow(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "Single-Finger Drag (Zoomed)", detail: "Pan around zoomed or 1:1 desktop")
                    gestureRow(icon: "hand.tap.fill", title: "Touch & Hold, Then Drag", detail: "Drag windows, sliders, or select text")
                }

                Section("Virtual Trackpad Mode") {
                    gestureRow(icon: "cursorarrow.motionlines", title: "Single-Finger Drag", detail: "Move remote cursor in real time; auto-pans near zoomed edges")
                    gestureRow(icon: "cursorarrow.click", title: "Single Tap", detail: "Left-click at cursor")
                    gestureRow(icon: "cursorarrow.click.2", title: "Double-Tap-Hold or Long-Press + Drag", detail: "Click-and-drag windows or text selection")
                }

                Section("Hardware Mouse & Keyboard") {
                    gestureRow(icon: "computermouse", title: "Bluetooth / Magic Trackpad", detail: "Hover to move cursor, secondary click, native scroll wheel")
                    gestureRow(icon: "keyboard", title: "External Keyboard", detail: "Arrows, Esc, Tab, Return, F1–F12, and Cmd/Opt/Ctrl/Shift chords")
                }
            }
            .navigationTitle("Gesture Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func gestureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
