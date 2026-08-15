#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>

#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <poll.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <string>
#include <termios.h>
#include <thread>
#include <unistd.h>
#include <vector>

static NSString *const kCommandKey = @"command";
static NSString *const kRequestIDKey = @"requestId";
static const NSUInteger kMaximumWriteBytes = 256 * 1024;
static const NSUInteger kMaximumSerialProbeMilliseconds = 5000;
static const NSUInteger kMaximumSerialProbeBytes = 64 * 1024;
static const NSUInteger kMaximumSerialProbeHexBytes = 4096;
static const NSUInteger kVersionProbePayloadBytes = 11;
static const int64_t kSDPTimeoutMilliseconds = 15000;
static const int64_t kRFCOMMOpenTimeoutMilliseconds = 15000;
static const NSTimeInterval kSDPCachePollIntervalSeconds = 0.35;

static const uint8_t kVersionProbePayload[kVersionProbePayloadBytes] = {
    0xBA, 0xDC, 0xFE, 0x00, 0xC0, 0x03, 0x00, 0x00, 0x01, 0x00, 0xEF,
};

static NSData *AddressBytesForKey(NSString *key) {
  if (![key isKindOfClass:NSString.class] || key.length != 12) return nil;
  NSMutableData *data = [NSMutableData dataWithLength:6];
  uint8_t *bytes = static_cast<uint8_t *>(data.mutableBytes);
  for (NSUInteger index = 0; index < 6; ++index) {
    unsigned int value = 0;
    NSString *octet = [key substringWithRange:NSMakeRange(index * 2, 2)];
    if (![[NSScanner scannerWithString:octet] scanHexInt:&value]) return nil;
    bytes[index] = static_cast<uint8_t>(value);
  }
  return data;
}

static NSString *ColonAddressForKey(NSString *key) {
  if (key.length != 12) return nil;
  NSMutableArray<NSString *> *octets = [NSMutableArray arrayWithCapacity:6];
  for (NSUInteger index = 0; index < 12; index += 2) {
    [octets addObject:[key substringWithRange:NSMakeRange(index, 2)]];
  }
  return [octets componentsJoinedByString:@":"];
}

static BOOL IsSafeSerialBasename(NSString *value) {
  if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 255) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
  return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *HexStringForData(NSData *data, NSUInteger maximumBytes) {
  const NSUInteger count = MIN(data.length, maximumBytes);
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  NSMutableString *result = [NSMutableString stringWithCapacity:count * 3];
  for (NSUInteger index = 0; index < count; ++index) {
    if (index != 0) [result appendString:@" "];
    [result appendFormat:@"%02X", bytes[index]];
  }
  return result;
}

static BOOL RegistryEntryMatchesAddress(io_registry_entry_t entry, NSData *addressBytes) {
  for (NSString *propertyName in @[ @"BD_ADDR", @"BTAddress" ]) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(
        entry, (__bridge CFStringRef)propertyName, kCFAllocatorDefault, 0);
    if (property == nil) continue;
    const BOOL matches =
        CFGetTypeID(property) == CFDataGetTypeID() &&
        CFDataGetLength((CFDataRef)property) == addressBytes.length &&
        memcmp(CFDataGetBytePtr((CFDataRef)property), addressBytes.bytes, addressBytes.length) == 0;
    CFRelease(property);
    if (matches) return YES;
  }
  return NO;
}

static NSString *RegistryStringProperty(io_registry_entry_t entry, CFStringRef name) {
  CFTypeRef property = IORegistryEntryCreateCFProperty(entry, name, kCFAllocatorDefault, 0);
  if (property == nil) return nil;
  if (CFGetTypeID(property) != CFStringGetTypeID()) {
    CFRelease(property);
    return nil;
  }
  return CFBridgingRelease(property);
}

static NSArray<NSDictionary<NSString *, NSString *> *> *LiveSerialEndpointsForAddress(
    NSData *addressBytes, NSString **outRegistryError) {
  if (outRegistryError != nullptr) *outRegistryError = nil;
  CFMutableDictionaryRef matching = IOServiceMatching("IOBluetoothDevice");
  if (matching == nil) {
    if (outRegistryError != nullptr) *outRegistryError = @"Could not construct IOBluetoothDevice registry query.";
    return @[];
  }
  io_iterator_t devices = IO_OBJECT_NULL;
  const kern_return_t deviceStatus =
      IOServiceGetMatchingServices(kIOMainPortDefault, matching, &devices);
  if (deviceStatus != KERN_SUCCESS) {
    if (outRegistryError != nullptr) {
      *outRegistryError = [NSString stringWithFormat:@"IORegistry device query failed: 0x%08x", deviceStatus];
    }
    return @[];
  }

  NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *unique = [NSMutableDictionary dictionary];
  io_registry_entry_t device = IO_OBJECT_NULL;
  while ((device = IOIteratorNext(devices)) != IO_OBJECT_NULL) {
    if (RegistryEntryMatchesAddress(device, addressBytes)) {
      io_iterator_t descendants = IO_OBJECT_NULL;
      const kern_return_t descendantStatus = IORegistryEntryCreateIterator(
          device, kIOServicePlane, kIORegistryIterateRecursively, &descendants);
      if (descendantStatus == KERN_SUCCESS) {
        io_registry_entry_t child = IO_OBJECT_NULL;
        while ((child = IOIteratorNext(descendants)) != IO_OBJECT_NULL) {
          NSString *path = RegistryStringProperty(child, CFSTR(kIOCalloutDeviceKey));
          if ([path hasPrefix:@"/dev/cu."]) {
            NSString *basename = path.lastPathComponent;
            if (IsSafeSerialBasename(basename)) {
              unique[path] = @{ @"path": path, @"basename": basename };
            }
          }
          IOObjectRelease(child);
        }
        IOObjectRelease(descendants);
      }
    }
    IOObjectRelease(device);
  }
  IOObjectRelease(devices);
  return [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
    return [left[@"path"] compare:right[@"path"]];
  }];
}

static NSDictionary<NSString *, id> *PersistentPortEvidence(
    NSString *addressKey, NSString *liveBasename) {
  NSData *plistData = [NSData dataWithContentsOfFile:@"/Library/Preferences/com.apple.Bluetooth.plist"];
  NSError *error = nil;
  id root = plistData == nil ? nil : [NSPropertyListSerialization propertyListWithData:plistData options:0 format:nil error:&error];
  NSDictionary *ports = [root isKindOfClass:NSDictionary.class] ? root[@"PersistentPorts"] : nil;
  NSDictionary *entry = [ports isKindOfClass:NSDictionary.class] ? ports[ColonAddressForKey(addressKey)] : nil;
  if (![entry isKindOfClass:NSDictionary.class]) {
    return @{ @"persistentPortPresent": @NO, @"persistentPortVerified": @NO };
  }
  NSData *recordAddress = entry[@"BTAddress"];
  NSString *bsdName = entry[@"BSDName"];
  NSNumber *channel = entry[@"RFCOMMChannel"];
  NSString *liveBSDName = [liveBasename hasPrefix:@"cu."]
      ? [liveBasename substringFromIndex:3]
      : liveBasename;
  const BOOL addressMatches =
      [recordAddress isKindOfClass:NSData.class] &&
      recordAddress.length == 6 &&
      [recordAddress isEqualToData:AddressBytesForKey(addressKey)];
  // IORegistry exposes the callout basename as `cu.<BSDName>`, while the
  // Bluetooth persistent-port record stores only `<BSDName>`. Compare the
  // normalized values; neither is used as a lookup key.
  const BOOL bsdMatches = IsSafeSerialBasename(bsdName) && [bsdName isEqualToString:liveBSDName];
  const BOOL channelIsValid = [channel isKindOfClass:NSNumber.class] &&
      channel.unsignedIntegerValue > 0 && channel.unsignedIntegerValue <= UINT8_MAX;
  return @{
    @"persistentPortPresent": @YES,
    @"persistentPortVerified": @(addressMatches && bsdMatches),
    @"persistentBSDName": IsSafeSerialBasename(bsdName) ? bsdName : @"",
    @"persistentChannel": addressMatches && bsdMatches && channelIsValid ? channel : NSNull.null,
    @"persistentAddressMatches": @(addressMatches),
    @"persistentEndpointMatches": @(bsdMatches),
    @"persistentPlistReadError": error == nil ? @"" : error.localizedDescription,
  };
}

