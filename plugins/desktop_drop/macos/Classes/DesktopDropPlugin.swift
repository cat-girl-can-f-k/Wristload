import Cocoa
import FlutterMacOS

private let appOwnedBookmarkPrefix = "wristload-app-owned-v1:"
private let appOwnedCapabilityDefaultsPrefix = "wristload.drop.capability."
private let appOwnedDropDirectoryName = "Wristload/DropPromises"

private func findFlutterViewController(_ viewController: NSViewController?) -> FlutterViewController? {
  guard let vc = viewController else {
    return nil
  }
  if let fvc = vc as? FlutterViewController {
    return fvc
  }
  for child in vc.children {
    let fvc = findFlutterViewController(child)
    if fvc != nil {
      return fvc
    }
  }
  return nil
}

public class DesktopDropPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    guard let flutterView = registrar.view else { return }
    guard let flutterWindow = flutterView.window else { return }
    guard let vc = findFlutterViewController(flutterWindow.contentViewController) else { return }

    let channel = FlutterMethodChannel(name: "desktop_drop", binaryMessenger: registrar.messenger)

    let d = DropTarget(frame: vc.view.bounds, channel: channel)
    d.autoresizingMask = [.width, .height]

    d.registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    d.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])

    vc.view.addSubview(d)
  }
}

class DropTarget: NSView {
  private let channel: FlutterMethodChannel

  init(frame frameRect: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("entered", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("updated", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("exited", arguments: nil)
  }

  /// Application-owned directory used for accepting file promises.
  private lazy var destinationURL: URL? = {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return nil
    }
    let destination = applicationSupport.appendingPathComponent(
      appOwnedDropDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true,
        attributes: nil
      )
      return destination.standardizedFileURL.resolvingSymlinksInPath()
    } catch {
      return nil
    }
  }()

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    var items: [[String: Any]] = []
    var errors: [[String: Any]] = []
    let itemsLock = NSLock()

    func appendItem(path: String, bookmark: Data, source: String) {
      itemsLock.lock()
      defer { itemsLock.unlock() }
      items.append([
        "path": path,
        "apple-bookmark": FlutterStandardTypedData(bytes: bookmark),
        "source": source,
      ])
    }

    func appendError(path: String?, code: String, message: String) {
      itemsLock.lock()
      defer { itemsLock.unlock() }
      var payload: [String: Any] = [
        "code": code,
        "message": message,
      ]
      if let path, !path.isEmpty {
        payload["path"] = path
      }
      errors.append(payload)
    }

    func securityScopedBookmark(for fileURL: URL) throws -> Data {
      try fileURL.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }

