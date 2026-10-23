import AppKit
import Testing
@testable import UniversalTranslator

// Moving the caption overlay: where a drop is remembered, on which display, and the Dock menu that unlocks it.

@Suite struct OverlayTests {
    // Two displays side by side in AppKit's coordinates (origin bottom left of the main one), menu bar and Dock
    // already taken out of their visible areas.
    private let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 912)
    private let external = NSRect(x: 1512, y: -100, width: 1920, height: 1055)

    @Test func aDropIsRememberedRelativeToTheDisplayItLandedOn() {
        // Bottom center at the middle of the external display.
        let frame = NSRect(x: 1512 + 960 - 400, y: -100 + 527.5, width: 800, height: 120)
        let onExternal = OverlayController.customPosition(of: frame, in: external)
        #expect(abs(onExternal.x - 0.5) < 1e-9 && abs(onExternal.y - 0.5) < 1e-9)
        // Measured against the display it started on (the old bug), the same drop is off that display entirely.
        let onBuiltIn = OverlayController.customPosition(of: frame, in: builtIn)
        #expect(onBuiltIn.x > 1)
    }

    @Test func aRememberedPositionPutsTheOverlayBackWhereItWasDropped() {
        for visible in [builtIn, external] {
            for frame in [NSRect(x: visible.minX + 100, y: visible.minY + 40, width: 900, height: 140),
                          NSRect(x: visible.midX - 300, y: visible.midY, width: 600, height: 80)] {
                let p = OverlayController.customPosition(of: frame, in: visible)
                let origin = OverlayController.customOrigin(x: p.x, y: p.y, size: frame.size, in: visible)
                #expect(abs(origin.x - frame.minX) < 1e-6 && abs(origin.y - frame.minY) < 1e-6, "\(frame)")
            }
        }
    }

    @Test func droppingOnAnotherDisplayPicksThatDisplayWhateverTheSetting() {
        // Already on the display the setting picks: nothing changes.
        #expect(OverlayController.screenSetting(afterDropOn: "Built-in", target: "Built-in", mode: .main, name: "")
                == (.main, ""))
        #expect(OverlayController.screenSetting(afterDropOn: "LG", target: "LG", mode: .withMouse, name: "")
                == (.withMouse, ""))
        // Elsewhere: that display, by name, for every mode (it used to switch only from "main display").
        for mode in ScreenMode.allCases {
            let after = OverlayController.screenSetting(afterDropOn: "LG", target: "Built-in", mode: mode, name: "Built-in")
            #expect(after == (.specific, "LG"), "\(mode)")
        }
    }

    @Test func dockMenuOffersMoveWhileLockedAndLockWhileUnlocked() {
        #expect(AppController.dockActions(listening: false, locked: true, shown: true)
                == [.startListening, .moveCaptions, .hideCaptions, .showTranscript])
        #expect(AppController.dockActions(listening: true, locked: false, shown: false)
                == [.stopListening, .lockCaptions, .showCaptions, .showTranscript])
        #expect(AppController.DockAction.moveCaptions.title == "Move Captions…")
    }
}
