//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import OSLog
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?
    // mode 7 启动/重试失败原因写入统一日志，便于用 log show 定位。
    private static let mode7Logger = Logger(subsystem: "PlayTools", category: "Mode7")

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        PlayScreen.shared.initialize()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initialize()

        if PlaySettings.shared.enableMode7 && PlaySettings.shared.resolution == 7 {
            // mode 7 固定游戏 drawable 尺寸，使渲染像素不随窗口变化。
            let pinWidth = PlaySettings.shared.windowSizeWidth.rounded()
            let pinHeight = PlaySettings.shared.windowSizeHeight.rounded()
            if pinWidth > 0 && pinHeight > 0 {
                _ = PTSetPinnedDrawableSize(CGSize(width: pinWidth, height: pinHeight))
            }
            // 仅追踪画布与真实窗口的比例，用于触摸坐标映射和 presenter 尺寸更新。
            CanvasDisplayScaler.start()
            startMode7Pipeline()
        }

        if ArknightsMetalCapture.installation == true {
            print("[PlayTools] Installed Metal capture hooks.")
        }
        DispatchQueue.main.async {
            MaaTools.shared.initialize()
        }

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        if PlaySettings.shared.displayRotation != 0 {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5, execute: {
                let rotateCommand = UIKeyCommand(
                    title: "Keep Rotation Command",
                    image: nil,
                    action: #selector(UIApplication.rotateView(_:)),
                    input: "",
                    modifierFlags: [],
                    propertyList: ["rotationIndex": PlaySettings.shared.displayRotation]
                )
                UIApplication.shared.sendAction(
                    #selector(UIApplication.rotateView(_:)),
                    to: UIApplication.shared,
                    from: rotateCommand,
                    for: nil
                )
            })
        }
    }

    private static func startMode7Pipeline(attempt: Int = 0) {
        guard PlaySettings.shared.enableMode7,
              PlaySettings.shared.resolution == 7 else { return }
        guard !PTCanvasDisplayIsActive() else { return }

        let width = Int(PlaySettings.shared.windowSizeWidth.rounded())
        let height = Int(PlaySettings.shared.windowSizeHeight.rounded())
        guard width > 0, height > 0 else { return }
        guard let sourceWindow = PlayScreen.shared.keyWindow else {
            mode7Logger.error("mode7 attempt \(attempt) aborted: key window missing")
            scheduleMode7PipelineRetry(afterAttempt: attempt)
            return
        }
        guard let hostWindow = sourceWindow.nsWindow else {
            mode7Logger.error("mode7 attempt \(attempt) aborted: host window missing for source")
            scheduleMode7PipelineRetry(afterAttempt: attempt)
            return
        }

        // 窗口绑定完成后再次固定 drawable，避免首次启动时窗口尚未出现导致 pin 丢失。
        _ = PTSetPinnedDrawableSize(CGSize(width: CGFloat(width), height: CGFloat(height)))
        if PTCanvasDisplayStart(sourceWindow, hostWindow, UInt(width), UInt(height)) {
            // presenter 建立后立即发布同一份几何快照，避免首次触控读取旧坐标。
            CanvasDisplayScaler.update()
        } else {
            mode7Logger.error("mode7 attempt \(attempt) aborted: PTCanvasDisplayStart returned false")
            scheduleMode7PipelineRetry(afterAttempt: attempt)
        }
    }

    private static func scheduleMode7PipelineRetry(afterAttempt attempt: Int) {
        let delays = [0.5, 1.5, 3.0, 5.0]
        guard attempt < delays.count else {
            // RenderServer 不可用时保留 drawable pin，让 MAA 仍能走固定尺寸 fallback。
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                startMode7Pipeline()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            startMode7Pipeline(attempt: attempt + 1)
        }
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
                if PlaySettings.shared.enableMode7 && PlaySettings.shared.resolution == 7 {
                    PTCanvasDisplayStop()
                }
                // Step 1: Resign active
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneWillResignActive?(scene)
                    NotificationCenter.default.post(name: UIScene.willDeactivateNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillResignActive?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                                object: UIApplication.shared)

                // Step 2: Enter background
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidEnterBackground?(scene)
                    NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationDidEnterBackground?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                                object: UIApplication.shared)

                // Step 2.5: End UIBackgroundTask
                // There is an expiration handler, but idk how to invoke it. Skip for now.

                // Step 3: Terminate
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidDisconnect?(scene)
                    NotificationCenter.default.post(name: UIScene.didDisconnectNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillTerminate?(UIApplication.shared)
                // Some apps will freeze or crash when click close button if we send willTerminateNotification.
                // The developer documentation says this is a "may be called method", so it can be safely skipped.
                // https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1623111-applicationwillterminate
                // swiftlint:disable:previous line_length
//                NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
//                                                object: UIApplication.shared)
                DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)

                // Step 3.5: End BGTask
                // BGTask typically runs in another process and is tricky to terminate.
                // It may run into infinite loops, end up silently heating the device up.
                // This actually happens for ToF. Hope future developers can solve this.
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }
}
