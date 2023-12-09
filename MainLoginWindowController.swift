//
//  MainLoginWindowController.swift
//  XCredsLoginPlugin
//
//  Created by Timothy Perfitt on 12/7/23.
//

import Cocoa

class MainLoginWindowController: NSWindowController {
    var controlsViewController: ControlsViewController?
    var setupDone=false
    @IBOutlet weak var backgroundImageView: NSImageView!
    @IBOutlet weak var loginWindowView: NSView!
    var resolutionObserver:Any?
    var networkChangeObserver:Any?
    var centerView:NSView?

    func setControlsDelegate(_ delegate:XCredsMechanismProtocol){

        self.controlsViewController?.delegate=delegate
    }
    override func windowDidLoad() {
        super.windowDidLoad()

        window?.canBecomeVisibleWithoutLogin=true
//        window?.level = .normal
//        window?.backgroundColor = NSColor.white
//        window?.titlebarAppearsTransparent = true
//        window?.isMovable = false
        let screenRect = NSScreen.screens[0].frame
        window?.setFrame(screenRect, display: true, animate: false)
        window?.alphaValue=0.9
    }
    override func awakeFromNib() {
        TCSLogWithMark()
        //awakeFromNib gets called multiple times. guard against that.
        if setupDone == false {
//            updateLoginWindowInfo()
            setupDone=true

            controlsViewController = ControlsViewController.initFromPlugin()
            guard let controlsViewController = controlsViewController else {
                return
            }
            self.window?.contentView?.addSubview(controlsViewController.view)
            let rect = NSMakeRect(0, 0, controlsViewController.view.frame.size.width,120)
            controlsViewController.view.frame=rect
//            controlsViewController.delegate=self.delegate

            TCSLogWithMark("Configure login window")
//            loginAppearance()
            setupLoginWindowAppearance()

            TCSLogWithMark("create background windows")
            createBackground()

            TCSLogWithMark("Become first responder")
            TCSLogWithMark("Finishing loading loginwindow")

//            os_log("Finishing loading loginwindow", log: uiLog, type: .debug)

            // Disabling due to it causing screen resizing during EULA
            let notificationCenter = NotificationCenter.default
            notificationCenter.addObserver(self,
                                           selector: #selector(updateWindowAfterResize),
                                           name: NSApplication.didChangeScreenParametersNotification,
                                           object: nil)
        }

    }
    @objc fileprivate func updateWindowAfterResize() {

        DispatchQueue.main.async{
            if self.window?.isVisible ?? true {
                let screenRect = NSScreen.screens[0].frame
                let screenWidth = screenRect.width
                let screenHeight = screenRect.height

                self.window?.setFrame(NSMakeRect(0,0 , screenWidth, screenHeight), display: true)

                let rect = NSMakeRect(0, 0, screenWidth,120)

                self.controlsViewController?.view.frame=rect
                self.recenterCenterView()
            }
        }
    }
    func setupLoginWindowAppearance() {
        DispatchQueue.main.async {

            NSApp.activate(ignoringOtherApps: true)

            TCSLogWithMark("setting up window...")

            self.window?.level = .normal
            self.window?.orderFrontRegardless()
            self.window?.makeKeyAndOrderFront(self)

            self.window?.backgroundColor = NSColor.blue
            self.window?.titlebarAppearsTransparent = true

            self.window?.isMovable = false
            self.window?.canBecomeVisibleWithoutLogin = true

            let screenRect = NSScreen.screens[0].frame
            let screenWidth = screenRect.width
            let screenHeight = screenRect.height

            var loginWindowWidth = screenWidth //start with full size
            var loginWindowHeight = screenHeight //start with full size

            //if prefs define smaller, then resize window
            TCSLogWithMark("checking for custom height and width")
            if DefaultsOverride.standardOverride.object(forKey: PrefKeys.loginWindowWidth.rawValue) != nil  {
                let val = CGFloat(DefaultsOverride.standardOverride.float(forKey: PrefKeys.loginWindowWidth.rawValue))
                if val > 100 {
                    TCSLogWithMark("setting loginWindowWidth to \(val)")
                    loginWindowWidth = val
                }
            }
            if DefaultsOverride.standardOverride.object(forKey: PrefKeys.loginWindowHeight.rawValue) != nil {
                let val = CGFloat(DefaultsOverride.standardOverride.float(forKey: PrefKeys.loginWindowHeight.rawValue))
                if val > 100 {
                    TCSLogWithMark("setting loginWindowHeight to \(val)")
                    loginWindowHeight = val
                }
            }

            self.window?.setFrame(screenRect, display: true, animate: false)
            let rect = NSMakeRect(0, 0, self.window?.contentView?.frame.size.width ?? 100,120)

            self.controlsViewController?.view.frame=rect

            let backgroundImage = DefaultsHelper.backgroundImage()
            TCSLogWithMark()
            if let backgroundImage = backgroundImage {
                backgroundImage.size=screenRect.size
                self.backgroundImageView.image=backgroundImage
                self.backgroundImageView.imageScaling = .scaleProportionallyUpOrDown

                self.backgroundImageView.frame=NSMakeRect(screenRect.origin.x, screenRect.origin.y, screenRect.size.width, screenRect.size.height-100)

            }
            TCSLogWithMark()
        }
//            self.window?.setFrame(NSMakeRect((screenWidth-CGFloat(width))/2,(screenHeight-CGFloat(height))/2, CGFloat(width), CGFloat(height)), display: true, animate: false)
//        }
//
    }

//    @objc override var windowNibName: NSNib.Name {
//        return NSNib.Name("LoginWebView")
//    }
    func loginTransition() {
        TCSLogWithMark()
        let screenRect = NSScreen.screens[0].frame
        let progressIndicator=NSProgressIndicator.init(frame: NSMakeRect(screenRect.width/2-16  , 3*screenRect.height/4-16,32, 32))
        progressIndicator.style = .spinning
        progressIndicator.startAnimation(self)
        self.window?.contentView?.addSubview(progressIndicator)
//
//        if let controlsViewController = controlsViewController {
//            loginProgressWindowController.window?.makeKeyAndOrderFront(self)
//

//        }
        if let resolutionObserver = resolutionObserver {
            NotificationCenter.default.removeObserver(resolutionObserver)
        }
        if let networkChangeObserver = networkChangeObserver {
            NotificationCenter.default.removeObserver(networkChangeObserver)
        }



        NSAnimationContext.runAnimationGroup({ (context) in
            context.duration = 1.0
            context.allowsImplicitAnimation = true
            self.centerView?.animator().alphaValue = 0.0
            let origin = self.controlsViewController?.view.frame.origin
            let size = self.controlsViewController?.view.frame.size

            if let origin = origin, let size = size {
                self.controlsViewController?.view.animator().setFrameOrigin(NSMakePoint(origin.x, origin.y-(2*size.height)))
            }
        }, completionHandler: {
            self.centerView?.alphaValue = 0.0
            self.controlsViewController?.view.animator().alphaValue=0.0

            self.centerView?.removeFromSuperview()
//            self.window?.orderOut(self)
            self.controlsViewController?.view.removeFromSuperview()

        })

    }

