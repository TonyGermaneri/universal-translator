// Prints where the mouse pointer is, then (given x y) moves it there, in global coordinates with the origin at the
// top left of the main display: for tier3's hover test. Moving the pointer needs no permission.
//   swift Tests/tier3/mouse.swift [x y]
import AppKit

let main = NSScreen.screens.first?.frame.height ?? 0
let now = NSEvent.mouseLocation
print("\(now.x) \(main - now.y)")
let args = CommandLine.arguments
if args.count == 3, let x = Double(args[1]), let y = Double(args[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
}