/// Opens only the exact live IORegistry endpoint for a classic MAC address.
/// It intentionally performs no writes, termios changes, ioctls, pairing, or
/// IOBluetooth calls, so it can establish a lower transport boundary safely.
static NSDictionary<NSString *, id> *ReadOnlySerialProbe(
    NSString *addressKey, NSUInteger durationMilliseconds) {
  NSMutableDictionary<NSString *, id> *result = [@{
    @"transport": @"serial-rfcomm",
    @"addressKey": addressKey,
    @"address": ColonAddressForKey(addressKey) ?: @"",
    @"identitySource": @"ioregistry_exact_bd_addr",
    @"openFlags": @"O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW",
    @"requestedReadWindowMs": @(durationMilliseconds),
    @"writes": @0,
    @"rxBytes": @0,
    @"rxHex": @"",
    @"rxHexTruncated": @NO,
  } mutableCopy];
  NSData *addressBytes = AddressBytesForKey(addressKey);
  if (addressBytes == nil) {
    result[@"outcome"] = @"invalid_address";
    result[@"errorCode"] = @"invalid_address";
    result[@"errorMessage"] = @"The serial probe requires a canonical classic Bluetooth MAC address.";
    return result;
  }

  NSString *registryError = nil;
  NSArray<NSDictionary<NSString *, NSString *> *> *candidates =
      LiveSerialEndpointsForAddress(addressBytes, &registryError);
  result[@"endpointCandidateCount"] = @(candidates.count);
  result[@"candidateBasenames"] = [candidates valueForKey:@"basename"] ?: @[];
  if (registryError != nil) {
    result[@"outcome"] = @"registry_error";
    result[@"errorCode"] = @"serial_registry_query_failed";
    result[@"errorMessage"] = registryError;
    return result;
  }
  if (candidates.count == 0) {
    result[@"outcome"] = @"endpoint_unavailable";
    result[@"errorCode"] = @"serial_endpoint_unavailable";
    result[@"errorMessage"] = @"No live serial endpoint matched the exact classic Bluetooth address.";
    return result;
  }
  if (candidates.count != 1) {
    result[@"outcome"] = @"endpoint_ambiguous";
    result[@"errorCode"] = @"serial_endpoint_ambiguous";
    result[@"errorMessage"] = @"Multiple live serial endpoints matched the exact classic Bluetooth address.";
    return result;
  }

  NSDictionary<NSString *, NSString *> *candidate = candidates.firstObject;
  NSString *path = candidate[@"path"];
  NSString *basename = candidate[@"basename"];
  result[@"endpoint"] = basename;
  result[@"endpointPath"] = path;
  [result addEntriesFromDictionary:PersistentPortEvidence(addressKey, basename)];

  struct stat before = {};
  if (lstat(path.fileSystemRepresentation, &before) != 0) {
    const int errorNumber = errno;
    result[@"outcome"] = @"endpoint_preflight_failed";
    result[@"errorCode"] = @"serial_endpoint_stat_failed";
    result[@"errno"] = @(errorNumber);
    result[@"errorMessage"] = [NSString stringWithUTF8String:strerror(errorNumber)] ?: @"lstat failed";
    return result;
  }
  result[@"endpointRdevBefore"] = @((unsigned long long)before.st_rdev);
  if (!S_ISCHR(before.st_mode)) {
    result[@"outcome"] = @"endpoint_preflight_failed";
    result[@"errorCode"] = @"serial_endpoint_not_character_device";
    result[@"errorMessage"] = @"The exact IORegistry endpoint is not a character device.";
    return result;
  }

  const auto openStarted = std::chrono::steady_clock::now();
  const int fd = open(path.fileSystemRepresentation,
                      O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  const auto openCompleted = std::chrono::steady_clock::now();
  result[@"openDurationMs"] = @(std::chrono::duration_cast<std::chrono::milliseconds>(
      openCompleted - openStarted).count());
  if (fd < 0) {
    const int errorNumber = errno;
    result[@"outcome"] = @"open_failed";
    result[@"errorCode"] = @"serial_endpoint_open_failed";
    result[@"errno"] = @(errorNumber);
    result[@"errorMessage"] = [NSString stringWithUTF8String:strerror(errorNumber)] ?: @"open failed";
    return result;
  }

  struct stat after = {};
  if (fstat(fd, &after) != 0 || !S_ISCHR(after.st_mode) || after.st_rdev != before.st_rdev) {
    const int errorNumber = errno;
    close(fd);
    result[@"outcome"] = @"endpoint_changed";
    result[@"errorCode"] = @"serial_endpoint_changed";
    result[@"errno"] = @(errorNumber);
    result[@"errorMessage"] = @"The serial endpoint changed or stopped being a character device while it was opened.";
    return result;
  }
  result[@"endpointRdevAfter"] = @((unsigned long long)after.st_rdev);

  NSMutableData *received = [NSMutableData data];
  NSString *closedReason = @"timeout";
  NSInteger readError = 0;
  const auto readStarted = std::chrono::steady_clock::now();
  const auto deadline = readStarted + std::chrono::milliseconds(durationMilliseconds);
  while (std::chrono::steady_clock::now() < deadline && received.length < kMaximumSerialProbeBytes) {
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now()).count();
    struct pollfd descriptor = { fd, static_cast<short>(POLLIN | POLLERR | POLLHUP), 0 };
    const int pollResult = poll(&descriptor, 1, static_cast<int>(std::max<int64_t>(1, remaining)));
    if (pollResult == 0) {
      closedReason = @"timeout";
      break;
    }
    if (pollResult < 0) {
      if (errno == EINTR) continue;
      readError = errno;
      closedReason = @"poll_error";
      break;
    }
    if ((descriptor.revents & POLLNVAL) != 0 || (descriptor.revents & POLLERR) != 0) {
      closedReason = @"poll_error";
      break;
    }
    bool reachedEOF = false;
    while (received.length < kMaximumSerialProbeBytes) {
      uint8_t buffer[4096];
      const size_t capacity = MIN(sizeof(buffer), kMaximumSerialProbeBytes - received.length);
      const ssize_t count = read(fd, buffer, capacity);
      if (count > 0) {
        [received appendBytes:buffer length:static_cast<NSUInteger>(count)];
        continue;
      }
      if (count == 0) {
        reachedEOF = true;
        break;
      }
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) break;
      readError = errno;
      closedReason = @"read_error";
      reachedEOF = true;
      break;
    }
    if (readError != 0 || reachedEOF) {
      if (readError == 0) closedReason = @"eof";
      break;
    }
    if (received.length >= kMaximumSerialProbeBytes) {
      closedReason = @"byte_limit";
      break;
    }
    if ((descriptor.revents & POLLHUP) != 0) {
      closedReason = @"hangup";
      break;
    }
  }
  const auto readCompleted = std::chrono::steady_clock::now();
  close(fd);
  result[@"outcome"] = readError == 0 ? @"opened" : @"read_failed";
  result[@"closedReason"] = closedReason;
  result[@"readDurationMs"] = @(std::chrono::duration_cast<std::chrono::milliseconds>(
      readCompleted - readStarted).count());
  result[@"rxBytes"] = @(received.length);
  result[@"rxHex"] = HexStringForData(received, kMaximumSerialProbeHexBytes);
  result[@"rxHexTruncated"] = @(received.length > kMaximumSerialProbeHexBytes);
  if (readError != 0) {
    result[@"errorCode"] = @"serial_endpoint_read_failed";
    result[@"errno"] = @(readError);
    result[@"errorMessage"] = [NSString stringWithUTF8String:strerror(readError)] ?: @"read failed";
  }
  return result;
}