    fileprivate func createBackground() {
//        var image: NSImage?
        // Is a background image path set? If not just use gray.
//        if let backgroundImage = getManagedPreference(key: .BackgroundImage) as? String  {
//            os_log("BackgroundImage preferences found.", log: uiLog, type: .debug)
//            image = NSImage(contentsOf: URL(fileURLWithPath: backgroundImage))
//        }
//
//        if let backgroundImageData = getManagedPreference(key: .BackgroundImageData) as? Data {
//            os_log("BackgroundImageData found", log: uiLog, type: .debug)
//            image = NSImage(data: backgroundImageData)
//        }
        let backgroundImage = DefaultsHelper.backgroundImage()
        let screenRect = NSScreen.screens[0].frame
        TCSLogWithMark()
        if let backgroundImage = backgroundImage {
            TCSLogWithMark()
            backgroundImageView.image?.size=screenRect.size
            TCSLogWithMark()

            backgroundImageView.image=backgroundImage
            TCSLogWithMark()

            backgroundImage.size=screenRect.size
            TCSLogWithMark()

            backgroundImageView.imageScaling = .scaleProportionallyUpOrDown
            TCSLogWithMark()
            backgroundImageView.frame=NSMakeRect(screenRect.origin.x, screenRect.origin.y, screenRect.size.width, screenRect.size.height-100)
            TCSLogWithMark()

        }
        TCSLogWithMark()

    }
    func recenterCenterView()  {
        if let contentView = self.window?.contentView, let centerView = self.centerView {
            var x = NSMidX(contentView.frame)
            var y = NSMidY(contentView.frame)

            x = x - centerView.frame.size.width/2
            y = y - centerView.frame.size.height/2
            let lowerLeftCorner = NSPoint(x: x, y: y)

            centerView.setFrameOrigin(lowerLeftCorner)
        }

    }
    func addCenterView(_ centerView:NSView){
        TCSLogWithMark("re-centering")
        if self.centerView != nil {
            self.centerView?.removeFromSuperview()
        }
        self.centerView=centerView
        self.window?.contentView?.addSubview(centerView)
        recenterCenterView()
    }




}
