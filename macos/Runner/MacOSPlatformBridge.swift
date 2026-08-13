import Cocoa
import FlutterMacOS
import IOBluetooth
import IOBluetoothUI
import Security

private let appOwnedBookmarkPrefix = "wristload-app-owned-v1:"
private let appOwnedCapabilityDefaultsPrefix = "wristload.drop.capability."
private let appOwnedDropDirectoryName = "Wristload/DropPromises"

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
      self?.emitRFCOMM(FlutterStandardTypedData(bytes: data))
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
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    rfcommEventSink = nil
    return nil
  }

  private func emitRFCOMM(_ event: Any) {
    if Thread.isMainThread {
      rfcommEventSink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.rfcommEventSink?(event)
      }
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
        result(try rfcommTransport.pair(
          peripheralID: identity.peripheralID,
          advertisedName: identity.name
        ))
      case "confirmIdentity":
        let identity = try rfcommIdentity(call.arguments)
        try rfcommTransport.confirmIdentity(
          peripheralID: identity.peripheralID,
          advertisedName: identity.name
        )
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
          let peripheralID = values["peripheralId"] as? String,
          !peripheralID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let name = values["name"] as? String,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PlatformBridgeError(
        "rfcomm_arguments",
        "A CoreBluetooth device identifier and advertised name are required."
      )
    }
    return (peripheralID, name)
  }
}

private enum MacOSAuthKeyStore {
  private static let service = "com.example.wristload.credentials"
  private static let account = "authkey"

  private static var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  static func read() throws -> String? {
    var query = baseQuery
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
      baseQuery as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    if updateStatus != errSecItemNotFound {
      try check(updateStatus, operation: "update")
    }
    var item = baseQuery
    item[kSecValueData] = data
    try check(SecItemAdd(item as CFDictionary, nil), operation: "add")
  }

  static func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status == errSecItemNotFound { return }
    try check(status, operation: "delete")
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