@class WearableBluetoothBridge;

/// A query-specific callback target gives each asynchronous SDP request a
/// stable generation. IOBluetooth does not provide SDP cancellation, so a
/// late callback must never be mistaken for a later request on the same
/// device.
@interface WearableSDPQueryDelegate : NSObject
@property(nonatomic, weak) WearableBluetoothBridge *bridge;
@property(nonatomic, assign) uint64_t generation;
- (instancetype)initWithBridge:(WearableBluetoothBridge *)bridge
                     generation:(uint64_t)generation;
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status;
@end

@interface WearableBluetoothBridge : NSObject <IOBluetoothDeviceInquiryDelegate, IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, strong) IOBluetoothDeviceInquiry *inquiry;
@property(nonatomic, copy) NSString *scanID;
@property(nonatomic, copy) NSString *scanRequestID;
@property(nonatomic, copy) NSString *scanStopRequestID;

@property(nonatomic, strong) IOBluetoothDevice *pendingDevice;
@property(nonatomic, strong) IOBluetoothSDPUUID *pendingServiceUUID;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *openingChannel;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) NSMutableDictionary<NSString *, IOBluetoothDevice *> *deviceCache;
@property(nonatomic, copy) NSString *activeConnectionID;
@property(nonatomic, copy) NSString *activeConnectRequestID;
@property(nonatomic, copy) NSString *activeAddress;
@property(nonatomic, copy) NSString *activeAddressKey;
@property(nonatomic, copy) NSString *disconnectRequestID;
@property(nonatomic, assign) uint64_t attemptGeneration;
@property(nonatomic, assign) uint64_t openingGeneration;
@property(nonatomic, assign) BOOL rfcommOpenPending;
@property(nonatomic, assign) BluetoothRFCOMMChannelID openingChannelID;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, strong) WearableSDPQueryDelegate *pendingSDPDelegate;
@property(nonatomic, strong) NSTimer *sdpCachePollTimer;
@property(nonatomic, assign) uint64_t sdpCachePollGeneration;
@property(nonatomic, copy) NSString *sdpCachePollConnectionID;
@property(nonatomic, strong) NSDate *sdpBaselineServicesUpdate;
@property(nonatomic, strong) NSDate *sdpQueryStartedAt;
@property(nonatomic, assign) BOOL sdpCacheRefreshObserved;
@property(nonatomic, strong) IOBluetoothDevice *sdpDrainDevice;
@property(nonatomic, copy) NSString *sdpDrainAddressKey;
@property(nonatomic, strong) WearableSDPQueryDelegate *sdpDrainDelegate;
@property(nonatomic, assign) uint64_t sdpDrainGeneration;
@property(nonatomic, assign) BOOL sdpDrainPending;
@property(nonatomic, assign) BOOL serialProbeInFlight;
@property(nonatomic, copy) NSString *serialProbeRequestID;
@property(nonatomic, copy) NSString *helperSessionID;

- (void)completeSDPQueryForDevice:(IOBluetoothDevice *)device
                            status:(IOReturn)status
                        generation:(uint64_t)generation
                  completionSource:(NSString *)completionSource;
- (void)handleSDPCallbackForDevice:(IOBluetoothDevice *)device
                             status:(IOReturn)status
                         generation:(uint64_t)generation
                           delegate:(WearableSDPQueryDelegate *)delegate;
- (void)beginConnectionWithDevice:(IOBluetoothDevice *)device
                         requestID:(NSString *)requestID
                      connectionID:(NSString *)connectionID
                               key:(NSString *)key
                            address:(NSString *)address
                         apiAddress:(NSString *)apiAddress
                        serviceUUID:(IOBluetoothSDPUUID *)serviceUUID
              requestedServiceUUID:(NSString *)requestedServiceUUID
                       lookupSource:(NSString *)lookupSource;
- (void)clearRFCOMMOpeningState;
- (void)serialProbe:(NSDictionary *)command requestID:(NSString *)requestID;
@end

@implementation WearableBluetoothBridge

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _helperSessionID = NSUUID.UUID.UUIDString;
    _deviceCache = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)emit:(NSDictionary *)event {
  NSCAssert(NSThread.isMainThread, @"Bridge state and stdout are main-thread only");
  NSError *error = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:&error];
  if (json == nil) {
    fprintf(stderr, "Could not encode bridge event: %s\n", error.localizedDescription.UTF8String);
    return;
  }

  NSMutableData *line = [json mutableCopy];
  const uint8_t newline = '\n';
  [line appendBytes:&newline length:1];
  [[NSFileHandle fileHandleWithStandardOutput] writeData:line];
}

- (void)emitError:(NSString *)code
           message:(NSString *)message
         requestID:(NSString *)requestID
      connectionID:(NSString *)connectionID {
  NSMutableDictionary *event = [@{ @"event": @"error", @"code": code, @"message": message } mutableCopy];
  if (requestID != nil) event[@"requestId"] = requestID;
  if (connectionID != nil) event[@"connectionId"] = connectionID;
  [self emit:event];
}

- (void)emitConnectionStage:(NSString *)stage
                  requestID:(NSString *)requestID
               connectionID:(NSString *)connectionID
                      fields:(NSDictionary *)fields {
  NSMutableDictionary *event = [@{
    @"event": @"connection.stage",
    @"stage": stage,
    @"connectionId": connectionID ?: @"",
  } mutableCopy];
  if (requestID != nil) event[@"requestId"] = requestID;
  if (self.activeAddress != nil) event[@"address"] = self.activeAddress;
  if (self.activeAddressKey != nil) event[@"addressKey"] = self.activeAddressKey;
  [event addEntriesFromDictionary:fields ?: @{}];
  [self emit:event];
}

- (id)millisecondsFieldForDate:(NSDate *)date {
  if (date == nil) return NSNull.null;
  return @((int64_t)(date.timeIntervalSince1970 * 1000.0));
}

- (NSArray<IOBluetoothSDPServiceRecord *> *)serviceRecordsForDevice:(IOBluetoothDevice *)device {
  NSMutableArray<IOBluetoothSDPServiceRecord *> *records = [NSMutableArray array];
  for (id candidate in device.services ?: @[]) {
    if ([candidate isKindOfClass:IOBluetoothSDPServiceRecord.class]) {
      [records addObject:(IOBluetoothSDPServiceRecord *)candidate];
    }
  }
  return records;
}

- (BOOL)hasFreshSDPCacheForDevice:(IOBluetoothDevice *)device {
  NSDate *lastUpdate = [device getLastServicesUpdate];
  if (lastUpdate == nil) return NO;
  if (self.sdpBaselineServicesUpdate != nil) {
    return [lastUpdate compare:self.sdpBaselineServicesUpdate] == NSOrderedDescending;
  }
  // With no pre-query cache, only a services update contemporaneous with this
  // query can act as a delegate-missing completion signal.
  return self.sdpQueryStartedAt != nil &&
      lastUpdate.timeIntervalSince1970 >= self.sdpQueryStartedAt.timeIntervalSince1970 - 1.0;
}

- (void)invalidateSDPCachePolling {
  [self.sdpCachePollTimer invalidate];
  self.sdpCachePollTimer = nil;
  self.sdpCachePollGeneration = 0;
  self.sdpCachePollConnectionID = nil;
}

- (void)movePendingSDPQueryToDrain {
  if (self.pendingDevice == nil || self.pendingSDPDelegate == nil) return;
  self.sdpDrainDevice = self.pendingDevice;
  self.sdpDrainAddressKey = self.activeAddressKey;
  self.sdpDrainDelegate = self.pendingSDPDelegate;
  self.sdpDrainGeneration = self.pendingSDPDelegate.generation;
  self.sdpDrainPending = YES;
  self.pendingSDPDelegate = nil;
}

