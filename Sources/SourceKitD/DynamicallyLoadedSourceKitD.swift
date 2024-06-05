//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import SKSupport
import SwiftExtensions

import struct TSCBasic.AbsolutePath

#if compiler(<5.11)
extension DLHandle: @unchecked Sendable {}
#else
extension DLHandle: @unchecked @retroactive Sendable {}
#endif
extension sourcekitd_api_keys: @unchecked Sendable {}
extension sourcekitd_api_requests: @unchecked Sendable {}
extension sourcekitd_api_values: @unchecked Sendable {}

public struct SourceKitDTestHooks: Sendable {
  public var sourcekitdRequestDidStart: (@Sendable (SKDRequestDictionary) -> Void)?

  public init(sourcekitdRequestDidStart: (@Sendable (SKDRequestDictionary) -> Void)? = nil) {
    self.sourcekitdRequestDidStart = sourcekitdRequestDidStart
  }
}

/// Wrapper for sourcekitd, taking care of initialization, shutdown, and notification handler
/// multiplexing.
///
/// Users of this class should not call the api functions `initialize`, `shutdown`, or
/// `set_notification_handler`, which are global state managed internally by this class.
public actor DynamicallyLoadedSourceKitD: SourceKitD {
  /// The path to the sourcekitd dylib.
  private let path: AbsolutePath

  /// The handle to the dylib.
  private let dylib: DLHandle

  public let testHooks: SourceKitDTestHooks

  /// The sourcekitd API functions.
  public let api: sourcekitd_api_functions_t

  /// Convenience for accessing known keys.
  public let keys: sourcekitd_api_keys

  /// Convenience for accessing known keys.
  public let requests: sourcekitd_api_requests

  /// Convenience for accessing known keys.
  public let values: sourcekitd_api_values

  private nonisolated let notificationHandlingQueue = AsyncQueue<Serial>()

  /// List of notification handlers that will be called for each notification.
  private var notificationHandlers: [WeakSKDNotificationHandler] = []

  /// If there is already a `sourcekitd` instance from the given return it, otherwise create a new one.
  ///
  /// `testHooks` are only considered when an instance is being created. If a sourcekitd instance at the given path
  /// already exists, its test hooks will be used.
  public static func getOrCreate(dylibPath: AbsolutePath, testHooks: SourceKitDTestHooks) async throws -> SourceKitD {
    try await SourceKitDRegistry.shared
      .getOrAdd(dylibPath, create: { try DynamicallyLoadedSourceKitD(dylib: dylibPath, testHooks: testHooks) })
  }

  init(dylib path: AbsolutePath, testHooks: SourceKitDTestHooks) throws {
    self.path = path
    #if os(Windows)
    self.dylib = try dlopen(path.pathString, mode: [])
    #else
    self.dylib = try dlopen(path.pathString, mode: [.lazy, .local, .first])
    #endif
    self.testHooks = testHooks
    self.api = try sourcekitd_api_functions_t(self.dylib)
    self.keys = sourcekitd_api_keys(api: self.api)
    self.requests = sourcekitd_api_requests(api: self.api)
    self.values = sourcekitd_api_values(api: self.api)

    self.api.initialize()
    self.api.set_notification_handler { [weak self] rawResponse in
      guard let self, let rawResponse else { return }
      let response = SKDResponse(rawResponse, sourcekitd: self)
      self.notificationHandlingQueue.async {
        let handlers = await self.notificationHandlers.compactMap(\.value)

        for handler in handlers {
          handler.notification(response)
        }
      }
    }
  }

  deinit {
    self.api.set_notification_handler(nil)
    self.api.shutdown()
    // FIXME: is it safe to dlclose() sourcekitd? If so, do that here. For now, let the handle leak.
    dylib.leak()
  }

  /// Adds a new notification handler (referenced weakly).
  public func addNotificationHandler(_ handler: SKDNotificationHandler) {
    notificationHandlers.removeAll(where: { $0.value == nil })
    notificationHandlers.append(.init(handler))
  }

  /// Removes a previously registered notification handler.
  public func removeNotificationHandler(_ handler: SKDNotificationHandler) {
    notificationHandlers.removeAll(where: { $0.value == nil || $0.value === handler })
  }

  public nonisolated func log(request: SKDRequestDictionary) {
    logger.info(
      """
      Sending sourcekitd request:
      \(request.forLogging)
      """
    )
  }

  public nonisolated func log(response: SKDResponse) {
    logger.log(
      level: (response.error == nil || response.error == .requestCancelled) ? .debug : .error,
      """
      Received sourcekitd response:
      \(response.forLogging)
      """
    )
  }

  public nonisolated func log(crashedRequest req: SKDRequestDictionary, fileContents: String?) {
    let log = """
      Request:
      \(req.description)

      File contents:
      \(fileContents ?? "<nil>")
      """
    let chunks = splitLongMultilineMessage(message: log)
    for (index, chunk) in chunks.enumerated() {
      logger.fault(
        """
        sourcekitd crashed (\(index + 1)/\(chunks.count))
        \(chunk)
        """
      )
    }
  }

  public nonisolated func logRequestCancellation(request: SKDRequestDictionary) {
    // We don't need to log which request has been cancelled because we can associate the cancellation log message with
    // the send message via the log
    logger.info(
      """
      Cancelling sourcekitd request:
      \(request.forLogging)
      """
    )
  }
}

struct WeakSKDNotificationHandler: Sendable {
  weak private(set) var value: SKDNotificationHandler?
  init(_ value: SKDNotificationHandler) {
    self.value = value
  }
}
