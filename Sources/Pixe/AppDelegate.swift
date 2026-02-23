import AppKit
import MetalKit

class AppDelegate: NSObject, NSApplicationDelegate {
    let imageList: ImageList
    var window: ImageWindow!
    var metalView: MetalImageView!
    var renderer: Renderer!

    init(imageList: ImageList) {
        self.imageList = imageList
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("pixe: Metal is not supported on this device\n", stderr)
            NSApp.terminate(nil)
            return
        }

        renderer = Renderer(device: device, imageList: imageList)

        metalView = MetalImageView(frame: .zero, device: device)
        metalView.delegate = renderer

        window = ImageWindow(contentView: metalView)
        renderer.window = window

        let inputHandler = InputHandler(renderer: renderer)
        metalView.inputHandler = inputHandler

        renderer.loadCurrentImage()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pixe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pixe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Window menu (required for fullscreen support)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
