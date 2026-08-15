import Cocoa
import FlutterMacOS
import IOBluetooth
import IOBluetoothUI
import Security

private let appOwnedBookmarkPrefix = "wristload-app-owned-v1:"
private let appOwnedCapabilityDefaultsPrefix = "wristload.drop.capability."
private let appOwnedDropDirectoryName = "Wristload/DropPromises"

private func wireHex(_ data: Data) -> String {
  data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private struct PlatformBridgeError: Error {
  let code: String
  let message: String
  let details: Any?

  init(_ code: String, _ message: String, details: Any? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }

  var flutterError: FlutterError {
    FlutterError(code: code, message: message, details: details)
  }
}

/// Owns native services for the primary Flutter engine. Secondary windows only
/// render snapshots and deliberately do not create another Bluetooth transport.
final class MacOSPlatformBridge: NSObject, FlutterStreamHandler {
  private let secureStoreChannel: FlutterMethodChannel
  private let systemTimeChannel: FlutterMethodChannel
  private let rfcommChannel: FlutterMethodChannel
  private let rfcommEventChannel: FlutterEventChannel
  private let securityScopeChannel: FlutterMethodChannel
  private let rfcommTransport = MacOSRFCOMMTransport()
  private var rfcommEventSink: FlutterEventSink?
  private var pendingRFCOMMEvents: [[String: Any]] = []
  private var securityScopeURLs: [String: URL] = [:]
  private var appOwnedLeaseTokens: Set<String> = []

  init(binaryMessenger: FlutterBinaryMessenger) {
    secureStoreChannel = FlutterMethodChannel(
      name: "wristload/secure_store",
      binaryMessenger: binaryMessenger
    )
    systemTimeChannel = FlutterMethodChannel(
      name: "wristload/system_time",
      binaryMessenger: binaryMessenger
    )
    rfcommChannel = FlutterMethodChannel(
      name: "wristload/rfcomm",
      binaryMessenger: binaryMessenger
    )
    rfcommEventChannel = FlutterEventChannel(
      name: "wristload/rfcomm/events",
      binaryMessenger: binaryMessenger
    )
    securityScopeChannel = FlutterMethodChannel(
      name: "wristload/security_scope",
      binaryMessenger: binaryMessenger
    )
    super.init()

    secureStoreChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleSecureStore(call, result: result)
    }
    systemTimeChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleSystemTime(call, result: result)
    }
    rfcommChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleRFCOMM(call, result: result)
    }
    rfcommEventChannel.setStreamHandler(self)
    securityScopeChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleSecurityScope(call, result: result)
    }

    rfcommTransport.onData = { [weak self] data in
      self?.emitRFCOMM([
        "kind": "data",
        "event": "read",
        "direction": "RX",
        "bytes": data.count,
        "wireHex": wireHex(data),
        "transport": "RFCOMM/SPP",
        "platform": "macos",
      ])
    }
    rfcommTransport.onEvent = { [weak self] event in
      self?.emitRFCOMM(event)
    }
    rfcommTransport.onClosed = { [weak self] error in
      self?.emitRFCOMM(error)
    }
  }

  deinit {
    secureStoreChannel.setMethodCallHandler(nil)
    systemTimeChannel.setMethodCallHandler(nil)
    rfcommChannel.setMethodCallHandler(nil)
    rfcommEventChannel.setStreamHandler(nil)
    securityScopeChannel.setMethodCallHandler(nil)
    for (_, url) in securityScopeURLs { url.stopAccessingSecurityScopedResource() }
    rfcommTransport.disconnect()
  }

  private func handleSecurityScope(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "pickFiles":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = arguments["allowMultiple"] as? Bool ?? false
        panel.allowedFileTypes = arguments["allowedExtensions"] as? [String]
        guard panel.runModal() == .OK else { result(nil); return }
        result(try panel.urls.map { try self.bookmarkResult(for: $0) })
      case "startAccess":
        guard let arguments = call.arguments as? [String: Any],
              let data = (arguments["bookmark"] as? FlutterStandardTypedData)?.data else {
          throw PlatformBridgeError("security_scope_arguments", "Missing bookmark data.")
        }
        guard !data.isEmpty && data.count <= 65_536 else {
          throw PlatformBridgeError("security_scope_arguments", "The bookmark data is invalid.")
        }
        if let capability = appOwnedCapability(from: data) {
          result(try startAppOwnedAccess(capability: capability))
          return
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else {
          throw PlatformBridgeError("security_scope_denied", "The selected file is no longer accessible.")
        }
        do {
          let fileURL = try validatedRegularFileURL(url)
          let token = UUID().uuidString
          var response: [String: Any] = [
            "token": token,
            "path": fileURL.path,
            "started": true,
          ]
          if stale {
            response["bookmark"] = FlutterStandardTypedData(
              bytes: try bookmarkData(for: fileURL)
            )
          }
          securityScopeURLs[token] = url
          result(response)
        } catch {
          url.stopAccessingSecurityScopedResource()
          throw error
        }
      case "stopAccess":
        let arguments = call.arguments as? [String: Any]
        if let token = arguments?["token"] as? String {
          if let url = securityScopeURLs.removeValue(forKey: token) {
            url.stopAccessingSecurityScopedResource()
          } else {
            appOwnedLeaseTokens.remove(token)
          }
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch let error as PlatformBridgeError { result(error.flutterError)
    } catch { result(FlutterError(code: "security_scope", message: error.localizedDescription, details: nil)) }
  }

  private func bookmarkData(for url: URL) throws -> Data {
    try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  private func bookmarkResult(for url: URL) throws -> [String: Any] {
    let fileURL = try validatedRegularFileURL(url)
    return [
      "path": fileURL.path,
      "bookmark": FlutterStandardTypedData(bytes: try bookmarkData(for: fileURL)),
    ]
  }

  private func validatedRegularFileURL(_ url: URL) throws -> URL {
    let fileURL = url.standardizedFileURL
    let values = try fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true,
          values.isDirectory != true,
          values.isSymbolicLink != true else {
      throw PlatformBridgeError(
        "security_scope_invalid_file",
        "The file authorization does not reference a regular, non-symbolic-link file."
      )
    }
    return fileURL
  }

  private func appOwnedCapability(from data: Data) -> String? {
    guard let value = String(data: data, encoding: .utf8),
          value.hasPrefix(appOwnedBookmarkPrefix) else {
      return nil
    }
    let rawCapability = String(value.dropFirst(appOwnedBookmarkPrefix.count))
    guard let uuid = UUID(uuidString: rawCapability),
          uuid.uuidString.lowercased() == rawCapability.lowercased() else {
      return nil
    }
    return uuid.uuidString.lowercased()
  }

  private func startAppOwnedAccess(capability: String) throws -> [String: Any] {
    let defaultsKey = appOwnedCapabilityDefaultsPrefix + capability
    guard let storedPath = UserDefaults.standard.string(forKey: defaultsKey) else {
      throw PlatformBridgeError(
        "security_scope_owned_invalid",
        "The promised-file authorization is no longer valid."
      )
    }
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw PlatformBridgeError(
        "security_scope_owned_unavailable",
        "The application-owned file directory is unavailable."
      )
    }
    let root = applicationSupport
      .appendingPathComponent(appOwnedDropDirectoryName, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let storedURL = URL(fileURLWithPath: storedPath).standardizedFileURL
    let storedValues = try storedURL.resourceValues(
      forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    )
    guard storedValues.isRegularFile == true,
          storedValues.isDirectory != true,
          storedValues.isSymbolicLink != true else {
      throw PlatformBridgeError(
        "security_scope_owned_invalid_file",
        "The promised-file authorization does not reference a regular file."
      )
    }
    let candidate = storedURL.resolvingSymlinksInPath()
    let rootComponents = root.pathComponents
    let candidateComponents = candidate.pathComponents
    guard candidateComponents.count > rootComponents.count,
          Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
      UserDefaults.standard.removeObject(forKey: defaultsKey)
      throw PlatformBridgeError(
        "security_scope_owned_outside_container",
        "The promised file is outside the application-owned directory."
      )
    }
    let leaseToken = UUID().uuidString
    appOwnedLeaseTokens.insert(leaseToken)
    return [
      "token": leaseToken,
      "path": candidate.path,
      "started": true,
    ]
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    rfcommEventSink = events
    let pending = pendingRFCOMMEvents
    pendingRFCOMMEvents.removeAll(keepingCapacity: true)
    for event in pending { events(event) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    rfcommEventSink = nil
    return nil
  }

  private func emitRFCOMM(_ event: Any) {
    let deliver = { [weak self] in
      guard let self else { return }
      if let sink = self.rfcommEventSink {
        sink(event)
        return
      }
      // `pair` runs before Dart starts the RFCOMM stream for the first time.
      // Preserve native diagnostic events until the stream attaches, while
      // deliberately not retaining arbitrary binary traffic.
      guard let nativeEvent = event as? [String: Any] else { return }
      self.pendingRFCOMMEvents.append(nativeEvent)
      if self.pendingRFCOMMEvents.count > 128 {
        self.pendingRFCOMMEvents.removeFirst(
          self.pendingRFCOMMEvents.count - 128
        )
      }
    }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  private func handleSecureStore(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    do {
      switch call.method {
      case "read":
        result(try MacOSAuthKeyStore.read())
      case "write":
        guard let value = call.arguments as? String else {
          throw PlatformBridgeError(
            "secure_store_arguments",
            "Missing authkey value."
          )
        }
        try MacOSAuthKeyStore.write(value)
        result(nil)
      case "delete":
        try MacOSAuthKeyStore.delete()
        result(nil)
      case "readFor":
        let id = try secureStoreDeviceID(from: call.arguments)
        result(try MacOSAuthKeyStore.read(for: id))
      case "writeFor":
        guard let arguments = call.arguments as? [String: Any],
              let value = arguments["value"] as? String else {
          throw PlatformBridgeError(
            "secure_store_arguments",
            "Missing device authkey value."
          )
        }
        let id = try secureStoreDeviceID(from: arguments["id"])
        try MacOSAuthKeyStore.write(value, for: id)
        result(nil)
      case "deleteFor":
        let id = try secureStoreDeviceID(from: call.arguments)
        try MacOSAuthKeyStore.delete(for: id)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as PlatformBridgeError {
      result(error.flutterError)
    } catch {
      result(FlutterError(
        code: "secure_store",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func secureStoreDeviceID(from value: Any?) throws -> String {
    guard let id = value as? String else {
      throw PlatformBridgeError(
        "secure_store_arguments",
        "Missing device id."
      )
    }
    let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
      throw PlatformBridgeError(
        "secure_store_arguments",
        "The device id is invalid."
      )
    }
    return normalized
  }

  private func handleSystemTime(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard call.method == "read" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let now = Date()
    let timeZone = TimeZone.current
    let daylightSeconds = Int(timeZone.daylightSavingTimeOffset(for: now))
    let totalSeconds = timeZone.secondsFromGMT(for: now)
    let hourFormat = DateFormatter.dateFormat(
      fromTemplate: "j",
      options: 0,
      locale: Locale.current
    ) ?? "HH"
    result([
      "standardOffsetMinutes": (totalSeconds - daylightSeconds) / 60,
      "daylightOffsetMinutes": daylightSeconds / 60,
      "timezoneId": timeZone.identifier,
      "use24Hour": !hourFormat.contains("a"),
    ])
  }

  private func handleRFCOMM(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleRFCOMM(call, result: result)
      }
      return
    }

    do {
      switch call.method {
      case "pair":
        let identity = try rfcommIdentity(call.arguments)
        rfcommTransport.pair(
          peripheralID: identity.peripheralID,
          advertisedName: identity.name,
          completion: result
        )
      case "confirmIdentity":
        let identity = try rfcommIdentity(call.arguments)
        try rfcommTransport.confirmIdentity(
          peripheralID: identity.peripheralID,
          advertisedName: identity.name
        )
        result(nil)
      case "forgetIdentity":
        let peripheralID = try rfcommPeripheralID(from: call.arguments)
        rfcommTransport.forgetIdentity(peripheralID: peripheralID)
        result(nil)
      case "connect":
        let identity = try rfcommIdentity(call.arguments)
        try rfcommTransport.connect(
          peripheralID: identity.peripheralID,
          advertisedName: identity.name,
          completion: result
        )
      case "write":
        let data: Data
        if let value = call.arguments as? FlutterStandardTypedData {
          data = value.data
        } else if let value = call.arguments as? Data {
          data = value
        } else {
          throw PlatformBridgeError(
            "rfcomm_arguments",
            "RFCOMM write requires byte data."
          )
        }
        try rfcommTransport.write(data, completion: result)
      case "disconnect":
        rfcommTransport.disconnect(completion: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as PlatformBridgeError {
      result(error.flutterError)
    } catch {
      result(FlutterError(
        code: "rfcomm",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func rfcommIdentity(_ arguments: Any?) throws -> (
    peripheralID: String,
    name: String
  ) {
    guard let values = arguments as? [String: Any],
          let name = values["name"] as? String,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PlatformBridgeError(
        "rfcomm_arguments",
        "A CoreBluetooth device identifier and advertised name are required."
      )
    }
    return (try rfcommPeripheralID(from: values), name)
  }

  private func rfcommPeripheralID(from arguments: Any?) throws -> String {
    guard let values = arguments as? [String: Any],
          let value = values["peripheralId"] as? String else {
      throw PlatformBridgeError(
        "rfcomm_arguments",
        "A CoreBluetooth device identifier is required."
      )
    }
    let peripheralID = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !peripheralID.isEmpty, peripheralID.utf8.count <= 512 else {
      throw PlatformBridgeError(
        "rfcomm_arguments",
        "The CoreBluetooth device identifier is invalid."
      )
    }
    return peripheralID
  }
}

private enum MacOSAuthKeyStore {
  private static let service = "com.anemo.wristload.credentials"
  private static let legacyService = "com.example.wristload.credentials"
  private static let account = "authkey"
  private static let deviceAccountPrefix = "authkey.device."

  private static func baseQuery(
    service: String,
    account: String
  ) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  static func read() throws -> String? {
    if let value = try read(service: service, account: account) { return value }
    guard let value = try read(service: legacyService, account: account) else { return nil }
    // Migrate the old bundle-id namespace on first successful read. This
    // keeps existing macOS installations connected after the rebrand.
    try write(value)
    try? delete(service: legacyService, account: account)
    return value
  }

  /// Per-device entries deliberately remain in the current service only. The
  /// legacy service contains the former global authkey and is migrated only by
  /// `read()`, so looking up a device cannot accidentally resurrect it.
  static func read(for deviceID: String) throws -> String? {
    try read(service: service, account: deviceAccount(for: deviceID))
  }

  private static func read(service: String, account: String) throws -> String? {
    var query = baseQuery(service: service, account: account)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    try check(status, operation: "read")
    guard let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      throw PlatformBridgeError(
        "secure_store_payload",
        "The Keychain authkey payload is invalid."
      )
    }
    return value
  }

  static func write(_ value: String) throws {
    try write(value, service: service, account: account)
  }

  static func write(_ value: String, for deviceID: String) throws {
    try write(value, service: service, account: deviceAccount(for: deviceID))
  }

  private static func write(
    _ value: String,
    service: String,
    account: String
  ) throws {
    guard value.range(
      of: "^[0-9a-fA-F]{32}$",
      options: .regularExpression
    ) != nil else {
      throw PlatformBridgeError(
        "secure_store_value",
        "Authkey must be 32 hexadecimal characters."
      )
    }
    let data = Data(value.lowercased().utf8)
    let updateStatus = SecItemUpdate(
      baseQuery(service: service, account: account) as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    if updateStatus != errSecItemNotFound {
      try check(updateStatus, operation: "update")
    }
    var item = baseQuery(service: service, account: account)
    item[kSecValueData] = data
    try check(SecItemAdd(item as CFDictionary, nil), operation: "add")
  }

  static func delete() throws {
    try delete(service: service, account: account)
    try delete(service: legacyService, account: account)
  }

  static func delete(for deviceID: String) throws {
    try delete(service: service, account: deviceAccount(for: deviceID))
  }

  private static func delete(service: String, account: String) throws {
    let status = SecItemDelete(
      baseQuery(service: service, account: account) as CFDictionary
    )
    if status == errSecItemNotFound { return }
    try check(status, operation: "delete")
  }

  private static func deviceAccount(for deviceID: String) -> String {
    // Account is a Keychain attribute, not a filesystem name. Namespacing it
    // prevents collision with the global/legacy `authkey` record while
    // preserving a one-to-one mapping for every CoreBluetooth identifier.
    deviceAccountPrefix + deviceID
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == errSecSuccess else {
      let message = SecCopyErrorMessageString(status, nil) as String?
      throw PlatformBridgeError(
        "secure_store_\(operation)",
        message ?? "Keychain operation failed (\(status)).",
        details: status
      )
    }
  }
}

private final class MacOSRFCOMMSessionDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
  // The bridge owns the transport. A weak link prevents a late Bluetooth
  // callback from keeping the whole Flutter bridge alive after shutdown.
  weak var owner: MacOSRFCOMMTransport?
  let generation: UInt64

  init(owner: MacOSRFCOMMTransport, generation: UInt64) {
    self.owner = owner
    self.generation = generation
    super.init()
  }

  @objc(sdpQueryComplete:status:)
  func sdpQueryComplete(_ queriedDevice: IOBluetoothDevice, status: IOReturn) {
    owner?.sdpQueryComplete(queriedDevice, status: status, generation: generation)
  }

  func rfcommChannelOpenComplete(
    _ openedChannel: IOBluetoothRFCOMMChannel,
    status: IOReturn
  ) {
    owner?.rfcommChannelOpenComplete(
      openedChannel,
      status: status,
      generation: generation
    )
  }

  func rfcommChannelData(
    _ source: IOBluetoothRFCOMMChannel,
    data dataPointer: UnsafeMutableRawPointer,
    length dataLength: Int
  ) {
    guard dataLength > 0 else { return }
    owner?.rfcommChannelData(
      source,
      data: Data(bytes: dataPointer, count: dataLength),
      generation: generation
    )
  }

  func rfcommChannelClosed(_ closedChannel: IOBluetoothRFCOMMChannel) {
    owner?.rfcommChannelClosed(closedChannel, generation: generation)
  }

  @objc func rfcommChannelCloseNotification(
    _ notification: IOBluetoothUserNotification,
    channel closedChannel: IOBluetoothRFCOMMChannel
  ) {
    owner?.rfcommChannelClosed(closedChannel, generation: generation)
  }
}

private enum MacOSRFCOMMSessionPhase {
  case queryingSDP
  case cancellingSDP
  case opening
  case connected
  case closingLocal
}

private final class MacOSRFCOMMSession {
  let generation: UInt64
  let delegate: MacOSRFCOMMSessionDelegate
  let device: IOBluetoothDevice
  let peripheralID: String
  let advertisedName: String
  let ioQueue: DispatchQueue
  private let stateLock = NSLock()
  private var writesCancelled = false
  private var closeRequested = false
  private var channelTeardownScheduled = false
  private var scheduledCloseObjectIDs: Set<IOBluetoothObjectID> = []
  private var scheduledCloseChannels: Set<ObjectIdentifier> = []
  private var channelsForTeardown: [
    ObjectIdentifier: IOBluetoothRFCOMMChannel
  ] = [:]
  var phase: MacOSRFCOMMSessionPhase = .queryingSDP
  var channel: IOBluetoothRFCOMMChannel?
  var channelObjectID: IOBluetoothObjectID?
  var closeNotification: IOBluetoothUserNotification?
  var sdpCachePollTimer: Timer?
  var sdpBaselineUpdateMillis: Int64?
  var sdpQueryStartedMillis: Int64?
  var sdpQueryKind = "full"
  var sdpCacheRefreshObserved = false
  var teardownTimeout: Timer?
  var retirementTimeout: Timer?
  var completion: FlutterResult?
  var disconnectCompletions: [FlutterResult] = []

  init(
    generation: UInt64,
    delegate: MacOSRFCOMMSessionDelegate,
    device: IOBluetoothDevice,
    peripheralID: String,
    advertisedName: String,
    completion: @escaping FlutterResult
  ) {
    self.generation = generation
    self.delegate = delegate
    self.device = device
    self.peripheralID = peripheralID
    self.advertisedName = advertisedName
    self.ioQueue = DispatchQueue(
      label: "wristload.rfcomm.io.\(generation)",
      qos: .userInitiated
    )
    self.completion = completion
  }

  fileprivate func cancelWritesAndRequestClose() {
    stateLock.lock()
    writesCancelled = true
    closeRequested = true
    stateLock.unlock()
  }

  fileprivate func isWriteCancelled() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return writesCancelled
  }

  fileprivate func prepareChannelClose(
    for channel: IOBluetoothRFCOMMChannel
  ) -> (shouldEnqueue: Bool, detachDelegate: Bool) {
    let objectID = channel.getObjectID()
    let channelIdentity = ObjectIdentifier(channel)
    stateLock.lock()
    defer { stateLock.unlock() }
    guard closeRequested else {
      return (false, false)
    }
    let detachDelegate = channelTeardownScheduled
    if !detachDelegate {
      channelsForTeardown[channelIdentity] = channel
    }
    if objectID != kIOBluetoothObjectIDNULL {
      guard !scheduledCloseObjectIDs.contains(objectID) else {
        return (false, detachDelegate)
      }
      scheduledCloseObjectIDs.insert(objectID)
    } else {
      guard !scheduledCloseChannels.contains(channelIdentity) else {
        return (false, detachDelegate)
      }
      scheduledCloseChannels.insert(channelIdentity)
    }
    return (true, detachDelegate)
  }

  fileprivate func matchesClosedChannel(
    _ channel: IOBluetoothRFCOMMChannel
  ) -> Bool {
    if let boundChannel = self.channel, boundChannel === channel {
      return true
    }
    let objectID = channel.getObjectID()
    if let boundObjectID = channelObjectID,
       boundObjectID != kIOBluetoothObjectIDNULL,
       boundObjectID == objectID {
      return true
    }
    let channelIdentity = ObjectIdentifier(channel)
    stateLock.lock()
    defer { stateLock.unlock() }
    if channelsForTeardown[channelIdentity] != nil {
      return true
    }
    if objectID != kIOBluetoothObjectIDNULL {
      return scheduledCloseObjectIDs.contains(objectID)
    }
    return scheduledCloseChannels.contains(channelIdentity)
  }

  fileprivate func takeChannelsForTeardown(
    including boundChannel: IOBluetoothRFCOMMChannel?
  ) -> [IOBluetoothRFCOMMChannel] {
    stateLock.lock()
    if let boundChannel {
      channelsForTeardown[ObjectIdentifier(boundChannel)] = boundChannel
    }
    let channels = Array(channelsForTeardown.values)
    channelsForTeardown.removeAll()
    stateLock.unlock()
    return channels
  }

  fileprivate func markChannelTeardownScheduled() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !channelTeardownScheduled else { return false }
    channelTeardownScheduled = true
    return true
  }
}

/// Owns a system classic-Bluetooth selection/pairing operation independently
/// of an RFCOMM session. A selected device is still only a candidate until
/// the Dart application layer finishes its authkey handshake.
private final class MacOSClassicPairingOperation: NSObject {
  let peripheralID: String
  let advertisedName: String
  let completion: FlutterResult
  var selector: IOBluetoothDeviceSelectorController?
  var attempt: MacOSClassicPairingAttempt?
  var timeout: Timer?
  var phase = "selector"
  var completed = false

  init(
    peripheralID: String,
    advertisedName: String,
    completion: @escaping FlutterResult
  ) {
    self.peripheralID = peripheralID
    self.advertisedName = advertisedName
    self.completion = completion
  }
}

/// Wraps IOBluetoothDevicePair's weak delegate API. The transport retains this
/// object throughout pairing and serializes every delegate callback on the
/// main thread, which also owns cancellation and timeout handling.
private final class MacOSClassicPairingAttempt: NSObject, IOBluetoothDevicePairDelegate {
  private let device: IOBluetoothDevice
  private let peripheralID: String
  private let advertisedName: String
  private let emitEvent: (String, [String: Any]) -> Void
  private let completion: (
    MacOSClassicPairingAttempt,
    Result<IOBluetoothDevice, PlatformBridgeError>
  ) -> Void
  private var pair: IOBluetoothDevicePair?
  private var finished = false
  private var activePrompt: NSAlert?
  private weak var activePromptHost: NSWindow?
  private var activePromptToken: UUID?

  init(
    device: IOBluetoothDevice,
    peripheralID: String,
    advertisedName: String,
    emitEvent: @escaping (String, [String: Any]) -> Void,
    completion: @escaping (
      MacOSClassicPairingAttempt,
      Result<IOBluetoothDevice, PlatformBridgeError>
    ) -> Void
  ) {
    self.device = device
    self.peripheralID = peripheralID
    self.advertisedName = advertisedName
    self.emitEvent = emitEvent
    self.completion = completion
  }

  func start() {
    runOnMain { [weak self] in
      guard let self, !self.finished else { return }
      guard let pair = IOBluetoothDevicePair(device: self.device) else {
        self.emit("pairing_start_failed", fields: [
          "reason": "pair_object_unavailable",
        ])
        self.finish(
          .failure(PlatformBridgeError(
            "pairing_controller",
            "macOS could not create a Classic Bluetooth pairing operation."
          )),
          stopPairing: false
        )
        return
      }
      self.pair = pair
      // This must happen before start(): a nearby device can immediately
      // produce a delegate callback on some macOS versions.
      pair.delegate = self
      self.emit("pairing_started")
      let status = pair.start()
      // A pairing delegate can synchronously report a terminal outcome while
      // start() is still on the stack. That terminal callback wins.
      guard !self.finished else { return }
      guard status == kIOReturnSuccess else {
        self.emit("pairing_start_failed", fields: [
          "status": Int(status),
        ])
        self.finish(
          .failure(PlatformBridgeError(
            "pairing_start",
            "macOS could not start Classic Bluetooth pairing (IOBluetooth status \(status)).",
            details: status
          )),
          stopPairing: true
        )
        return
      }
    }
  }

  /// Cancels the native request without completing its Flutter call. The
  /// transport completes that call itself so all completion paths are exactly-once.
  func cancelSilently() {
    runOnMain { [weak self] in
      self?.cancelOnMain()
    }
  }

  func devicePairingStarted(_ sender: Any!) {
    receiveCallback(sender) { attempt, _ in
      attempt.emit("pairing_started_callback")
    }
  }

  func devicePairingConnecting(_ sender: Any!) {
    receiveCallback(sender) { attempt, _ in
      attempt.emit("pairing_connecting")
    }
  }

  func devicePairingConnected(_ sender: Any!) {
    receiveCallback(sender) { attempt, _ in
      attempt.emit("pairing_connected")
    }
  }

  func devicePairingPINCodeRequest(_ sender: Any!) {
    receiveCallback(sender) { attempt, pair in
      attempt.emit("pairing_user_input_required", fields: [
        "kind": "pin",
      ])
      let alert = attempt.makePINAlert()
      let promptPresented = attempt.presentPrompt(alert, kind: "pin") { [weak attempt, weak pair] response in
        guard let attempt, let pair, attempt.isCurrent(pair) else { return }
        guard response == .alertFirstButtonReturn else {
          attempt.rejectPIN(pair, code: "pairing_user_input_cancelled", message: "Classic Bluetooth pairing was cancelled before a PIN was provided.")
          return
        }
        let pinText = (alert.accessoryView as? NSSecureTextField)?.stringValue ?? ""
        let pinBytes = Array(pinText.utf8)
        guard !pinBytes.isEmpty, pinBytes.count <= 16 else {
          attempt.emit("pairing_user_input_invalid", fields: [
            "kind": "pin",
            "length": pinBytes.count,
          ])
          attempt.rejectPIN(pair, code: "pairing_user_input_invalid", message: "Classic Bluetooth pairing requires a PIN between 1 and 16 bytes.")
          return
        }
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin) { rawBuffer in
          rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
          rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            .update(from: pinBytes, count: pinBytes.count)
        }
        pair.replyPINCode(pinBytes.count, pinCode: &pin)
        attempt.emit("pairing_user_input_submitted", fields: [
          "kind": "pin",
          "length": pinBytes.count,
        ])
      }
      guard promptPresented else {
        attempt.rejectPIN(pair, code: "pairing_user_input_unavailable", message: "Classic Bluetooth pairing requires a PIN, but Wristload could not present the input sheet.")
        return
      }
    }
  }

  func devicePairingUserConfirmationRequest(
    _ sender: Any!,
    numericValue: BluetoothNumericValue
  ) {
    receiveCallback(sender) { attempt, pair in
      // Never auto-approve a numeric comparison or write its value to the
      // diagnostic journal. The user makes the explicit decision in macOS.
      attempt.emit("pairing_user_input_required", fields: [
        "kind": "numeric_confirmation",
      ])
      let alert = attempt.makeNumericConfirmationAlert(numericValue)
      let promptPresented = attempt.presentPrompt(alert, kind: "numeric_confirmation") { [weak attempt, weak pair] response in
        guard let attempt, let pair, attempt.isCurrent(pair) else { return }
        let accepted = response == .alertFirstButtonReturn
        pair.replyUserConfirmation(accepted)
        guard accepted else {
          attempt.finish(
            .failure(PlatformBridgeError(
              "pairing_user_input_cancelled",
              "Classic Bluetooth numeric comparison was not confirmed."
            )),
            stopPairing: true
          )
          return
        }
        attempt.emit("pairing_user_input_submitted", fields: [
          "kind": "numeric_confirmation",
        ])
      }
      guard promptPresented else {
        pair.replyUserConfirmation(false)
        attempt.finish(
          .failure(PlatformBridgeError(
            "pairing_user_input_unavailable",
            "Classic Bluetooth pairing requires numeric confirmation, but Wristload could not present the confirmation sheet."
          )),
          stopPairing: true
        )
        return
      }
    }
  }

  func devicePairingUserPasskeyNotification(
    _ sender: Any!,
    passkey: BluetoothPasskey
  ) {
    receiveCallback(sender) { attempt, pair in
      // Passkey notification does not require a reply. Show it to the user
      // and keep the pairing operation alive while it is entered on the band.
      attempt.emit("pairing_user_input_required", fields: [
        "kind": "passkey",
      ])
      let alert = attempt.makePasskeyAlert(passkey)
      let promptPresented = attempt.presentPrompt(alert, kind: "passkey") { [weak attempt, weak pair] _ in
        guard let attempt, let pair, attempt.isCurrent(pair) else { return }
        attempt.emit("pairing_user_input_acknowledged", fields: [
          "kind": "passkey",
        ])
      }
      guard promptPresented else {
        attempt.finish(
          .failure(PlatformBridgeError(
            "pairing_user_input_unavailable",
            "Classic Bluetooth pairing requires a passkey, but Wristload could not present the passkey sheet."
          )),
          stopPairing: true
        )
        return
      }
    }
  }

  func deviceSimplePairingComplete(
    _ sender: Any!,
    status: BluetoothHCIEventStatus
  ) {
    receiveCallback(sender) { attempt, _ in
      // This is not terminal: Apple may perform another low-level pairing.
      attempt.emit("pairing_simple_complete", fields: [
        "status": Int(status),
      ])
    }
  }

  func devicePairingFinished(_ sender: Any!, error: IOReturn) {
    receiveCallback(sender) { attempt, _ in
      let paired = attempt.device.isPaired()
      attempt.emit("pairing_finished", fields: [
        "status": Int(error),
        "paired": paired,
      ])
      guard error == kIOReturnSuccess, paired else {
        attempt.finish(
          .failure(PlatformBridgeError(
            "pairing_failed",
            "Classic Bluetooth pairing did not complete (IOBluetooth status \(error)).",
            details: ["status": Int(error), "paired": paired]
          )),
          stopPairing: true
        )
        return
      }
      attempt.finish(.success(attempt.device), stopPairing: false)
    }
  }

  private func receiveCallback(
    _ sender: Any!,
    _ body: @escaping (MacOSClassicPairingAttempt, IOBluetoothDevicePair) -> Void
  ) {
    guard let callbackPair = sender as? IOBluetoothDevicePair else { return }
    runOnMain { [weak self] in
      guard let self, self.isCurrent(callbackPair) else { return }
      body(self, callbackPair)
    }
  }

  private func isCurrent(_ candidate: IOBluetoothDevicePair) -> Bool {
    !finished && pair === candidate
  }

  private func cancelOnMain() {
    guard !finished else { return }
    finished = true
    let pair = pair
    self.pair = nil
    dismissActivePromptOnMain()
    pair?.delegate = nil
    pair?.stop()
  }

  private func makePINAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "需要蓝牙 PIN 码"
    alert.informativeText = "请输入设备要求的 PIN 码。PIN 不会写入诊断日志或保存到磁盘。"
    alert.addButton(withTitle: "配对")
    alert.addButton(withTitle: "取消")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.placeholderString = "PIN"
    alert.accessoryView = field
    return alert
  }

  private func makeNumericConfirmationAlert(
    _ numericValue: BluetoothNumericValue
  ) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "确认蓝牙配对"
    alert.informativeText = "请确认手环上显示的配对数字与下方一致：\n\n\(String(format: "%06u", numericValue))"
    alert.addButton(withTitle: "一致")
    alert.addButton(withTitle: "不一致")
    return alert
  }

  private func makePasskeyAlert(_ passkey: BluetoothPasskey) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "在设备上输入配对码"
    alert.informativeText = "请在手环上输入以下配对码：\n\n\(String(format: "%06u", passkey))"
    alert.addButton(withTitle: "已输入")
    return alert
  }

  private func presentPrompt(
    _ alert: NSAlert,
    kind: String,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) -> Bool {
    guard !finished else {
      emit("pairing_user_input_unavailable", fields: [
        "kind": kind,
        "reason": "pairing_finished",
      ])
      return false
    }
    guard activePrompt == nil else {
      emit("pairing_user_input_unavailable", fields: [
        "kind": kind,
        "reason": "another_prompt_active",
      ])
      return false
    }
    guard let host = promptHostWindow(), host.isVisible else {
      emit("pairing_user_input_unavailable", fields: [
        "kind": kind,
        "reason": "host_window_unavailable",
      ])
      return false
    }
    guard host.attachedSheet == nil else {
      emit("pairing_user_input_unavailable", fields: [
        "kind": kind,
        "reason": "host_sheet_active",
      ])
      return false
    }
    let token = UUID()
    activePrompt = alert
    activePromptHost = host
    activePromptToken = token
    alert.beginSheetModal(for: host) { [weak self] response in
      guard let self else { return }
      self.runOnMain { [weak self] in
        guard let self, self.activePromptToken == token else { return }
        self.activePrompt = nil
        self.activePromptHost = nil
        self.activePromptToken = nil
        guard !self.finished else { return }
        self.emit("pairing_user_input_dismissed", fields: [
          "kind": kind,
          "response": Int(response.rawValue),
        ])
        completion(response)
      }
    }
    guard host.attachedSheet === alert.window else {
      if activePromptToken == token {
        activePrompt = nil
        activePromptHost = nil
        activePromptToken = nil
      }
      alert.window.orderOut(nil)
      emit("pairing_user_input_unavailable", fields: [
        "kind": kind,
        "reason": "sheet_not_attached",
      ])
      return false
    }
    emit("pairing_user_input_presented", fields: [
      "kind": kind,
    ])
    return true
  }

  private func promptHostWindow() -> NSWindow? {
    if let mainWindow = NSApp.mainWindow,
       mainWindow.isVisible,
       mainWindow.attachedSheet == nil {
      return mainWindow
    }
    return NSApp.windows.first { window in
      window.isVisible && window !== NSApp.modalWindow && window.attachedSheet == nil
    }
  }

  private func dismissActivePromptOnMain() {
    guard let alert = activePrompt else { return }
    let host = activePromptHost
    activePrompt = nil
    activePromptHost = nil
    activePromptToken = nil
    if host?.attachedSheet === alert.window {
      host?.endSheet(alert.window, returnCode: .cancel)
    } else {
      alert.window.orderOut(nil)
    }
  }

  private func rejectPIN(
    _ pair: IOBluetoothDevicePair,
    code: String,
    message: String
  ) {
    guard isCurrent(pair) else { return }
    // The delegate contract requires a PIN reply. A zero-length reply carries
    // no secret and is immediately followed by stop(), so a cancelled prompt
    // cannot silently submit user credentials.
    var emptyPIN = BluetoothPINCode()
    pair.replyPINCode(0, pinCode: &emptyPIN)
    finish(.failure(PlatformBridgeError(code, message)), stopPairing: true)
  }

  private func emit(_ name: String, fields: [String: Any] = [:]) {
    var event = fields
    event["peripheral"] = peripheralID
    event["advertisedName"] = advertisedName
    event["address"] = device.addressString ?? ""
    emitEvent(name, event)
  }

  private func finish(
    _ result: Result<IOBluetoothDevice, PlatformBridgeError>,
    stopPairing: Bool
  ) {
    runOnMain { [weak self] in
      guard let self, !self.finished else { return }
      self.finished = true
      let pair = self.pair
      self.pair = nil
      self.dismissActivePromptOnMain()
      pair?.delegate = nil
      if stopPairing { pair?.stop() }
      self.completion(self, result)
    }
  }

  private func runOnMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }
}

private final class MacOSRFCOMMTransport: NSObject {
  var onData: ((Data) -> Void)?
  var onClosed: ((FlutterError) -> Void)?
  var onEvent: (([String: Any]) -> Void)?

  private var connectTimeout: Timer?
  private var nextGeneration: UInt64 = 0
  private var session: MacOSRFCOMMSession?
  private var retiredSessions: [UInt64: MacOSRFCOMMSession] = [:]
  private var provisionalMappings: [String: String] = [:]
  private var pairingOperation: MacOSClassicPairingOperation?
  // A selector owns a nested AppKit modal loop. Keep it gated until that loop
  // returns, so cancellation cannot race a new selector into existence.
  private var selectorModalOperation: MacOSClassicPairingOperation?
  private let teardownTimeoutInterval: TimeInterval = 5
  private let retiredCleanupInterval: TimeInterval = 30
  private let pairingTimeoutInterval: TimeInterval = 90
  private let sdpCachePollInterval: TimeInterval = 0.35

  private func scheduleCommonModeTimer(
    interval: TimeInterval,
    repeats: Bool = false,
    handler: @escaping (Timer) -> Void
  ) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats, block: handler)
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func emitEvent(
    _ name: String,
    generation: UInt64? = nil,
    fields: [String: Any] = [:]
  ) {
    var event: [String: Any] = [
      "kind": "native",
      "event": name,
      "transport": "RFCOMM/SPP",
      "platform": "macos",
    ]
    if let generation { event["generation"] = generation }
    for (key, value) in fields { event[key] = value }
    onEvent?(event)
  }

  private func phaseName(_ phase: MacOSRFCOMMSessionPhase) -> String {
    switch phase {
    case .queryingSDP: return "queryingSDP"
    case .cancellingSDP: return "cancellingSDP"
    case .opening: return "opening"
    case .connected: return "connected"
    case .closingLocal: return "closingLocal"
    }
  }

  private func currentWallClockMillis() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
  }

  private func dateMillis(_ date: Date?) -> Int64? {
    guard let date else { return nil }
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private func serviceRecords(
    _ device: IOBluetoothDevice
  ) -> [IOBluetoothSDPServiceRecord] {
    (device.services ?? []).compactMap { $0 as? IOBluetoothSDPServiceRecord }
  }

  private func didRefreshSDPCache(
    _ updateMillis: Int64?,
    for current: MacOSRFCOMMSession
  ) -> Bool {
    guard let updateMillis else { return false }
    if let baseline = current.sdpBaselineUpdateMillis {
      return updateMillis > baseline
    }
    // No pre-existing service cache is safe to consume only when the first
    // observed update is contemporaneous with this query.
    guard let started = current.sdpQueryStartedMillis else { return false }
    return updateMillis >= started - 1_000
  }

  private func installConnectTimeout(for current: MacOSRFCOMMSession) {
    connectTimeout?.invalidate()
    let generation = current.generation
    connectTimeout = scheduleCommonModeTimer(interval: 30) { [weak self, weak current] _ in
      guard let self,
            let current,
            self.session === current,
            current.generation == generation else { return }
      if current.phase == .queryingSDP {
        self.emitEvent("sdp_timeout", generation: generation, fields: [
          "queryKind": current.sdpQueryKind,
          "baselineLastServicesUpdateMillis": current.sdpBaselineUpdateMillis as Any,
          "lastServicesUpdateMillis": self.dateMillis(
            current.device.getLastServicesUpdate()
          ) as Any,
          "serviceCount": self.serviceRecords(current.device).count,
          "cacheRefreshObserved": current.sdpCacheRefreshObserved,
          "paired": current.device.isPaired(),
          "basebandConnected": current.device.isConnected(),
        ])
      }
      self.cancelPending(PlatformBridgeError(
        "rfcomm_connect_timeout",
        "The classic Bluetooth SPP connection timed out."
      ), generation: generation)
    }
  }

  private func startSDPCachePolling(for current: MacOSRFCOMMSession) {
    guard current.sdpCachePollTimer == nil else { return }
    let generation = current.generation
    current.sdpCachePollTimer = scheduleCommonModeTimer(
      interval: sdpCachePollInterval,
      repeats: true
    ) { [weak self, weak current] _ in
      guard let self, let current else { return }
      guard self.session === current,
            current.generation == generation,
            current.phase == .queryingSDP else {
        self.invalidateSDPCachePoll(for: current)
        return
      }
      let updateMillis = self.dateMillis(current.device.getLastServicesUpdate())
      guard self.didRefreshSDPCache(updateMillis, for: current) else { return }
      current.sdpCacheRefreshObserved = true
      self.invalidateSDPCachePoll(for: current)
      self.emitEvent("sdp_cache_refresh_observed", generation: generation, fields: [
        "queryKind": current.sdpQueryKind,
        "baselineLastServicesUpdateMillis": current.sdpBaselineUpdateMillis as Any,
        "lastServicesUpdateMillis": updateMillis as Any,
        "serviceCount": self.serviceRecords(current.device).count,
        "delegateCallbackObserved": false,
      ])
      self.emitEvent("sdp_completed", generation: generation, fields: [
        "status": Int(kIOReturnSuccess),
        "completionSource": "cache_poll",
      ])
      self.finishSDPQuery(
        current.device,
        status: kIOReturnSuccess,
        generation: generation,
        completionSource: "cache_poll"
      )
    }
  }

  private func invalidateSDPCachePoll(for current: MacOSRFCOMMSession) {
    current.sdpCachePollTimer?.invalidate()
    current.sdpCachePollTimer = nil
  }

  private func invalidateSDPObservation(for current: MacOSRFCOMMSession) {
    invalidateSDPCachePoll(for: current)
    if session === current {
      connectTimeout?.invalidate()
      connectTimeout = nil
    }
  }

  private func resolveSPPChannel(
    on device: IOBluetoothDevice,
    session current: MacOSRFCOMMSession,
    completionSource: String
  ) -> BluetoothRFCOMMChannelID? {
    let records = serviceRecords(device)
    var sppRecordCount = 0
    var channels = [BluetoothRFCOMMChannelID]()

    for (index, record) in records.enumerated() {
      let matchesSPP = record.matchesUUID16(0x1101)
      var channelID: BluetoothRFCOMMChannelID = 0
      let channelStatus = record.getRFCOMMChannelID(&channelID)
      emitEvent("sdp_service_record", generation: current.generation, fields: [
        "index": index,
        "serviceName": record.getServiceName() ?? "",
        "matchesSPP": matchesSPP,
        "rfcommChannelStatus": Int(channelStatus),
        "rfcommChannelId": channelStatus == kIOReturnSuccess
          ? Int(channelID) : -1,
        "queryKind": current.sdpQueryKind,
        "completionSource": completionSource,
      ])
      guard matchesSPP else { continue }
      sppRecordCount += 1
      if channelStatus == kIOReturnSuccess {
        channels.append(channelID)
      }
    }

    let uniqueChannels = Array(Set(channels)).sorted()
    guard !uniqueChannels.isEmpty else {
      let error = PlatformBridgeError(
        sppRecordCount == 0 ? "spp_service_missing" : "spp_channel_missing",
        sppRecordCount == 0
          ? "The selected device does not expose the Serial Port Profile service."
          : "The SPP service does not expose an RFCOMM channel.",
        details: [
          "serviceCount": records.count,
          "sppRecordCount": sppRecordCount,
          "queryKind": current.sdpQueryKind,
          "completionSource": completionSource,
        ]
      )
      finishPending(error, session: current)
      return nil
    }
    guard uniqueChannels.count == 1 else {
      finishPending(PlatformBridgeError(
        "spp_channel_ambiguous",
        "The device exposes multiple SPP RFCOMM channels; no channel was selected automatically.",
        details: [
          "channels": uniqueChannels.map(Int.init),
          "serviceCount": records.count,
          "sppRecordCount": sppRecordCount,
          "queryKind": current.sdpQueryKind,
          "completionSource": completionSource,
        ]
      ), session: current)
      return nil
    }
    return uniqueChannels[0]
  }

  /// Starts the macOS system pairing flow. The Flutter result remains pending
  /// until a known paired device is reused, or a selected device has completed
  /// IOBluetoothDevicePair successfully.
  func pair(
    peripheralID: String,
    advertisedName: String,
    completion: @escaping FlutterResult
  ) {
    runOnMain { [weak self] in
      self?.startPairing(
        peripheralID: peripheralID,
        advertisedName: advertisedName,
        completion: completion
      )
    }
  }

  private func startPairing(
    peripheralID: String,
    advertisedName: String,
    completion: @escaping FlutterResult
  ) {
    guard selectorModalOperation == nil else {
      emitEvent("pairing_rejected", fields: [
        "peripheral": peripheralID,
        "advertisedName": advertisedName,
        "reason": "selector_dismissing",
      ])
      completion(FlutterError(
        code: "pairing_closing",
        message: "The previous Classic Bluetooth device selector is still closing. Try again in a moment.",
        details: nil
      ))
      return
    }
    guard pairingOperation == nil else {
      completion(FlutterError(
        code: "pairing_in_progress",
        message: "Classic Bluetooth pairing is already in progress.",
        details: nil
      ))
      return
    }
    guard session == nil else {
      completion(FlutterError(
        code: "rfcomm_active",
        message: "Disconnect the current RFCOMM session before pairing another device.",
        details: nil
      ))
      return
    }

    // An explicit retry must not reuse a candidate that has not yet passed
    // application-layer identity verification. Confirmed mappings stay valid.
    provisionalMappings.removeValue(forKey: mappingKey(peripheralID))
    let operation = MacOSClassicPairingOperation(
      peripheralID: peripheralID,
      advertisedName: advertisedName,
      completion: completion
    )
    pairingOperation = operation
    schedulePairingTimeout(for: operation)

    do {
      switch try resolveClassicDevice(
        peripheralID: peripheralID,
        advertisedName: advertisedName
      ) {
      case .resolved(let selected):
        completePairingOperation(operation, with: .success(selected))
      case .needsSelection(let matchingCandidates):
        presentClassicDeviceSelector(
          for: operation,
          matchingCandidates: matchingCandidates
        )
      }
    } catch let error as PlatformBridgeError {
      completePairingOperation(operation, with: .failure(error))
    } catch {
      completePairingOperation(operation, with: .failure(PlatformBridgeError(
        "pairing",
        error.localizedDescription
      )))
    }
  }

  private func schedulePairingTimeout(
    for operation: MacOSClassicPairingOperation
  ) {
    // IOBluetoothDeviceSelectorController.runModal() switches the main run
    // loop into a modal mode, so the deadline must be in the common mode.
    operation.timeout = scheduleCommonModeTimer(interval: pairingTimeoutInterval) {
      [weak self, weak operation] _ in
      guard let self,
            let operation,
            self.pairingOperation === operation,
            !operation.completed else { return }
      self.cancelPairingOperation(
        operation,
        error: PlatformBridgeError(
          "pairing_timeout",
          "Classic Bluetooth pairing timed out after \(Int(self.pairingTimeoutInterval)) seconds."
        ),
        event: "pairing_timeout"
      )
    }
  }

  /// Presents macOS's public classic-device selector. No SPP UUID filter is
  /// applied here: a band may not expose its SPP SDP record until pairing, and
  /// the existing RFCOMM SDP phase remains the authoritative validation.
  private func presentClassicDeviceSelector(
    for operation: MacOSClassicPairingOperation,
    matchingCandidates: Int
  ) {
    guard pairingOperation === operation, !operation.completed else { return }
    guard let selector = IOBluetoothDeviceSelectorController.deviceSelector()
    else {
      completePairingOperation(operation, with: .failure(PlatformBridgeError(
        "device_selector",
        "macOS could not create the Classic Bluetooth device selector."
      )))
      return
    }

    operation.selector = selector
    operation.phase = "selector"
    selector.setOptions(
      IOBluetoothServiceBrowserControllerOptions(
        kIOBluetoothServiceBrowserControllerOptionsAutoStartInquiry
      )
    )
    selector.setTitle("Select Classic Bluetooth Device")
    selector.setDescriptionText(
      "Select the Classic Bluetooth device matching \"\(operation.advertisedName)\". The SPP service is verified after pairing."
    )
    selector.setPrompt("Select")
    emitEvent("selector_opening", fields: [
      "peripheral": operation.peripheralID,
      "advertisedName": operation.advertisedName,
      "matchingCandidates": matchingCandidates,
      "sppValidation": "deferred_to_sdp",
    ])

    // runModal owns a nested AppKit event loop. A Flutter disconnect request
    // can therefore cancel this operation while the panel is visible.
    selectorModalOperation = operation
    defer {
      if self.selectorModalOperation === operation {
        self.selectorModalOperation = nil
      }
    }
    let status = selector.runModal()
    let results = selector.getResults()
    let resultCount = results?.count ?? 0
    guard pairingOperation === operation, !operation.completed else { return }
    operation.selector = nil
    emitEvent("selector_finished", fields: [
      "peripheral": operation.peripheralID,
      "advertisedName": operation.advertisedName,
      "status": Int(status),
      "resultsCount": resultCount,
      "success": status == kIOBluetoothUISuccess,
    ])
    guard status == kIOBluetoothUISuccess else {
      let wasCancelled = status == kIOBluetoothUIUserCanceledErr
      completePairingOperation(operation, with: .failure(PlatformBridgeError(
        wasCancelled ? "pairing_cancelled" : "device_selector",
        wasCancelled
          ? "Classic Bluetooth device selection was cancelled."
          : "Classic Bluetooth device selection did not complete (macOS status \(status)).",
        details: ["status": Int(status), "resultsCount": resultCount]
      )))
      return
    }
    guard let selected = results?.first as? IOBluetoothDevice else {
      completePairingOperation(operation, with: .failure(PlatformBridgeError(
        "pairing_no_result",
        "macOS reported a successful device selection without a selected Classic Bluetooth device.",
        details: ["status": Int(status), "resultsCount": resultCount]
      )))
      return
    }
    let selectedName = selected.name ?? selected.nameOrAddress ?? ""
    guard classicNameMatchesAdvertisement(
      advertisedName: operation.advertisedName,
      classicName: selectedName
    ) else {
      completePairingOperation(operation, with: .failure(PlatformBridgeError(
        "paired_device_mismatch",
        "The selected Classic Bluetooth device does not match the scanned BLE device name."
      )))
      return
    }
    if selected.isPaired() {
      completePairingOperation(operation, with: .success(selected))
      return
    }
    startSystemPairing(selected, for: operation)
  }

  private func startSystemPairing(
    _ device: IOBluetoothDevice,
    for operation: MacOSClassicPairingOperation
  ) {
    guard pairingOperation === operation, !operation.completed else { return }
    operation.phase = "pairing"
    let attempt = MacOSClassicPairingAttempt(
      device: device,
      peripheralID: operation.peripheralID,
      advertisedName: operation.advertisedName,
      emitEvent: { [weak self] name, fields in
        self?.emitEvent(name, fields: fields)
      },
      completion: { [weak self, weak operation] completedAttempt, result in
        guard let self,
              let operation,
              self.pairingOperation === operation,
              operation.attempt === completedAttempt,
              !operation.completed else { return }
        operation.attempt = nil
        self.completePairingOperation(operation, with: result)
      }
    )
    // IOBluetoothDevicePair.delegate is weak. Retain the attempt before start
    // so an immediately-delivered delegate callback cannot be lost.
    operation.attempt = attempt
    attempt.start()
  }

  private func completePairingOperation(
    _ operation: MacOSClassicPairingOperation,
    with result: Result<IOBluetoothDevice, PlatformBridgeError>
  ) {
    guard pairingOperation === operation, !operation.completed else { return }
    operation.completed = true
    operation.timeout?.invalidate()
    operation.timeout = nil
    operation.selector = nil
    operation.attempt = nil
    pairingOperation = nil

    switch result {
    case .success(let selected):
      let selectedName = selected.name ?? selected.nameOrAddress ?? ""
      guard selected.isPaired(),
            classicNameMatchesAdvertisement(
              advertisedName: operation.advertisedName,
              classicName: selectedName
            ) else {
        let error = PlatformBridgeError(
          "paired_device_mismatch",
          "The selected Classic Bluetooth device is not a confirmed match for the scanned BLE device."
        )
        emitPairingFailure(error, operation: operation)
        operation.completion(error.flutterError)
        return
      }
      provision(selected, peripheralID: operation.peripheralID)
      emitEvent("pair_completed", fields: [
        "peripheral": operation.peripheralID,
        "address": selected.addressString ?? "",
        "name": selectedName,
        "paired": true,
        "phase": operation.phase,
      ])
      operation.completion(deviceDescription(selected))
    case .failure(let error):
      emitPairingFailure(error, operation: operation)
      operation.completion(error.flutterError)
    }
  }

  private func cancelPairingOperation(
    _ operation: MacOSClassicPairingOperation,
    error: PlatformBridgeError,
    event: String = "pairing_cancelled"
  ) {
    guard pairingOperation === operation, !operation.completed else { return }
    emitEvent(event, fields: [
      "peripheral": operation.peripheralID,
      "advertisedName": operation.advertisedName,
      "phase": operation.phase,
      "code": error.code,
    ])
    operation.attempt?.cancelSilently()
    operation.attempt = nil
    let selector = operation.selector
    // Complete first: abortModal() can synchronously unwind runModal(), and
    // the old selector must never win that race with a successful result.
    completePairingOperation(operation, with: .failure(error))
    closeClassicDeviceSelector(selector, for: operation)
  }

  private func closeClassicDeviceSelector(
    _ selector: IOBluetoothDeviceSelectorController?,
    for operation: MacOSClassicPairingOperation
  ) {
    guard let selector else { return }
    // Only abort a nested modal loop that this transport owns. Comparing the
    // window objects is not reliable on all macOS releases.
    if selectorModalOperation === operation {
      NSApp.abortModal()
    }
    selector.close()
  }

  private func emitPairingFailure(
    _ error: PlatformBridgeError,
    operation: MacOSClassicPairingOperation
  ) {
    emitEvent("pairing_failed", fields: [
      "peripheral": operation.peripheralID,
      "advertisedName": operation.advertisedName,
      "phase": operation.phase,
      "code": error.code,
      "message": error.message,
    ])
  }

  func confirmIdentity(peripheralID: String, advertisedName: String) throws {
    let mapping = mappingKey(peripheralID)
    guard let address = provisionalMappings[mapping],
          let selected = IOBluetoothDevice(addressString: address),
          selected.isPaired(),
          classicNameMatchesAdvertisement(
            advertisedName: advertisedName,
            classicName: selected.name ?? selected.nameOrAddress ?? ""
          ) else {
      throw PlatformBridgeError(
        "device_identity_unconfirmed",
        "The authenticated classic Bluetooth identity is no longer available."
      )
    }
    UserDefaults.standard.set(address, forKey: mapping)
    provisionalMappings.removeValue(forKey: mapping)
    emitEvent("identity_confirmed", fields: ["address": address, "name": advertisedName])
  }

  /// Clears only Wristload's local CoreBluetooth-to-classic-device association.
  /// This deliberately does not close an active RFCOMM channel and does not
  /// alter the macOS system pairing record.
  func forgetIdentity(peripheralID: String) {
    let mapping = mappingKey(peripheralID)
    let hadPersistedMapping = UserDefaults.standard.object(forKey: mapping) != nil
    let hadProvisionalMapping = provisionalMappings.removeValue(forKey: mapping) != nil
    UserDefaults.standard.removeObject(forKey: mapping)
    emitEvent("identity_forgotten", fields: [
      "peripheral": peripheralID,
      "hadPersistedMapping": hadPersistedMapping,
      "hadProvisionalMapping": hadProvisionalMapping,
    ])
  }

  func connect(
    peripheralID: String,
    advertisedName: String,
    completion: @escaping FlutterResult
  ) throws {
    if let current = session {
      if current.phase != .connected {
        throw PlatformBridgeError(
          current.phase == .queryingSDP || current.phase == .opening
            ? "rfcomm_connect_pending"
            : "rfcomm_closing",
          current.phase == .queryingSDP || current.phase == .opening
            ? "An RFCOMM connection is already in progress."
            : "The previous RFCOMM connection is still closing."
        )
      }
      guard let channel = current.channel, channel.isOpen() else {
        throw PlatformBridgeError(
          "rfcomm_closing",
          "The previous RFCOMM connection is still closing."
        )
      }
      let requested = try resolveDevice(
        peripheralID: peripheralID,
        advertisedName: advertisedName
      )
      guard let active = channel.getDevice(),
            let requestedAddress = requested.addressString,
            let activeAddress = active.addressString,
            requestedAddress.caseInsensitiveCompare(activeAddress) == .orderedSame else {
        throw PlatformBridgeError(
          "rfcomm_connected_other_device",
          "RFCOMM is already connected to a different classic Bluetooth device."
        )
      }
      completion(deviceDescription(active))
      return
    }

    guard pairingOperation == nil else {
      throw PlatformBridgeError(
        "pairing_pending",
        "Classic Bluetooth pairing is still in progress."
      )
    }
    let selected = try resolveDevice(
      peripheralID: peripheralID,
      advertisedName: advertisedName
    )
    nextGeneration &+= 1
    if nextGeneration == 0 { nextGeneration = 1 }
    let generation = nextGeneration
    let sessionDelegate = MacOSRFCOMMSessionDelegate(
      owner: self,
      generation: generation
    )
    let newSession = MacOSRFCOMMSession(
      generation: generation,
      delegate: sessionDelegate,
      device: selected,
      peripheralID: peripheralID,
      advertisedName: advertisedName,
      completion: completion
    )
    session = newSession
    provision(selected, peripheralID: peripheralID)
    let baselineUpdate = selected.getLastServicesUpdate()
    newSession.sdpBaselineUpdateMillis = dateMillis(baselineUpdate)
    newSession.sdpQueryStartedMillis = currentWallClockMillis()
    emitEvent("sdp_started", generation: generation, fields: [
      "address": selected.addressString ?? "",
      "name": advertisedName,
      "queryKind": newSession.sdpQueryKind,
      "baselineLastServicesUpdateMillis": newSession.sdpBaselineUpdateMillis as Any,
      "queryStartedMillis": newSession.sdpQueryStartedMillis as Any,
      "cachedServiceCount": serviceRecords(selected).count,
      "paired": selected.isPaired(),
      "basebandConnected": selected.isConnected(),
      "onMainThread": Thread.isMainThread,
      "callbackSelectorAvailable": sessionDelegate.responds(
        to: #selector(MacOSRFCOMMSessionDelegate.sdpQueryComplete(_:status:))
      ),
    ])
    // Install both observers before invoking the asynchronous API. On a cache
    // hit, IOBluetooth can deliver completion before this method returns.
    installConnectTimeout(for: newSession)
    startSDPCachePolling(for: newSession)
    // A complete SDP query is deliberately used here rather than asking only
    // for UUID 0x1101. Some paired band firmware does not answer a filtered
    // service search but does answer the public all-services query. We still
    // accept only a uniquely identified 0x1101 service below.
    let status = selected.performSDPQuery(sessionDelegate)
    guard status == kIOReturnSuccess else {
      invalidateSDPObservation(for: newSession)
      emitEvent("error", generation: generation, fields: [
        "code": "sdp_query_start",
        "status": Int(status),
        "queryKind": newSession.sdpQueryKind,
      ])
      session = nil
      newSession.delegate.owner = nil
      throw ioError(
        code: "sdp_query",
        message: "Unable to start the SPP service query.",
        status: status
      )
    }
  }

  fileprivate func sdpQueryComplete(
    _ queriedDevice: IOBluetoothDevice,
    status: IOReturn,
    generation: UInt64
  ) {
    emitEvent("sdp_callback_entered", generation: generation, fields: [
      "status": Int(status),
      "address": queriedDevice.addressString ?? "",
      "paired": queriedDevice.isPaired(),
      "basebandConnected": queriedDevice.isConnected(),
      "lastServicesUpdateMillis": dateMillis(queriedDevice.getLastServicesUpdate()) as Any,
      "serviceCount": serviceRecords(queriedDevice).count,
      "onMainThread": Thread.isMainThread,
    ])
    runOnMain { [weak self] in
      self?.emitEvent("sdp_completed", generation: generation, fields: [
        "status": Int(status),
        "completionSource": "delegate",
      ])
      self?.finishSDPQuery(
        queriedDevice,
        status: status,
        generation: generation,
        completionSource: "delegate"
      )
    }
  }

  private func finishSDPQuery(
    _ queriedDevice: IOBluetoothDevice,
    status: IOReturn,
    generation: UInt64,
    completionSource: String
  ) {
    guard let current = session, current.generation == generation else {
      if let retired = retiredSessions[generation] {
        // An SDP callback is terminal only while the query is still the
        // pending phase. Once opening has begun, keep the retired session so
        // a late open/close callback can still be matched and closed.
        switch retired.phase {
        case .queryingSDP, .cancellingSDP:
          finishRetiredSession(retired)
        case .opening, .connected, .closingLocal:
          break
        }
      }
      return
    }
    guard isSameDevice(queriedDevice, current.device) else {
      finishPending(
        PlatformBridgeError(
          "sdp_device_mismatch",
          "The SPP service query completed for an unexpected device."
        ),
        session: current
      )
      return
    }
    if current.phase == .cancellingSDP {
      finishSession(current)
      return
    }
    guard current.phase == .queryingSDP else { return }
    invalidateSDPCachePoll(for: current)
    guard status == kIOReturnSuccess else {
      emitEvent("error", generation: generation, fields: [
        "code": "sdp_query",
        "status": Int(status),
      ])
      finishPending(
        ioError(
        code: "sdp_query",
        message: "The device rejected the SPP service query.",
        status: status
        ),
        session: current
      )
      return
    }
    guard let channelID = resolveSPPChannel(
      on: queriedDevice,
      session: current,
      completionSource: completionSource
    ) else { return }
    openRFCOMMChannel(
      on: queriedDevice,
      channelID: channelID,
      session: current,
      completionSource: completionSource
    )
  }

  private func openRFCOMMChannel(
    on queriedDevice: IOBluetoothDevice,
    channelID: BluetoothRFCOMMChannelID,
    session current: MacOSRFCOMMSession,
    completionSource: String
  ) {
    let generation = current.generation
    emitEvent("channel_resolved", generation: generation, fields: [
      "channelId": Int(channelID),
      "selectionSource": completionSource,
    ])
    current.phase = .opening
    emitEvent("opening", generation: generation, fields: [
      "channelId": Int(channelID),
      "selectionSource": completionSource,
    ])
    var opened: IOBluetoothRFCOMMChannel?
    let openStatus = queriedDevice.openRFCOMMChannelAsync(
      &opened,
      withChannelID: channelID,
      delegate: current.delegate
    )
    guard openStatus == kIOReturnSuccess else {
      emitEvent("error", generation: generation, fields: [
        "code": "rfcomm_open_start",
        "status": Int(openStatus),
      ])
      finishPending(
        ioError(
          code: "rfcomm_open",
          message: "Unable to start the RFCOMM connection.",
          status: openStatus
        ),
        session: current
      )
      return
    }
    if let opened, !bind(opened, to: current) {
      finishInvalidOpen(
        opened,
        error: PlatformBridgeError(
          "rfcomm_close_notification",
          "Unable to monitor the RFCOMM channel lifecycle."
        ),
        session: current
      )
    }
  }

  fileprivate func rfcommChannelOpenComplete(
    _ openedChannel: IOBluetoothRFCOMMChannel,
    status: IOReturn,
    generation: UInt64
  ) {
    runOnMain { [weak self] in
      guard let self else { return }
      guard let current = self.session,
            current.generation == generation else {
        if let retired = self.retiredSessions[generation] {
          self.finishRetiredOpen(
            openedChannel,
            status: status,
            session: retired
          )
        }
        return
      }
      if current.channel == nil {
        guard self.isSameDevice(openedChannel.getDevice(), current.device),
              self.bind(openedChannel, to: current) else {
          self.finishInvalidOpen(
            openedChannel,
            error: PlatformBridgeError(
              "rfcomm_channel_mismatch",
              "RFCOMM opened an unexpected channel."
            ),
            session: current
          )
          return
        }
      }
      guard self.matches(openedChannel, session: current) else {
        if current.phase == .opening {
          self.finishInvalidOpen(
            openedChannel,
            error: PlatformBridgeError(
              "rfcomm_channel_mismatch",
              "RFCOMM opened an unexpected channel."
            ),
            session: current
          )
        }
        return
      }
      switch current.phase {
      case .opening:
        if status == kIOReturnSuccess {
          self.emitEvent("opened", generation: generation, fields: [
            "status": Int(status),
            "mtu": Int(openedChannel.getMTU()),
            "channelObjectId": String(openedChannel.getObjectID()),
          ])
        } else {
          self.emitEvent("error", generation: generation, fields: [
            "code": "rfcomm_open",
            "status": Int(status),
          ])
        }
        guard status == kIOReturnSuccess else {
          self.finishPending(
            self.ioError(
              code: "rfcomm_open",
              message: "The RFCOMM connection failed to open.",
              status: status
            ),
            session: current
          )
          return
        }
        self.connectTimeout?.invalidate()
        self.connectTimeout = nil
        current.phase = .connected
        let completion = current.completion
        current.completion = nil
        completion?(self.deviceDescription(openedChannel.getDevice()))
      case .closingLocal:
        guard status == kIOReturnSuccess else {
          self.finishSession(current)
          return
        }
        current.cancelWritesAndRequestClose()
        if let channel = current.channel {
          self.enqueueChannelClose(channel, for: current)
        }
        self.scheduleTeardownWatchdog(for: current)
      case .connected:
        // Ignore a duplicate completion for the current, established channel.
        return
      case .queryingSDP, .cancellingSDP:
        return
      }
    }
  }

  func write(_ data: Data, completion: @escaping FlutterResult) throws {
    guard !data.isEmpty else {
      completion(nil)
      return
    }
    guard let current = session,
          current.phase == .connected,
          let channel = current.channel,
          channel.isOpen() else {
      throw PlatformBridgeError(
        "rfcomm_not_connected",
        "RFCOMM is not connected."
      )
    }
    let mtu = min(Int(channel.getMTU()), Int(UInt16.max))
    guard mtu > 0 else {
      throw PlatformBridgeError(
        "rfcomm_mtu",
        "The RFCOMM channel reported an invalid MTU."
      )
    }
    let session = current
    let generation = session.generation
    let channelObjectID = session.channelObjectID
    emitEvent("write_started", generation: generation, fields: [
      "direction": "TX",
      "bytes": data.count,
      "mtu": mtu,
      "channelObjectId": channelObjectID.map(String.init) ?? "",
    ])
    session.ioQueue.async { [weak self, session] in
      var failure: FlutterError?
      var cancelled = false
      var offset = 0
      var chunkIndex = 0
      while offset < data.count {
        guard !session.isWriteCancelled() else {
          cancelled = true
          break
        }
        let count = min(mtu, data.count - offset)
        let status: IOReturn = data.withUnsafeBytes { bytes in
          guard let baseAddress = bytes.baseAddress else {
            return kIOReturnSuccess
          }
          let pointer = UnsafeMutableRawPointer(
            mutating: baseAddress.advanced(by: offset)
          )
          return channel.writeSync(pointer, length: UInt16(count))
        }
        guard status == kIOReturnSuccess else {
          self?.emitEvent("error", generation: generation, fields: [
            "code": "rfcomm_write",
            "status": Int(status),
            "offset": offset,
            "bytes": count,
          ])
          failure = FlutterError(
            code: "rfcomm_write",
            message: "The RFCOMM write failed (IOBluetooth status \(status)).",
            details: status
          )
          break
        }
        let chunk = data.subdata(in: offset..<(offset + count))
        self?.emitEvent("write_chunk", generation: generation, fields: [
          "direction": "TX",
          "offset": offset,
          "chunkIndex": chunkIndex,
          "bytes": count,
          "mtu": mtu,
          "status": Int(status),
          "wireHex": wireHex(chunk),
        ])
        offset += count
        chunkIndex += 1
      }
      self?.emitEvent("write_completed", generation: generation, fields: [
        "direction": "TX",
        "bytes": data.count,
        "mtu": mtu,
        "completed": !cancelled && failure == nil,
      ])
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          completion(FlutterError(
            code: "rfcomm_write_cancelled",
            message: "The RFCOMM transport was released while writing.",
            details: nil
          ))
          return
        }
        if let failure {
          completion(failure)
          return
        }
        if cancelled || session.isWriteCancelled() {
          completion(FlutterError(
            code: "rfcomm_write_cancelled",
            message: "The RFCOMM connection was closed while writing.",
            details: nil
          ))
          return
        }
        guard let active = self.session,
              active.generation == generation,
              active.phase == .connected,
              active.channelObjectID == channelObjectID else {
          completion(FlutterError(
            code: "rfcomm_write_cancelled",
            message: "The RFCOMM connection changed while writing.",
            details: nil
          ))
          return
        }
        completion(nil)
      }
    }
  }

  func disconnect(completion: FlutterResult? = nil) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.disconnect(completion: completion)
      }
      return
    }
    connectTimeout?.invalidate()
    connectTimeout = nil
    let cancelledPairing = pairingOperation != nil
    if let operation = pairingOperation {
      cancelPairingOperation(
        operation,
        error: PlatformBridgeError(
          "pairing_cancelled",
          "Classic Bluetooth pairing was cancelled."
        )
      )
    }
    guard let current = session else {
      emitEvent("disconnect_completed", fields: [
        "hadSession": false,
        "hadPairing": cancelledPairing,
      ])
      completion?(nil)
      return
    }
    if let completion {
      current.disconnectCompletions.append(completion)
    }
    if let completion = current.completion {
      current.completion = nil
      completion(FlutterError(
        code: "rfcomm_cancelled",
        message: "RFCOMM connection cancelled.",
        details: nil
      ))
    }
    switch current.phase {
    case .queryingSDP:
      // IOBluetooth exposes no SDP cancellation API. The watchdog releases
      // Dart and moves the delegate to retiredSessions if no callback arrives.
      current.phase = .cancellingSDP
      scheduleTeardownWatchdog(for: current)
    case .opening, .connected:
      current.phase = .closingLocal
      current.cancelWritesAndRequestClose()
      guard let channel = current.channel else {
        scheduleTeardownWatchdog(for: current)
        return
      }
      enqueueChannelClose(channel, for: current)
      scheduleTeardownWatchdog(for: current)
    case .cancellingSDP, .closingLocal:
      return
    }
  }

  fileprivate func rfcommChannelData(
    _ source: IOBluetoothRFCOMMChannel,
    data: Data,
    generation: UInt64
  ) {
    runOnMain { [weak self] in
      guard let self,
            let current = self.session,
            current.generation == generation,
            current.phase == .connected,
            self.matches(source, session: current) else { return }
      self.onData?(data)
    }
  }

  fileprivate func rfcommChannelClosed(
    _ closedChannel: IOBluetoothRFCOMMChannel,
    generation: UInt64
  ) {
    runOnMain { [weak self] in
      guard let self else { return }
      guard let current = self.session,
            current.generation == generation,
            self.matches(closedChannel, session: current) else {
        if let retired = self.retiredSessions[generation],
           self.matches(closedChannel, session: retired) {
          self.finishRetiredSession(retired)
        }
        return
      }
      let previousPhase = current.phase
      self.emitEvent("closed", generation: generation, fields: [
        "phase": self.phaseName(previousPhase),
        "address": current.device.addressString ?? "",
      ])
      if previousPhase == .opening, let completion = current.completion {
        current.completion = nil
        completion(PlatformBridgeError(
          "rfcomm_closed",
          "The RFCOMM channel closed before the connection completed."
        ).flutterError)
      }
      self.finishSession(current)
      if previousPhase == .connected {
        self.onClosed?(FlutterError(
          code: "rfcomm_closed",
          message: "The remote device closed the RFCOMM connection.",
          details: nil
        ))
      }
    }
  }

  private enum ClassicDeviceResolution {
    case resolved(IOBluetoothDevice)
    case needsSelection(matchingCandidates: Int)
  }

  /// Resolves only devices that are already known to macOS. A missing or
  /// ambiguous identity is deliberately left to the system selector rather
  /// than guessed from a BLE name.
  private func resolveClassicDevice(
    peripheralID: String,
    advertisedName: String
  ) throws -> ClassicDeviceResolution {
    let wantedName = canonicalName(advertisedName)
    guard !wantedName.isEmpty else {
      throw PlatformBridgeError(
        "device_identity",
        "The scanned Bluetooth device has no usable advertised name."
      )
    }
    let mapping = mappingKey(peripheralID)
    if let address = UserDefaults.standard.string(
      forKey: mapping
    ), let stored = IOBluetoothDevice(addressString: address),
       stored.isPaired() {
      let storedName = stored.name ?? stored.nameOrAddress ?? ""
      if classicNameMatchesAdvertisement(
        advertisedName: advertisedName,
        classicName: storedName
      ) {
        emitEvent("classic_identity_mapping_resolved", fields: [
          "peripheral": peripheralID,
          "source": "confirmed_mapping",
          "address": address,
          "matchMode": classicNameMatchMode(
            advertisedName: advertisedName,
            classicName: storedName
          ) ?? "unknown",
        ])
        return .resolved(stored)
      }
      UserDefaults.standard.removeObject(forKey: mapping)
    }
    if let address = provisionalMappings[mapping],
       let provisional = IOBluetoothDevice(addressString: address),
       provisional.isPaired() {
      let provisionalName =
        provisional.name ?? provisional.nameOrAddress ?? ""
      if classicNameMatchesAdvertisement(
        advertisedName: advertisedName,
        classicName: provisionalName
      ) {
        emitEvent("classic_identity_mapping_resolved", fields: [
          "peripheral": peripheralID,
          "source": "provisional_mapping",
          "address": address,
          "matchMode": classicNameMatchMode(
            advertisedName: advertisedName,
            classicName: provisionalName
          ) ?? "unknown",
        ])
        return .resolved(provisional)
      }
      provisionalMappings.removeValue(forKey: mapping)
    }

    let pairedCandidates = (IOBluetoothDevice.pairedDevices() ?? [])
      .compactMap { $0 as? IOBluetoothDevice }
    let matches = pairedCandidates.filter { candidate in
        let candidateName = candidate.name ?? candidate.nameOrAddress ?? ""
        return classicNameMatchesAdvertisement(
          advertisedName: advertisedName,
          classicName: candidateName
        )
      }
    emitEvent("classic_candidates_resolved", fields: [
      "peripheral": peripheralID,
      "advertisedName": advertisedName,
      "pairedCandidates": pairedCandidates.count,
      "matchingCandidates": matches.count,
      "matchModes": matches.map { candidate in
        classicNameMatchMode(
          advertisedName: advertisedName,
          classicName: candidate.name ?? candidate.nameOrAddress ?? ""
        )
      },
    ])
    if matches.count == 1 {
      // A single exact (or the documented one-way BLE instance-suffix) match
      // is sufficient to reuse the system pairing. Do not present a second
      // selector after macOS has already paired that unique device.
      let selected = matches[0]
      emitEvent("classic_pairing_reused", fields: [
        "peripheral": peripheralID,
        "address": selected.addressString ?? "",
        "name": selected.name ?? selected.nameOrAddress ?? "",
        "matchMode": classicNameMatchMode(
          advertisedName: advertisedName,
          classicName: selected.name ?? selected.nameOrAddress ?? ""
        ) ?? "unknown",
      ])
      return .resolved(selected)
    }
    if matches.count > 1 {
      emitEvent("classic_pairing_ambiguous", fields: [
        "peripheral": peripheralID,
        "advertisedName": advertisedName,
        "matchingCandidates": matches.count,
      ])
    }
    return .needsSelection(matchingCandidates: matches.count)
  }

  /// RFCOMM can use only a known paired device. This intentionally never
  /// opens a selector: the earlier pair request owns all user interaction.
  private func resolveDevice(
    peripheralID: String,
    advertisedName: String
  ) throws -> IOBluetoothDevice {
    switch try resolveClassicDevice(
      peripheralID: peripheralID,
      advertisedName: advertisedName
    ) {
    case .resolved(let selected):
      return selected
    case .needsSelection(let matchingCandidates):
      let isUnpaired = matchingCandidates == 0
      throw PlatformBridgeError(
        isUnpaired ? "device_not_paired" : "device_not_confirmed",
        isUnpaired
          ? "The matching classic Bluetooth device is not paired. Reconnect and complete the macOS pairing dialog."
          : "The classic Bluetooth device association is not confirmed. Reconnect and explicitly select the intended device."
      )
    }
  }

  private func provision(
    _ selected: IOBluetoothDevice,
    peripheralID: String
  ) {
    guard let address = selected.addressString else { return }
    provisionalMappings[mappingKey(peripheralID)] = address
  }

  private func mappingKey(_ peripheralID: String) -> String {
    "wristload.rfcomm.\(peripheralID.lowercased())"
  }

  private func canonicalName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  /// Matches a classic Bluetooth name to the exact advertised name. Xiaomi
  /// BLE advertisements may append a four-character hexadecimal instance
  /// suffix (for example ` 9D63`) that is absent from the classic name. Only
  /// that one-way, exact suffix form is accepted; broad prefix/contains
  /// matching could bind the wrong band when several devices share a model.
  private func classicNameMatchesAdvertisement(
    advertisedName: String,
    classicName: String
  ) -> Bool {
    classicNameMatchMode(
      advertisedName: advertisedName,
      classicName: classicName
    ) != nil
  }

  private func classicNameMatchMode(
    advertisedName: String,
    classicName: String
  ) -> String? {
    let advertised = canonicalName(advertisedName)
    let classic = canonicalName(classicName)
    guard !advertised.isEmpty, !classic.isEmpty else { return nil }
    if advertised == classic { return "exact" }

    let bytes = Array(advertised.utf8)
    guard bytes.count > 5, bytes[bytes.count - 5] == 0x20 else {
      return nil
    }
    let suffix = bytes[(bytes.count - 4)..<bytes.count]
    guard suffix.allSatisfy({ byte in
      (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x46) ||
          (byte >= 0x61 && byte <= 0x66)
    }) else {
      return nil
    }
    let baseBytes = bytes[..<(bytes.count - 5)]
    guard let base = String(bytes: baseBytes, encoding: .utf8),
          canonicalName(base) == classic else {
      return nil
    }
    return "advertised_trailing_hex"
  }

  private func deviceDescription(_ selected: IOBluetoothDevice) -> [String: Any] {
    [
      "address": selected.addressString ?? "",
      "name": selected.name ?? selected.nameOrAddress ?? "",
    ]
  }

  private func bind(
    _ openedChannel: IOBluetoothRFCOMMChannel,
    to current: MacOSRFCOMMSession
  ) -> Bool {
    guard isSameDevice(openedChannel.getDevice(), current.device) else {
      return false
    }
    let objectID = openedChannel.getObjectID()
    guard objectID != kIOBluetoothObjectIDNULL else { return false }
    if let expectedID = current.channelObjectID {
      return expectedID == objectID
    }
    guard let notification = openedChannel.register(
      forChannelCloseNotification: current.delegate,
      selector: #selector(
        MacOSRFCOMMSessionDelegate.rfcommChannelCloseNotification(_:channel:)
      )
    ) else {
      return false
    }
    current.channel = openedChannel
    current.channelObjectID = objectID
    current.closeNotification = notification
    return true
  }

  private func matches(
    _ candidate: IOBluetoothRFCOMMChannel,
    session current: MacOSRFCOMMSession
  ) -> Bool {
    if let expectedID = current.channelObjectID,
       expectedID != kIOBluetoothObjectIDNULL,
       candidate.getObjectID() == expectedID {
      return true
    }
    // IOBluetooth may clear an object's numeric ID before delivering the
    // close callback. Fall back to the retained channel object identity.
    return current.matchesClosedChannel(candidate)
  }

  private func isSameDevice(
    _ lhs: IOBluetoothDevice?,
    _ rhs: IOBluetoothDevice?
  ) -> Bool {
    guard let lhs, let rhs else { return false }
    if lhs === rhs { return true }
    guard let leftAddress = lhs.addressString,
          let rightAddress = rhs.addressString else { return false }
    return leftAddress.caseInsensitiveCompare(rightAddress) == .orderedSame
  }

  private func cancelPending(
    _ error: PlatformBridgeError,
    generation: UInt64
  ) {
    guard let current = session, current.generation == generation else { return }
    connectTimeout?.invalidate()
    connectTimeout = nil
    let completion = current.completion
    current.completion = nil
    completion?(error.flutterError)
    switch current.phase {
    case .queryingSDP:
      current.phase = .cancellingSDP
      scheduleTeardownWatchdog(for: current)
    case .opening, .connected:
      current.phase = .closingLocal
      current.cancelWritesAndRequestClose()
      guard let channel = current.channel else {
        scheduleTeardownWatchdog(for: current)
        return
      }
      enqueueChannelClose(channel, for: current)
      scheduleTeardownWatchdog(for: current)
    case .cancellingSDP, .closingLocal:
      return
    }
  }

  private func finishPending(
    _ error: PlatformBridgeError,
    session current: MacOSRFCOMMSession
  ) {
    guard let active = session, active === current else { return }
    emitEvent("error", generation: current.generation, fields: [
      "code": error.code,
      "message": error.message,
      "phase": phaseName(current.phase),
    ])
    let completion = current.completion
    current.completion = nil
    completion?(error.flutterError)
    finishSession(current)
  }

  private func finishInvalidOpen(
    _ openedChannel: IOBluetoothRFCOMMChannel,
    error: PlatformBridgeError,
    session current: MacOSRFCOMMSession
  ) {
    guard let active = session, active === current else {
      if let retired = retiredSessions[current.generation] {
        finishRetiredOpen(
          openedChannel,
          status: kIOReturnSuccess,
          session: retired
        )
      } else {
        current.cancelWritesAndRequestClose()
        enqueueChannelClose(openedChannel, for: current)
      }
      return
    }
    let completion = current.completion
    current.completion = nil
    current.phase = .closingLocal
    current.cancelWritesAndRequestClose()
    let boundChannel = current.channel
    enqueueChannelClose(openedChannel, for: current)
    if let boundChannel,
       boundChannel.getObjectID() != openedChannel.getObjectID() {
      enqueueChannelClose(boundChannel, for: current)
    }
    retireSession(current, disconnectError: nil)
    completion?(error.flutterError)
  }

  private func finishSession(_ current: MacOSRFCOMMSession) {
    guard let active = session, active === current else { return }
    connectTimeout?.invalidate()
    connectTimeout = nil
    current.teardownTimeout?.invalidate()
    current.teardownTimeout = nil
    current.retirementTimeout?.invalidate()
    current.retirementTimeout = nil
    current.cancelWritesAndRequestClose()
    session = nil
    finishDisconnects(current, error: nil)
    scheduleChannelTeardown(for: current)
  }

  private func scheduleTeardownWatchdog(for current: MacOSRFCOMMSession) {
    guard let active = session, active === current else { return }
    guard current.teardownTimeout == nil else { return }
    let generation = current.generation
    current.teardownTimeout = scheduleCommonModeTimer(
      interval: teardownTimeoutInterval
    ) { [weak self] _ in
      guard let self,
            let active = self.session,
            active.generation == generation else { return }
      self.retireSession(active, disconnectError: nil)
    }
  }

  private func retireSession(
    _ current: MacOSRFCOMMSession,
    disconnectError: FlutterError?
  ) {
    guard let active = session, active === current else { return }
    connectTimeout?.invalidate()
    connectTimeout = nil
    current.teardownTimeout?.invalidate()
    current.teardownTimeout = nil

    // Complete and clear all public callbacks before exposing an idle active
    // slot. The retired delegate continues to absorb only this generation's
    // late IOBluetooth callbacks.
    let connectCompletion = current.completion
    current.completion = nil
    current.cancelWritesAndRequestClose()
    session = nil
    retiredSessions[current.generation] = current
    current.retirementTimeout?.invalidate()
    let generation = current.generation
    current.retirementTimeout = scheduleCommonModeTimer(
      interval: retiredCleanupInterval
    ) { [weak self, weak current] _ in
      guard let self,
            let current,
            self.retiredSessions[generation] === current else { return }
      self.finishRetiredSession(current)
    }
    finishDisconnects(current, error: disconnectError)
    connectCompletion?(PlatformBridgeError(
      "rfcomm_cancelled",
      "RFCOMM connection cancelled."
    ).flutterError)
  }

  private func finishRetiredOpen(
    _ openedChannel: IOBluetoothRFCOMMChannel,
    status: IOReturn,
    session current: MacOSRFCOMMSession
  ) {
    guard retiredSessions[current.generation] === current else { return }
    guard status == kIOReturnSuccess else {
      current.cancelWritesAndRequestClose()
      enqueueChannelClose(openedChannel, for: current)
      finishRetiredSession(current)
      return
    }
    if current.channel == nil {
      guard isSameDevice(openedChannel.getDevice(), current.device),
            bind(openedChannel, to: current) else {
        current.cancelWritesAndRequestClose()
        enqueueChannelClose(openedChannel, for: current)
        return
      }
    }
    guard matches(openedChannel, session: current) else {
      current.cancelWritesAndRequestClose()
      enqueueChannelClose(openedChannel, for: current)
      return
    }
    current.cancelWritesAndRequestClose()
    enqueueChannelClose(openedChannel, for: current)
  }

  private func finishRetiredSession(_ current: MacOSRFCOMMSession) {
    guard retiredSessions[current.generation] === current else { return }
    current.teardownTimeout?.invalidate()
    current.teardownTimeout = nil
    current.retirementTimeout?.invalidate()
    current.retirementTimeout = nil
    current.cancelWritesAndRequestClose()
    retiredSessions.removeValue(forKey: current.generation)
    scheduleChannelTeardown(for: current)
  }

  private func enqueueChannelClose(
    _ channel: IOBluetoothRFCOMMChannel,
    for current: MacOSRFCOMMSession
  ) {
    current.cancelWritesAndRequestClose()
    let plan = current.prepareChannelClose(for: channel)
    guard plan.shouldEnqueue else { return }
    current.ioQueue.async { [weak self, current, channel, plan] in
      let status = channel.close()
      if plan.detachDelegate {
        _ = channel.setDelegate(nil)
      }
      guard status != kIOReturnSuccess else { return }
      DispatchQueue.main.async { [weak self, current] in
        guard let self else { return }
        if let active = self.session, active === current {
          self.retireSession(
            current,
            disconnectError: self.ioError(
              code: "rfcomm_close",
              message: "Unable to close the RFCOMM connection.",
              status: status
            ).flutterError
          )
        } else if self.retiredSessions[current.generation] === current {
          self.finishRetiredSession(current)
        }
      }
    }
  }

  private func scheduleChannelTeardown(
    for current: MacOSRFCOMMSession
  ) {
    guard current.markChannelTeardownScheduled() else { return }
    let channel = current.channel
    let notification = current.closeNotification
    let channels = current.takeChannelsForTeardown(including: channel)
    current.channel = nil
    current.channelObjectID = nil
    current.closeNotification = nil
    guard channel != nil || notification != nil || !channels.isEmpty else {
      current.delegate.owner = nil
      return
    }
    current.ioQueue.async { [current, channel, notification, channels] in
      for candidate in channels { _ = candidate.close() }
      notification?.unregister()
      if let channel {
        _ = channel.setDelegate(nil)
      }
      for candidate in channels where channel == nil || candidate !== channel {
        _ = candidate.setDelegate(nil)
      }
      DispatchQueue.main.async { [weak self, current] in
        guard let self else {
          current.delegate.owner = nil
          return
        }
        guard self.session !== current,
              self.retiredSessions[current.generation] !== current else {
          return
        }
        current.delegate.owner = nil
      }
    }
  }

  private func finishDisconnects(
    _ current: MacOSRFCOMMSession,
    error: FlutterError?
  ) {
    let completions = current.disconnectCompletions
    current.disconnectCompletions.removeAll()
    for completion in completions {
      completion(error)
    }
  }

  private func ioError(
    code: String,
    message: String,
    status: IOReturn
  ) -> PlatformBridgeError {
    PlatformBridgeError(code, "\(message) (IOBluetooth status \(status))", details: status)
  }

  private func runOnMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }
}
