//
//  MetalCapture.swift
//  PlayTools
//
//  Created by hguandl on 2026/9/2.
//

import Foundation
import Metal
import OSLog

final class MetalCapture: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data

    init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }
}

enum MetalCaptureError: Error {
    case disabled
    case outdated
    case unavailable
}

final class MetalCaptureState: @unchecked Sendable {
    private var commandQueue: MTLCommandQueue?
    private var continuation: UnsafeContinuation<MetalCapture, any Error>?

    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init() {
        lock.initialize(to: .init())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func initialize(commandQueue: MTLCommandQueue) {
        os_unfair_lock_lock(lock)
        guard self.commandQueue == nil else {
            fatalError("Cannot initialize twice")
        }
        self.commandQueue = commandQueue
        os_unfair_lock_unlock(lock)
    }

    func register(continuation: UnsafeContinuation<MetalCapture, any Error>) {
        os_unfair_lock_lock(lock)
        let oldContinuation = self.continuation
        self.continuation = continuation
        os_unfair_lock_unlock(lock)
        oldContinuation?.resume(throwing: MetalCaptureError.outdated)
    }

    func takeContinuation() -> UnsafeContinuation<MetalCapture, any Error>? {
        guard os_unfair_lock_trylock(lock) else {
            return nil
        }
        guard let continuation else {
            os_unfair_lock_unlock(lock)
            return nil
        }
        self.continuation = nil
        os_unfair_lock_unlock(lock)
        return continuation
    }
}