    func appOwnedCapability(for fileURL: URL) throws -> (path: String, data: Data) {
      guard let destinationURL else {
        throw NSError(
          domain: "DesktopDropPlugin",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The application drop directory is unavailable."]
        )
      }
      let root = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
      let storedURL = fileURL.standardizedFileURL
      let storedValues = try storedURL.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
      )
      guard storedValues.isRegularFile == true,
            storedValues.isDirectory != true,
            storedValues.isSymbolicLink != true else {
        throw NSError(
          domain: "DesktopDropPlugin",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "The promised item is not a regular file."]
        )
      }
      let candidate = storedURL.resolvingSymlinksInPath()
      let rootComponents = root.pathComponents
      let candidateComponents = candidate.pathComponents
      guard candidateComponents.count > rootComponents.count,
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
        throw NSError(
          domain: "DesktopDropPlugin",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The promised file is outside the application drop directory."]
        )
      }
      let capability = UUID().uuidString.lowercased()
      UserDefaults.standard.set(
        candidate.path,
        forKey: appOwnedCapabilityDefaultsPrefix + capability
      )
      return (
        candidate.path,
        Data((appOwnedBookmarkPrefix + capability).utf8)
      )
    }

    func appendExternalItem(for fileURL: URL) {
      do {
        let bookmark = try securityScopedBookmark(for: fileURL)
        appendItem(path: fileURL.path, bookmark: bookmark, source: "external")
      } catch {
        appendError(
          path: fileURL.path,
          code: "bookmark_failed",
          message: "Unable to authorize the dropped file: \(error.localizedDescription)"
        )
      }
    }

    func appendPromisedItem(for fileURL: URL) {
      do {
        let capability = try appOwnedCapability(for: fileURL)
        appendItem(
          path: capability.path,
          bookmark: capability.data,
          source: "app-owned-file-promise"
        )
      } catch {
        appendError(
          path: fileURL.path,
          code: "promise_authorization_failed",
          message: "Unable to authorize the promised file: \(error.localizedDescription)"
        )
      }
    }

    let searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]

    let group = DispatchGroup()
    let promiseQueue = OperationQueue()
    promiseQueue.qualityOfService = .userInitiated
    promiseQueue.maxConcurrentOperationCount = 1
    promiseQueue.isSuspended = true
    var promiseDestinationURL: URL?
    var promiseDestinationError: Error?

    func destinationForPromises() throws -> URL {
      if let promiseDestinationURL { return promiseDestinationURL }
      if let promiseDestinationError { throw promiseDestinationError }
      guard let root = destinationURL else {
        let error = NSError(
          domain: "DesktopDropPlugin",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "The application drop directory is unavailable."]
        )
        promiseDestinationError = error
        throw error
      }
      let destination = root.appendingPathComponent(
        UUID().uuidString.lowercased(),
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: destination,
          withIntermediateDirectories: false,
          attributes: nil
        )
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        promiseDestinationURL = resolved
        return resolved
      } catch {
        promiseDestinationError = error
        throw error
      }
    }

    func isolatePromisedFile(_ fileURL: URL, under root: URL) throws -> URL {
      let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
      let source = fileURL.standardizedFileURL.resolvingSymlinksInPath()
      let rootComponents = resolvedRoot.pathComponents
      let sourceComponents = source.pathComponents
      guard sourceComponents.count > rootComponents.count,
            Array(sourceComponents.prefix(rootComponents.count)) == rootComponents else {
        throw NSError(
          domain: "DesktopDropPlugin",
          code: 5,
          userInfo: [NSLocalizedDescriptionKey: "The promised file was written outside its drop directory."]
        )
      }
      let itemDirectory = resolvedRoot.appendingPathComponent(
        UUID().uuidString.lowercased(),
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: itemDirectory,
        withIntermediateDirectories: false,
        attributes: nil
      )
      let isolated = itemDirectory.appendingPathComponent(
        source.lastPathComponent,
        isDirectory: false
      )
      try FileManager.default.moveItem(at: source, to: isolated)
      return isolated
    }

    // retrieve NSFilePromise.
    sender.enumerateDraggingItems(options: [], for: nil, classes: [NSFilePromiseReceiver.self, NSURL.self], searchOptions: searchOptions) { draggingItem, _, _ in
      switch draggingItem.item {
      case let filePromiseReceiver as NSFilePromiseReceiver:
        let promiseDestination: URL
        do {
          promiseDestination = try destinationForPromises()
        } catch {
          appendError(
            path: nil,
            code: "promise_destination_unavailable",
            message: "The application drop directory is unavailable: \(error.localizedDescription)"
          )
          break
        }
        filePromiseReceiver.receivePromisedFiles(atDestination: promiseDestination, options: [:], operationQueue: promiseQueue) { fileURL, error in
          defer { group.leave() }
          if let error = error {
            appendError(
              path: nil,
              code: "promise_receive_failed",
              message: "Unable to receive the promised file: \(error.localizedDescription)"
            )
          } else {
            do {
              let isolated = try isolatePromisedFile(
                fileURL,
                under: promiseDestination
              )
              appendPromisedItem(for: isolated)
            } catch {
              appendError(
                path: fileURL.path,
                code: "promise_isolation_failed",
                message: "Unable to isolate the promised file: \(error.localizedDescription)"
              )
            }
          }
        }
        let callbackCount = max(filePromiseReceiver.fileNames.count, 1)
        for _ in 0..<callbackCount { group.enter() }
      case let fileURL as URL:
        appendExternalItem(for: fileURL)
      default: break
      }
    }

    promiseQueue.isSuspended = false
    group.notify(queue: .main) {
      _ = promiseQueue
      itemsLock.lock()
      let completedItems = items
      let completedErrors = errors
      itemsLock.unlock()
      self.channel.invokeMethod("performOperation_macos", arguments: [
        "items": completedItems,
        "errors": completedErrors,
      ])
    }
    return true
  }

  func convertPoint(_ location: NSPoint) -> [CGFloat] {
    return [location.x, bounds.height - location.y]
  }
}