- (void)clearSDPDrain {
  self.sdpDrainPending = NO;
  self.sdpDrainDevice = nil;
  self.sdpDrainAddressKey = nil;
  self.sdpDrainDelegate = nil;
  self.sdpDrainGeneration = 0;
}

- (void)startSDPCachePollingForGeneration:(uint64_t)generation
                              connectionID:(NSString *)connectionID
                                   device:(IOBluetoothDevice *)device {
  [self invalidateSDPCachePolling];
  self.sdpCachePollGeneration = generation;
  self.sdpCachePollConnectionID = connectionID;
  __weak WearableBluetoothBridge *weakSelf = self;
  NSTimer *timer = [NSTimer timerWithTimeInterval:kSDPCachePollIntervalSeconds
                                           repeats:YES
                                             block:^(NSTimer *unusedTimer) {
    WearableBluetoothBridge *strongSelf = weakSelf;
    if (strongSelf == nil ||
        generation != strongSelf.attemptGeneration ||
        generation != strongSelf.sdpCachePollGeneration ||
        ![connectionID isEqualToString:strongSelf.activeConnectionID] ||
        ![connectionID isEqualToString:strongSelf.sdpCachePollConnectionID] ||
        device != strongSelf.pendingDevice) {
      [unusedTimer invalidate];
      return;
    }
    if (strongSelf.sdpCacheRefreshObserved ||
        ![strongSelf hasFreshSDPCacheForDevice:device]) return;
    strongSelf.sdpCacheRefreshObserved = YES;
    NSArray<IOBluetoothSDPServiceRecord *> *records = [strongSelf serviceRecordsForDevice:device];
    [strongSelf emitConnectionStage:@"sdp.cache_refresh"
                          requestID:strongSelf.activeConnectRequestID
                       connectionID:connectionID
                            fields:@{
                              @"queryKind": @"full",
                              @"baselineLastServicesUpdateMillis": [strongSelf millisecondsFieldForDate:strongSelf.sdpBaselineServicesUpdate],
                              @"lastServicesUpdateMillis": [strongSelf millisecondsFieldForDate:[device getLastServicesUpdate]],
                              @"serviceCount": @(records.count),
                              @"delegateCallbackObserved": @NO,
                            }];
    // A changed service-cache timestamp is diagnostic evidence only. The
    // performSDPQuery: delegate callback remains the sole terminal signal.
  }];
  self.sdpCachePollTimer = timer;
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)scheduleSDPTimeoutForGeneration:(uint64_t)generation
                           connectionID:(NSString *)connectionID
                                device:(IOBluetoothDevice *)device {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kSDPTimeoutMilliseconds * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        if (generation != self.attemptGeneration ||
            ![connectionID isEqualToString:self.activeConnectionID] ||
            device != self.pendingDevice) return;
        [self movePendingSDPQueryToDrain];
        [self emitConnectionStage:@"sdp.timeout"
                        requestID:self.activeConnectRequestID
                     connectionID:connectionID
                            fields:@{
                              @"timeoutMs": @(kSDPTimeoutMilliseconds),
                              @"queryKind": @"full",
                              @"baselineLastServicesUpdateMillis": [self millisecondsFieldForDate:self.sdpBaselineServicesUpdate],
                              @"lastServicesUpdateMillis": [self millisecondsFieldForDate:[device getLastServicesUpdate]],
                              @"serviceCount": @([self serviceRecordsForDevice:device].count),
                              @"cacheRefreshObserved": @(self.sdpCacheRefreshObserved),
                            }];
        [self endConnectionWithReason:@"error"
                           errorCode:@"sdp_timeout"
                             message:@"SDP query did not deliver its terminal callback within 15000 ms."
                           requestID:self.activeConnectRequestID];
      });
}

- (void)scheduleRFCOMMOpenTimeoutForGeneration:(uint64_t)generation
                                  connectionID:(NSString *)connectionID
                                    channelID:(BluetoothRFCOMMChannelID)channelID {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kRFCOMMOpenTimeoutMilliseconds * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        if (generation != self.attemptGeneration ||
            ![connectionID isEqualToString:self.activeConnectionID] ||
            !self.rfcommOpenPending ||
            self.openingGeneration != generation ||
            self.openingChannelID != channelID) return;
        [self emitConnectionStage:@"rfcomm.open.timeout"
                        requestID:self.activeConnectRequestID
                     connectionID:connectionID
                            fields:@{
                              @"channel": @(channelID),
                              @"channelAllocated": @(self.openingChannel != nil),
                              @"timeoutMs": @(kRFCOMMOpenTimeoutMilliseconds),
                            }];
        [self endConnectionWithReason:@"error"
                           errorCode:@"rfcomm_open_timeout"
                             message:@"RFCOMM channel open did not deliver its terminal callback within 15000 ms."
                           requestID:self.activeConnectRequestID];
      });
}

- (void)clearRFCOMMOpeningState {
  self.rfcommOpenPending = NO;
  self.openingGeneration = 0;
  self.openingChannelID = 0;
  self.openingChannel = nil;
}