  @objc func sdpQueryComplete(_ queriedDevice: IOBluetoothDevice, status: IOReturn) {
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

private final class MacOSRFCOMMTransport: NSObject {
  var onData: ((Data) -> Void)?
  var onClosed: ((FlutterError) -> Void)?

  private var connectTimeout: Timer?
  private var nextGeneration: UInt64 = 0
  private var session: MacOSRFCOMMSession?
  private var retiredSessions: [UInt64: MacOSRFCOMMSession] = [:]
  private var provisionalMappings: [String: String] = [:]
  private let teardownTimeoutInterval: TimeInterval = 5
  private let retiredCleanupInterval: TimeInterval = 30

  func pair(peripheralID: String, advertisedName: String) throws -> [String: Any] {
    // An explicit pairing request retries any association that has not yet
    // passed the application-layer identity check. Confirmed mappings in
    // UserDefaults remain reusable and do not prompt again.
    provisionalMappings.removeValue(forKey: mappingKey(peripheralID))
    let selected = try resolveDevice(
      peripheralID: peripheralID,
      advertisedName: advertisedName,
      promptIfMissing: true
    )
    provision(selected, peripheralID: peripheralID)
    return deviceDescription(selected)
  }

  func confirmIdentity(peripheralID: String, advertisedName: String) throws {
    let mapping = mappingKey(peripheralID)
    guard let address = provisionalMappings[mapping],
          let selected = IOBluetoothDevice(addressString: address),
          selected.isPaired(),
          canonicalName(selected.name ?? selected.nameOrAddress ?? "") ==
            canonicalName(advertisedName) else {
      throw PlatformBridgeError(
        "device_identity_unconfirmed",
        "The authenticated classic Bluetooth identity is no longer available."
      )
    }
    UserDefaults.standard.set(address, forKey: mapping)
    provisionalMappings.removeValue(forKey: mapping)
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
        advertisedName: advertisedName,
        promptIfMissing: false
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

    let selected = try resolveDevice(
      peripheralID: peripheralID,
      advertisedName: advertisedName,
      promptIfMissing: false
    )
    guard let sppUUID = IOBluetoothSDPUUID.uuid16(0x1101) else {
      throw PlatformBridgeError(
        "spp_uuid",
        "Unable to create the Bluetooth SPP service UUID."
      )
    }

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
    let status = selected.performSDPQuery(sessionDelegate, uuids: [sppUUID])
    guard status == kIOReturnSuccess else {
      session = nil
      newSession.delegate.owner = nil
      throw ioError(
        code: "sdp_query",
        message: "Unable to start the SPP service query.",
        status: status
      )
    }
    connectTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) {
      [weak self] _ in
      self?.cancelPending(PlatformBridgeError(
        "rfcomm_connect_timeout",
        "The classic Bluetooth SPP connection timed out."
      ), generation: generation)
    }
  }

  fileprivate func sdpQueryComplete(
    _ queriedDevice: IOBluetoothDevice,
    status: IOReturn,
    generation: UInt64
  ) {
    runOnMain { [weak self] in
      self?.finishSDPQuery(
        queriedDevice,
        status: status,
        generation: generation
      )
    }
  }

  private func finishSDPQuery(
    _ queriedDevice: IOBluetoothDevice,
    status: IOReturn,
    generation: UInt64
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
    guard status == kIOReturnSuccess else {
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
    guard let sppUUID = IOBluetoothSDPUUID.uuid16(0x1101),
          let service = queriedDevice.getServiceRecord(for: sppUUID) else {
      finishPending(
        PlatformBridgeError(
          "spp_service_missing",
          "The selected device does not expose the Serial Port Profile service."
        ),
        session: current
      )
      return
    }
    var channelID: BluetoothRFCOMMChannelID = 0
    let channelStatus = service.getRFCOMMChannelID(&channelID)
    guard channelStatus == kIOReturnSuccess else {
      finishPending(
        ioError(
          code: "spp_channel_missing",
          message: "The SPP service does not expose an RFCOMM channel.",
          status: channelStatus
        ),
        session: current
      )
      return
    }

    current.phase = .opening
    var opened: IOBluetoothRFCOMMChannel?
    let openStatus = queriedDevice.openRFCOMMChannelAsync(
      &opened,
      withChannelID: channelID,
      delegate: current.delegate
    )
    guard openStatus == kIOReturnSuccess else {
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
    session.ioQueue.async { [weak self, session] in
      var failure: FlutterError?
      var cancelled = false
      var offset = 0
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
          failure = FlutterError(
            code: "rfcomm_write",
            message: "The RFCOMM write failed (IOBluetooth status \(status)).",
            details: status
          )
          break
        }
        offset += count
      }
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
    guard let current = session else {
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

  private func resolveDevice(
    peripheralID: String,
    advertisedName: String,
    promptIfMissing: Bool
  ) throws -> IOBluetoothDevice {
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
      if canonicalName(storedName) == wantedName {
        return stored
      }
      UserDefaults.standard.removeObject(forKey: mapping)
    }
    if let address = provisionalMappings[mapping],
       let provisional = IOBluetoothDevice(addressString: address),
       provisional.isPaired() {
      let provisionalName =
        provisional.name ?? provisional.nameOrAddress ?? ""
      if canonicalName(provisionalName) == wantedName {
        return provisional
      }
      provisionalMappings.removeValue(forKey: mapping)
    }

    let matches = (IOBluetoothDevice.pairedDevices() ?? [])
      .compactMap { $0 as? IOBluetoothDevice }
      .filter { candidate in
        let candidateName = candidate.name ?? candidate.nameOrAddress ?? ""
        return canonicalName(candidateName) == wantedName
      }
    if !promptIfMissing {
      let reason = matches.isEmpty
        ? "The matching classic Bluetooth device is not paired. Reconnect and complete the macOS pairing dialog."
        : "The classic Bluetooth device association is not confirmed. Reconnect and explicitly select the intended device."
      throw PlatformBridgeError(
        matches.isEmpty ? "device_not_paired" : "device_not_confirmed",
        reason
      )
    }

    guard let sppUUID = IOBluetoothSDPUUID.uuid16(0x1101) else {
      throw PlatformBridgeError(
        "spp_uuid",
        "Unable to create the Bluetooth SPP service UUID."
      )
    }
    let selected: IOBluetoothDevice
    if matches.isEmpty {
      // The ObjC +pairingController factory is imported into Swift as the
      // non-optional init(); calling the documented selector is unavailable
      // under Swift (renamed: "init()").
      let pairing = IOBluetoothPairingController()
      pairing.addAllowedUUID(sppUUID)
      pairing.setTitle("Select Classic Bluetooth Device")
      pairing.setDescriptionText(
        "Select the classic Bluetooth device matching \"\(advertisedName)\" and verify its address before continuing."
      )
      guard pairing.runModal() == kIOBluetoothUISuccess,
            let paired = pairing.getResults()?.first as? IOBluetoothDevice else {
        throw PlatformBridgeError(
          "pairing_cancelled",
          "Classic Bluetooth pairing was cancelled or did not complete."
        )
      }
      selected = paired
    } else {
      guard let selector = IOBluetoothDeviceSelectorController.deviceSelector()
      else {
        throw PlatformBridgeError(
          "device_selector",
          "Unable to show the classic Bluetooth device selector."
        )
      }
      selector.addAllowedUUID(sppUUID)
      selector.setTitle("Confirm Classic Bluetooth Device")
      selector.setDescriptionText(
        "Select the paired device matching \"\(advertisedName)\" and verify its address before continuing."
      )
      guard selector.runModal() == kIOBluetoothUISuccess,
            let chosen = selector.getResults()?.first as? IOBluetoothDevice,
            chosen.isPaired() else {
        throw PlatformBridgeError(
          "device_selection_cancelled",
          "Classic Bluetooth device selection was cancelled."
        )
      }
      selected = chosen
    }
    let selectedName = selected.name ?? selected.nameOrAddress ?? ""
    guard canonicalName(selectedName) == wantedName else {
      throw PlatformBridgeError(
        "paired_device_mismatch",
        "The selected classic Bluetooth device does not match the scanned device name."
      )
    }
    provision(selected, peripheralID: peripheralID)
    return selected
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
    current.teardownTimeout = Timer.scheduledTimer(
      withTimeInterval: teardownTimeoutInterval,
      repeats: false
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
    current.retirementTimeout = Timer.scheduledTimer(
      withTimeInterval: retiredCleanupInterval,
      repeats: false
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