- (NSString *)addressKeyFromString:(NSString *)address {
  if (![address isKindOfClass:NSString.class]) return nil;
  NSString *compact = [[[[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
      stringByReplacingOccurrencesOfString:@"-" withString:@""]
      stringByReplacingOccurrencesOfString:@":" withString:@""] uppercaseString];
  if (compact.length != 12) return nil;
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
  return [compact rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound ? compact : nil;
}

- (NSString *)displayAddressForKey:(NSString *)key {
  if (key.length != 12) return nil;
  NSMutableArray<NSString *> *octets = [NSMutableArray arrayWithCapacity:6];
  for (NSUInteger index = 0; index < 12; index += 2) {
    [octets addObject:[key substringWithRange:NSMakeRange(index, 2)]];
  }
  return [octets componentsJoinedByString:@"-"];
}

- (NSDictionary *)deviceEventForDevice:(IOBluetoothDevice *)device source:(NSString *)source scanID:(NSString *)scanID {
  NSString *key = [self addressKeyFromString:device.addressString];
  NSString *address = [self displayAddressForKey:key];
  NSMutableDictionary *event = [@{
    @"event": @"device",
    @"address": address ?: @"",
    @"addressKey": key ?: @"",
    @"source": source,
    @"paired": @([device isPaired]),
  } mutableCopy];
  if (scanID != nil) event[@"scanId"] = scanID;
  if (device.name != nil) event[@"name"] = device.name;
  return event;
}

- (IOBluetoothSDPUUID *)serviceUUIDFromString:(NSString *)value {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *compact = [[[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
      stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
  if ((compact.length != 4 && compact.length != 8 && compact.length != 32) ||
      [compact rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return nil;
  if (compact.length == 4 || compact.length == 8) {
    unsigned int uuid = 0;
    [[NSScanner scannerWithString:compact] scanHexInt:&uuid];
    return compact.length == 4 ? [IOBluetoothSDPUUID uuid16:(BluetoothSDPUUID16)uuid] : [IOBluetoothSDPUUID uuid32:(BluetoothSDPUUID32)uuid];
  }
  NSMutableData *bytes = [NSMutableData dataWithLength:16];
  uint8_t *output = static_cast<uint8_t *>(bytes.mutableBytes);
  for (NSUInteger index = 0; index < 16; ++index) {
    unsigned int octet = 0;
    [[NSScanner scannerWithString:[compact substringWithRange:NSMakeRange(index * 2, 2)]] scanHexInt:&octet];
    output[index] = static_cast<uint8_t>(octet);
  }
  return [IOBluetoothSDPUUID uuidWithData:bytes];
}

- (void)handleCommand:(NSDictionary *)command {
  NSCAssert(NSThread.isMainThread, @"Commands must run on main thread");
  NSString *requestID = command[kRequestIDKey];
  if (![requestID isKindOfClass:NSString.class] || requestID.length == 0) {
    [self emitError:@"invalid_request_id" message:@"Every command must contain a non-empty string requestId." requestID:nil connectionID:nil];
    return;
  }
  NSString *name = command[kCommandKey];
  if (![name isKindOfClass:NSString.class]) {
    [self emitError:@"invalid_command" message:@"Expected a string field named command." requestID:requestID connectionID:nil];
    return;
  }
  [self emit:@{ @"event": @"command.received", @"command": name, @"requestId": requestID }];

  if ([name isEqualToString:@"hello"]) [self hello:requestID];
  else if ([name isEqualToString:@"paired.list"]) [self listPaired:requestID];
  else if ([name isEqualToString:@"scan.start"]) [self startScan:command requestID:requestID];
  else if ([name isEqualToString:@"scan.stop"]) [self stopScan:command requestID:requestID];
  else if ([name isEqualToString:@"connect"]) [self connect:command requestID:requestID];
  else if ([name isEqualToString:@"serial.probe"]) [self serialProbe:command requestID:requestID];
  else if ([name isEqualToString:@"write"]) [self write:command requestID:requestID];
  else if ([name isEqualToString:@"disconnect"]) [self disconnect:command requestID:requestID];
  else [self emitError:@"invalid_command" message:[NSString stringWithFormat:@"Unsupported command: %@", name] requestID:requestID connectionID:nil];
}

- (void)hello:(NSString *)requestID {
  [self emit:@{ @"event": @"hello.done", @"requestId": requestID, @"protocolVersion": @1, @"helperSessionId": self.helperSessionID }];
}

- (void)serialProbe:(NSDictionary *)command requestID:(NSString *)requestID {
  if (self.serialProbeInFlight) {
    [self emitError:@"serial_probe_in_progress"
             message:@"A read-only serial endpoint probe is already active."
           requestID:requestID
        connectionID:nil];
    return;
  }
  NSString *addressKey = [self addressKeyFromString:command[@"address"]];
  if (addressKey == nil) {
    [self emitError:@"invalid_serial_probe_arguments"
             message:@"serial.probe requires a canonical classic Bluetooth address."
           requestID:requestID
        connectionID:nil];
    return;
  }
  NSNumber *durationValue = command[@"durationMs"];
  NSUInteger durationMilliseconds = kMaximumSerialProbeMilliseconds;
  if (durationValue != nil) {
    if (![durationValue isKindOfClass:NSNumber.class] ||
        durationValue.integerValue < 1 ||
        durationValue.integerValue > kMaximumSerialProbeMilliseconds) {
      [self emitError:@"invalid_serial_probe_arguments"
               message:@"serial.probe durationMs must be an integer from 1 through 5000."
             requestID:requestID
          connectionID:nil];
      return;
    }
    durationMilliseconds = durationValue.unsignedIntegerValue;
  }
  self.serialProbeInFlight = YES;
  self.serialProbeRequestID = requestID;
  [self emit:@{
    @"event": @"serial.probe.started",
    @"requestId": requestID,
    @"addressKey": addressKey,
    @"address": [self displayAddressForKey:addressKey] ?: @"",
    @"transport": @"serial-rfcomm",
    @"writes": @0,
    @"durationMs": @(durationMilliseconds),
  }];
  __weak WearableBluetoothBridge *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSDictionary<NSString *, id> *result = ReadOnlySerialProbe(addressKey, durationMilliseconds);
    dispatch_async(dispatch_get_main_queue(), ^{
      WearableBluetoothBridge *strongSelf = weakSelf;
      if (strongSelf == nil || !strongSelf.serialProbeInFlight ||
          ![strongSelf.serialProbeRequestID isEqualToString:requestID]) return;
      strongSelf.serialProbeInFlight = NO;
      strongSelf.serialProbeRequestID = nil;
      NSMutableDictionary *event = [result mutableCopy];
      event[@"event"] = @"serial.probe.done";
      event[@"requestId"] = requestID;
      [strongSelf emit:event];
    });
  });
}

- (void)listPaired:(NSString *)requestID {
  NSMutableArray *devices = [NSMutableArray array];
  for (IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices) {
    NSString *key = [self addressKeyFromString:device.addressString];
    NSString *address = [self displayAddressForKey:key];
    if (key == nil || address == nil) continue;
    NSMutableDictionary *entry = [@{ @"address": address, @"addressKey": key, @"paired": @YES } mutableCopy];
    if (device.name != nil) entry[@"name"] = device.name;
    self.deviceCache[key] = device;
    [devices addObject:entry];
  }
  [self emit:@{ @"event": @"paired.list.done", @"requestId": requestID, @"devices": devices }];
}

- (void)startScan:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *scanID = command[@"scanId"];
  if (![scanID isKindOfClass:NSString.class] || scanID.length == 0) {
    [self emitError:@"invalid_scan_id" message:@"scan.start requires a non-empty string scanId." requestID:requestID connectionID:nil];
    return;
  }
  if (self.inquiry != nil) {
    [self emitError:@"scan_in_progress" message:@"A classic Bluetooth inquiry is already active." requestID:requestID connectionID:nil];
    return;
  }
  IOBluetoothDeviceInquiry *inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
  inquiry.searchType = kIOBluetoothDeviceSearchClassic;
  inquiry.updateNewDeviceNames = NO;
  NSNumber *seconds = command[@"duration"];
  if ([seconds isKindOfClass:NSNumber.class] && seconds.integerValue >= 1 && seconds.integerValue <= UINT8_MAX) inquiry.inquiryLength = (uint8_t)seconds.integerValue;
  IOReturn status = [inquiry start];
  if (status != kIOReturnSuccess) {
    [self emitError:@"scan_start_failed" message:[NSString stringWithFormat:@"IOBluetooth inquiry failed: 0x%08x", status] requestID:requestID connectionID:nil];
    return;
  }
  self.inquiry = inquiry;
  self.scanID = scanID;
  self.scanRequestID = requestID;
  [self emit:@{ @"event": @"scan.started", @"requestId": requestID, @"scanId": scanID }];
}

- (void)stopScan:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *scanID = command[@"scanId"];
  if (![scanID isKindOfClass:NSString.class] || ![scanID isEqualToString:self.scanID]) {
    [self emitError:@"scan_mismatch" message:@"scan.stop must name the active scanId." requestID:requestID connectionID:nil];
    return;
  }
  IOReturn status = [self.inquiry stop];
  if (status != kIOReturnSuccess && status != kIOReturnNotPermitted) {
    [self emitError:@"scan_stop_failed" message:[NSString stringWithFormat:@"Could not stop inquiry: 0x%08x", status] requestID:requestID connectionID:nil];
    return;
  }
  self.scanStopRequestID = requestID;
  // deviceInquiryComplete is the terminal event. Waiting for it guarantees a
  // subsequent scan.start cannot race the still-active native inquiry.
}

- (void)connect:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *connectionID = command[@"connectionId"];
  if (![connectionID isKindOfClass:NSString.class] || connectionID.length == 0) {
    [self emitError:@"invalid_connection_id" message:@"connect requires a non-empty string connectionId." requestID:requestID connectionID:nil];
    return;
  }
  if (self.activeConnectionID != nil) {
    [self emitError:@"connection_busy" message:@"Disconnect the current or pending RFCOMM connection first." requestID:requestID connectionID:connectionID];
    return;
  }
  NSString *key = [self addressKeyFromString:command[@"address"]];
  IOBluetoothSDPUUID *serviceUUID = [self serviceUUIDFromString:command[@"serviceUuid"]];
  if (key == nil || serviceUUID == nil) {
    [self emitError:@"invalid_connect_arguments" message:@"connect requires a Bluetooth address and a 16-, 32-, or 128-bit serviceUuid." requestID:requestID connectionID:connectionID];
    return;
  }
  NSString *address = [self displayAddressForKey:key];
  NSString *apiAddress = [address stringByReplacingOccurrencesOfString:@"-" withString:@":"];
  [self emitConnectionStage:@"device.lookup.started"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"address": address,
                        @"addressKey": key,
                        @"apiAddress": apiAddress,
                      }];
  // Never synchronously enumerate pairedDevices here. On this macOS host
  // that call has demonstrably blocked the helper's main run loop. Inquiry and
  // explicit paired-list refreshes cache the native object by classic MAC.
  IOBluetoothDevice *device = self.deviceCache[key];
  [self emitConnectionStage:@"device.lookup.completed"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"address": address,
                        @"addressKey": key,
                        @"deviceFound": @(device != nil),
                        @"lookupSource": device == nil ? @"scan_cache_miss" : @"scan_cache",
                      }];
  if (device == nil) {
    [self emitError:@"device_lookup_requires_scan"
             message:@"No cached IOBluetoothDevice exists for this address. Run a classic inquiry first; direct paired-device enumeration is deliberately not used because macOS blocks it on this host."
           requestID:requestID
        connectionID:connectionID];
    return;
  }
  [self beginConnectionWithDevice:device
                        requestID:requestID
                     connectionID:connectionID
                              key:key
                           address:address
                        apiAddress:apiAddress
                       serviceUUID:serviceUUID
             requestedServiceUUID:command[@"serviceUuid"]
                      lookupSource:@"scan_cache"];
}

- (void)beginConnectionWithDevice:(IOBluetoothDevice *)device
                         requestID:(NSString *)requestID
                      connectionID:(NSString *)connectionID
                               key:(NSString *)key
                            address:(NSString *)address
                         apiAddress:(NSString *)apiAddress
                        serviceUUID:(IOBluetoothSDPUUID *)serviceUUID
              requestedServiceUUID:(NSString *)requestedServiceUUID
                       lookupSource:(NSString *)lookupSource {
  if (self.sdpDrainPending) {
    [self emitError:@"sdp_drain_required"
             message:@"The previous SDP query has not delivered its terminal callback; restart the helper before starting another RFCOMM connection."
           requestID:requestID
        connectionID:connectionID];
    return;
  }
  self.activeConnectionID = connectionID;
  self.activeConnectRequestID = requestID;
  self.activeAddress = address;
  self.activeAddressKey = key;
  self.pendingDevice = device;
  self.pendingServiceUUID = serviceUUID;
  const uint64_t generation = ++self.attemptGeneration;
  self.pendingSDPDelegate = [[WearableSDPQueryDelegate alloc] initWithBridge:self generation:generation];
  self.sdpBaselineServicesUpdate = [device getLastServicesUpdate];
  self.sdpQueryStartedAt = NSDate.date;
  self.sdpCacheRefreshObserved = NO;
  [self emitConnectionStage:@"sdp.started"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"timeoutMs": @(kSDPTimeoutMilliseconds),
                        @"queryKind": @"full",
                        @"lookupSource": lookupSource,
                        @"requestedServiceUuid": requestedServiceUUID ?: @"",
                        @"baselineLastServicesUpdateMillis": [self millisecondsFieldForDate:self.sdpBaselineServicesUpdate],
                        @"queryStartedMillis": [self millisecondsFieldForDate:self.sdpQueryStartedAt],
                        @"cachedServiceCount": @([self serviceRecordsForDevice:device].count),
                        @"paired": @([device isPaired]),
                        @"basebandConnected": @([device isConnected]),
                      }];
  // Both observers are active before the asynchronous query starts. A complete
  // SDP query asks macOS for all L2CAP-derived records; the requested UUID is
  // used only to select a unique RFCOMM endpoint after completion.
  [self scheduleSDPTimeoutForGeneration:generation connectionID:connectionID device:device];
  [self startSDPCachePollingForGeneration:generation connectionID:connectionID device:device];
  [self emitConnectionStage:@"sdp.invoke.started"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{ @"queryKind": @"full" }];
  IOReturn status = [device performSDPQuery:self.pendingSDPDelegate];
  [self emitConnectionStage:@"sdp.invoke.returned"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"queryKind": @"full",
                        @"status": @(status),
                        @"statusHex": [NSString stringWithFormat:@"0x%08x", status],
                      }];
  if (status != kIOReturnSuccess) {
    [self invalidateSDPCachePolling];
    [self endConnectionWithReason:@"error" errorCode:@"sdp_start_failed" message:[NSString stringWithFormat:@"Could not start SDP query: 0x%08x", status] requestID:requestID];
  }
}

- (void)handleSDPCallbackForDevice:(IOBluetoothDevice *)device
                             status:(IOReturn)status
                         generation:(uint64_t)generation
                           delegate:(WearableSDPQueryDelegate *)delegate {
  NSCAssert(NSThread.isMainThread, @"SDP callback state must run on the main thread");
  if (self.sdpDrainPending &&
      delegate == self.sdpDrainDelegate &&
      generation == self.sdpDrainGeneration &&
      device == self.sdpDrainDevice) {
    [self emit:@{
      @"event": @"connection.diagnostic",
      @"kind": @"sdp.drain.completed",
      @"generation": @(generation),
      @"addressKey": self.sdpDrainAddressKey ?: @"",
      @"status": @(status),
    }];
    [self clearSDPDrain];
    return;
  }
  if (delegate != self.pendingSDPDelegate) return;
  [self completeSDPQueryForDevice:device
                           status:status
                       generation:generation
                 completionSource:@"delegate"];
}

- (void)completeSDPQueryForDevice:(IOBluetoothDevice *)device
                            status:(IOReturn)status
                        generation:(uint64_t)generation
                  completionSource:(NSString *)completionSource {
  if (generation != self.attemptGeneration ||
      device != self.pendingDevice ||
      self.activeConnectionID == nil) return;
  NSString *requestID = self.activeConnectRequestID;
  NSString *connectionID = self.activeConnectionID;
  NSArray<IOBluetoothSDPServiceRecord *> *records = [self serviceRecordsForDevice:device];
  [self invalidateSDPCachePolling];
  // `performSDPQuery:` owns the terminal callback. A service-cache update is
  // diagnostic evidence only and must never advance this state machine.
  self.pendingSDPDelegate = nil;
  [self emitConnectionStage:@"sdp.completed"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"status": @(status),
                        @"queryKind": @"full",
                        @"completionSource": completionSource,
                        @"baselineLastServicesUpdateMillis": [self millisecondsFieldForDate:self.sdpBaselineServicesUpdate],
                        @"lastServicesUpdateMillis": [self millisecondsFieldForDate:[device getLastServicesUpdate]],
                        @"serviceCount": @(records.count),
                        @"cacheRefreshObserved": @(self.sdpCacheRefreshObserved),
                        @"paired": @([device isPaired]),
                        @"basebandConnected": @([device isConnected]),
                      }];
  if (status != kIOReturnSuccess) {
    [self endConnectionWithReason:@"error" errorCode:@"sdp_query_failed" message:[NSString stringWithFormat:@"SDP query failed: 0x%08x", status] requestID:requestID];
    return;
  }
  NSMutableArray<NSNumber *> *channels = [NSMutableArray array];
  NSUInteger matchingServiceCount = 0;
  for (NSUInteger index = 0; index < records.count; ++index) {
    IOBluetoothSDPServiceRecord *record = records[index];
    const BOOL matchesRequestedService = [record matchesUUIDArray:@[ self.pendingServiceUUID ]];
    BluetoothRFCOMMChannelID candidateChannel = 0;
    const IOReturn channelStatus = [record getRFCOMMChannelID:&candidateChannel];
    [self emit:@{
      @"event": @"connection.diagnostic",
      @"kind": @"sdp.service_record",
      @"connectionId": connectionID,
      @"index": @(index),
      @"queryKind": @"full",
      @"completionSource": completionSource,
      @"serviceName": [record getServiceName] ?: @"",
      @"matchesRequestedService": @(matchesRequestedService),
      @"rfcommChannelStatus": @(channelStatus),
      @"rfcommChannelId": channelStatus == kIOReturnSuccess ? @(candidateChannel) : @(-1),
    }];
    if (!matchesRequestedService) continue;
    ++matchingServiceCount;
    if (channelStatus == kIOReturnSuccess) {
      [channels addObject:@(candidateChannel)];
    }
  }
  NSOrderedSet<NSNumber *> *uniqueChannels = [NSOrderedSet orderedSetWithArray:channels];
  if (uniqueChannels.count == 0) {
    NSString *code = matchingServiceCount == 0 ? @"rfcomm_service_not_found" : @"rfcomm_channel_missing";
    NSString *message = matchingServiceCount == 0
        ? @"The requested SDP service was not returned by the device."
        : @"The requested SDP service has no RFCOMM channel.";
    [self emitConnectionStage:@"sdp.endpoint.unavailable"
                    requestID:requestID
                 connectionID:connectionID
                        fields:@{
                          @"serviceCount": @(records.count),
                          @"matchingServiceCount": @(matchingServiceCount),
                          @"uniqueRFCOMMChannelCount": @(uniqueChannels.count),
                        }];
    [self endConnectionWithReason:@"error" errorCode:code message:message requestID:requestID];
    return;
  }
  if (uniqueChannels.count != 1) {
    [self emitConnectionStage:@"sdp.endpoint.ambiguous"
                    requestID:requestID
                 connectionID:connectionID
                        fields:@{
                          @"serviceCount": @(records.count),
                          @"matchingServiceCount": @(matchingServiceCount),
                          @"uniqueRFCOMMChannelCount": @(uniqueChannels.count),
                          @"channels": uniqueChannels.array,
                        }];
    [self endConnectionWithReason:@"error"
                       errorCode:@"rfcomm_channel_ambiguous"
                         message:@"The requested SDP service exposes multiple RFCOMM channels."
                       requestID:requestID];
    return;
  }
  BluetoothRFCOMMChannelID channelID = (BluetoothRFCOMMChannelID)uniqueChannels.firstObject.unsignedCharValue;
  [self emitConnectionStage:@"rfcomm.open.started"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"channel": @(channelID),
                        @"queryKind": @"full",
                        @"completionSource": completionSource,
                        @"timeoutMs": @(kRFCOMMOpenTimeoutMilliseconds),
                      }];
  // Register the request before calling IOBluetooth. Some native callbacks can
  // be delivered re-entrantly while `openRFCOMMChannelAsync:` is still on the
  // stack, before its out parameter becomes visible to this method.
  self.pendingDevice = nil;
  self.pendingServiceUUID = nil;
  self.rfcommOpenPending = YES;
  self.openingGeneration = generation;
  self.openingChannelID = channelID;
  self.openingChannel = nil;
  IOBluetoothRFCOMMChannel *channel = nil;
  [self emitConnectionStage:@"rfcomm.open.invoke.started"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{ @"channel": @(channelID) }];
  IOReturn openStatus = [device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self];
  [self emitConnectionStage:@"rfcomm.open.invoke.returned"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"channel": @(channelID),
                        @"status": @(openStatus),
                        @"statusHex": [NSString stringWithFormat:@"0x%08x", openStatus],
                        @"channelAllocated": @(channel != nil),
                      }];
  if (generation != self.attemptGeneration || ![connectionID isEqualToString:self.activeConnectionID]) {
    if (channel != nil && channel != self.channel) [channel closeChannel];
    return;
  }
  const BOOL requestStillPending =
      self.rfcommOpenPending &&
      self.openingGeneration == generation &&
      self.openingChannelID == channelID;
  if (!requestStillPending) {
    // A re-entrant callback already consumed this request. Do not overwrite
    // its active channel or schedule a timeout for an already completed open.
    if (channel != nil && channel != self.channel) [channel closeChannel];
    return;
  }
  if (openStatus != kIOReturnSuccess) {
    if (channel != nil) [channel closeChannel];
    [self clearRFCOMMOpeningState];
    [self endConnectionWithReason:@"error" errorCode:@"rfcomm_open_start_failed" message:[NSString stringWithFormat:@"Could not start RFCOMM channel %u: 0x%08x", channelID, openStatus] requestID:requestID];
    return;
  }
  // A nil out parameter is not itself proof of failure: the completion callback
  // supplies its own channel object. The generation/channel fence below owns
  // the timeout until that callback arrives.
  self.openingChannel = channel;
  [self scheduleRFCOMMOpenTimeoutForGeneration:generation connectionID:connectionID channelID:channelID];
}

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel status:(IOReturn)status {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self rfcommChannelOpenComplete:rfcommChannel status:status]; }); return; }
  const BOOL belongsToOpeningRequest =
      self.rfcommOpenPending &&
      self.openingGeneration == self.attemptGeneration &&
      self.activeConnectionID != nil &&
      [rfcommChannel getChannelID] == self.openingChannelID &&
      (self.openingChannel == nil || rfcommChannel == self.openingChannel);
  if (!belongsToOpeningRequest) {
    if (status == kIOReturnSuccess) [rfcommChannel closeChannel];
    return;
  }
  NSString *requestID = self.activeConnectRequestID;
  NSString *connectionID = self.activeConnectionID;
  const BluetoothRFCOMMChannelID channelID = self.openingChannelID;
  [self clearRFCOMMOpeningState];
  [self emitConnectionStage:@"rfcomm.open.completed"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"channel": @(channelID),
                        @"status": @(status),
                      }];
  if (status != kIOReturnSuccess) {
    [rfcommChannel closeChannel];
    [self endConnectionWithReason:@"error" errorCode:@"rfcomm_open_failed" message:[NSString stringWithFormat:@"RFCOMM open failed: 0x%08x", status] requestID:requestID];
    return;
  }
  self.channel = rfcommChannel;
  NSUInteger mtu = [rfcommChannel getMTU];
  [self emit:@{ @"event": @"connect.done", @"requestId": requestID, @"connectionId": connectionID, @"address": self.activeAddress, @"addressKey": self.activeAddressKey, @"channel": @([rfcommChannel getChannelID]), @"mtu": @(mtu) }];
}

- (void)write:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *connectionID = command[@"connectionId"];
  if (![connectionID isKindOfClass:NSString.class] || ![connectionID isEqualToString:self.activeConnectionID] || self.channel == nil || self.closing) {
    [self emitError:@"not_connected" message:@"write requires the active, open connectionId." requestID:requestID connectionID:connectionID];
    return;
  }
  NSString *base64 = command[@"base64"];
  if (![base64 isKindOfClass:NSString.class]) {
    [self emitError:@"invalid_write_arguments" message:@"write requires a base64 string." requestID:requestID connectionID:connectionID];
    return;
  }
  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
  if (data == nil) {
    [self emitError:@"invalid_base64" message:@"The write base64 payload is malformed." requestID:requestID connectionID:connectionID];
    return;
  }
  if (data.length > kMaximumWriteBytes) {
    [self emitError:@"write_too_large" message:@"Decoded write payload exceeds 262144 bytes." requestID:requestID connectionID:connectionID];
    return;
  }
  NSUInteger mtu = MIN([self.channel getMTU], (NSUInteger)UINT16_MAX);
  if (data.length > 0 && mtu == 0) {
    [self emitError:@"invalid_mtu" message:@"The RFCOMM channel reported an MTU of zero." requestID:requestID connectionID:connectionID];
    return;
  }
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  for (NSUInteger offset = 0; offset < data.length; offset += mtu) {
    NSUInteger length = MIN(mtu, data.length - offset);
    IOReturn status = [self.channel writeSync:(void *)(bytes + offset) length:(UInt16)length];
    if (status != kIOReturnSuccess) {
      [self emitError:@"write_failed" message:[NSString stringWithFormat:@"RFCOMM write failed at byte %lu: 0x%08x", (unsigned long)offset, status] requestID:requestID connectionID:connectionID];
      return;
    }
  }
  [self emit:@{ @"event": @"write.done", @"requestId": requestID, @"connectionId": connectionID, @"byteCount": @(data.length) }];
}

- (void)disconnect:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *connectionID = command[@"connectionId"];
  if (![connectionID isKindOfClass:NSString.class] || ![connectionID isEqualToString:self.activeConnectionID]) {
    [self emitError:@"connection_mismatch" message:@"disconnect must name the active connectionId." requestID:requestID connectionID:connectionID];
    return;
  }
  if (self.closing) {
    [self emitError:@"disconnect_in_progress" message:@"A disconnect is already in progress." requestID:requestID connectionID:connectionID];
    return;
  }
  self.disconnectRequestID = requestID;
  if (self.channel != nil) {
    self.closing = YES;
    IOReturn status = [self.channel closeChannel];
    if (status != kIOReturnSuccess) {
      [self endConnectionWithReason:@"error" errorCode:@"disconnect_failed" message:[NSString stringWithFormat:@"Could not close RFCOMM channel: 0x%08x", status] requestID:requestID];
    }
    return;
  }
  if (self.rfcommOpenPending || self.openingChannel != nil) {
    // The generation fence in endConnection rejects a late open callback.
    // It also closes any already allocated opening channel.
    [self endConnectionWithReason:@"local" errorCode:nil message:nil requestID:nil];
    return;
  }
  if (self.pendingDevice != nil || self.pendingSDPDelegate != nil) {
    [self movePendingSDPQueryToDrain];
  }
  [self endConnectionWithReason:@"local" errorCode:nil message:nil requestID:nil];
}

- (void)endConnectionWithReason:(NSString *)reason errorCode:(NSString *)errorCode message:(NSString *)message requestID:(NSString *)requestID {
  NSCAssert(NSThread.isMainThread, @"Connection state must run on main thread");
  NSString *connectionID = self.activeConnectionID;
  if (connectionID == nil) return;
  NSString *address = self.activeAddress ?: @"";
  NSString *addressKey = self.activeAddressKey ?: @"";
  NSString *disconnectRequestID = self.disconnectRequestID;
  IOBluetoothRFCOMMChannel *openingChannel = self.openingChannel;
  IOBluetoothRFCOMMChannel *activeChannel = self.channel;
  ++self.attemptGeneration;
  [self invalidateSDPCachePolling];
  self.pendingDevice = nil; self.pendingServiceUUID = nil; self.pendingSDPDelegate = nil; self.channel = nil;
  [self clearRFCOMMOpeningState];
  self.sdpBaselineServicesUpdate = nil; self.sdpQueryStartedAt = nil; self.sdpCacheRefreshObserved = NO;
  self.activeConnectionID = nil; self.activeConnectRequestID = nil; self.activeAddress = nil; self.activeAddressKey = nil;
  self.disconnectRequestID = nil; self.closing = NO;
  if (openingChannel != nil && openingChannel != activeChannel) [openingChannel closeChannel];
  if (activeChannel != nil) [activeChannel closeChannel];
  if (errorCode != nil) [self emitError:errorCode message:message requestID:requestID connectionID:connectionID];
  [self emit:@{
    @"event": @"connection.stage",
    @"stage": @"cleanup.completed",
    @"requestId": requestID ?: disconnectRequestID ?: @"",
    @"connectionId": connectionID,
    @"address": address,
    @"addressKey": addressKey,
    @"reason": reason,
  }];
  [self emit:@{ @"event": @"closed", @"connectionId": connectionID, @"address": address, @"addressKey": addressKey, @"reason": reason }];
  if (disconnectRequestID != nil && ![disconnectRequestID isEqualToString:requestID]) {
    [self emit:@{ @"event": @"disconnect.done", @"requestId": disconnectRequestID, @"connectionId": connectionID }];
  }
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self deviceInquiryDeviceFound:sender device:device]; }); return; }
  if (sender != self.inquiry || self.scanID == nil) return;
  NSDictionary *event = [self deviceEventForDevice:device source:@"inquiry" scanID:self.scanID];
  NSString *addressKey = event[@"addressKey"];
  if (addressKey.length != 0) {
    self.deviceCache[addressKey] = device;
    [self emit:event];
  }
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self deviceInquiryComplete:sender error:error aborted:aborted]; }); return; }
  if (sender != self.inquiry) return;
  NSString *scanID = self.scanID;
  NSString *startRequestID = self.scanRequestID;
  NSString *stopRequestID = self.scanStopRequestID;
  self.inquiry = nil; self.scanID = nil; self.scanRequestID = nil; self.scanStopRequestID = nil;
  NSString *reason = error == kIOReturnSuccess ? (aborted ? @"stopped" : @"completed") : @"failed";
  if (error != kIOReturnSuccess) [self emitError:@"scan_failed" message:[NSString stringWithFormat:@"Bluetooth inquiry ended with error: 0x%08x", error] requestID:startRequestID connectionID:nil];
  if (stopRequestID != nil) {
    [self emit:@{ @"event": @"scan.stop.done", @"requestId": stopRequestID, @"scanId": scanID ?: @"" }];
  }
  [self emit:@{ @"event": @"scan.finished", @"scanId": scanID ?: @"", @"reason": reason }];
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel data:(void *)dataPointer length:(size_t)dataLength {
  NSData *data = [NSData dataWithBytes:dataPointer length:dataLength];
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self rfcommChannelData:rfcommChannel data:(void *)data.bytes length:data.length]; }); return; }
  if (rfcommChannel != self.channel || self.activeConnectionID == nil || self.closing) return;
  [self emit:@{ @"event": @"data", @"connectionId": self.activeConnectionID, @"base64": [data base64EncodedStringWithOptions:0] }];
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)rfcommChannel {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self rfcommChannelClosed:rfcommChannel]; }); return; }
  if (rfcommChannel != self.channel) return;
  self.channel = nil;
  [self endConnectionWithReason:self.closing ? @"local" : @"remote" errorCode:nil message:nil requestID:nil];
}

- (void)shutdownForEOF {
  NSCAssert(NSThread.isMainThread, @"EOF shutdown must run on main thread");
  [self invalidateSDPCachePolling];
  if (self.inquiry != nil) [self.inquiry stop];
  IOBluetoothRFCOMMChannel *openingChannel = self.openingChannel;
  IOBluetoothRFCOMMChannel *activeChannel = self.channel;
  self.channel = nil;
  [self clearRFCOMMOpeningState];
  self.serialProbeInFlight = NO;
  self.serialProbeRequestID = nil;
  ++self.attemptGeneration;
  if (openingChannel != nil && openingChannel != activeChannel) [openingChannel closeChannel];
  if (activeChannel != nil) [activeChannel closeChannel];
}

@end

@implementation WearableSDPQueryDelegate

- (instancetype)initWithBridge:(WearableBluetoothBridge *)bridge
                     generation:(uint64_t)generation {
  self = [super init];
  if (self != nil) {
    _bridge = bridge;
    _generation = generation;
  }
  return self;
}

- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
  if (!NSThread.isMainThread) {
    __weak WearableSDPQueryDelegate *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf sdpQueryComplete:device status:status];
    });
    return;
  }
  [self.bridge handleSDPCallbackForDevice:device
                                   status:status
                               generation:self.generation
                                 delegate:self];
}

@end

static void HandleLine(WearableBluetoothBridge *bridge, const std::string &line) {
  @autoreleasepool {
    NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:NSDictionary.class]) {
      [bridge emitError:@"invalid_json" message:error.localizedDescription ?: @"Each input line must be a JSON object." requestID:nil connectionID:nil];
      return;
    }
    [bridge handleCommand:object];
  }
}

int main(void) {
  @autoreleasepool {
    WearableBluetoothBridge *bridge = [[WearableBluetoothBridge alloc] init];
    std::thread input([bridge] {
      std::string line;
      while (std::getline(std::cin, line)) {
        std::string inputLine = line;
        dispatch_async(dispatch_get_main_queue(), ^{ HandleLine(bridge, inputLine); });
      }
      dispatch_async(dispatch_get_main_queue(), ^{ [bridge shutdownForEOF]; CFRunLoopStop(CFRunLoopGetMain()); });
    });
    input.detach();
    CFRunLoopRun();
  }
  return 0;
}
