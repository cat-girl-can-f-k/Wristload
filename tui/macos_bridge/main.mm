#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>

#import "identity_name_match.h"

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
static const NSUInteger kMaximumTransportDiagnosticHexBytes = 4096;
static const NSUInteger kVersionProbePayloadBytes = 11;
// GUI allows a 30 s native connect window. Keep the standalone TUI diagnostic
// window above that boundary so a missing terminal delegate callback is not
// misclassified as a shorter, TUI-only timeout.
static const int64_t kSDPTimeoutMilliseconds = 35000;
static const int64_t kRFCOMMOpenTimeoutMilliseconds = 15000;
static const int64_t kRFCOMMCloseTimeoutMilliseconds = 15000;
static const int64_t kSDPDrainQuarantineMilliseconds = 30000;
static const NSTimeInterval kSDPCachePollIntervalSeconds = 0.35;
static NSString *const kTuiIdentityMappingsDefaultsKey = @"WristloadTuiClassicIdentityMappings.v1";

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

static int64_t UnixMillisecondsNow(void) {
  return (int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
}

static NSDictionary<NSString *, id> *NativeStatusFields(NSString *domain, NSNumber *code) {
  if (domain == nil && code == nil) return @{};
  NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionary];
  if (domain != nil) fields[@"nativeDomain"] = domain;
  if (code != nil) {
    fields[@"nativeCode"] = code;
    fields[@"nativeStatusHex"] = [NSString stringWithFormat:@"0x%08x", code.unsignedIntValue];
  }
  return fields;
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

/// A query tombstone intentionally outlives its logical connection. IOBluetooth
/// offers no SDP cancellation or acknowledgement that it released the callback
/// target, so a callback that arrives after a cache-based fallback or timeout
/// must still land on its original delegate instead of a deallocated object.
/// Tombstones are retained for the helper process lifetime.
@interface WearableRetiredSDPQuery : NSObject
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) WearableSDPQueryDelegate *delegate;
@property(nonatomic, copy) NSString *addressKey;
@property(nonatomic, copy) NSString *connectionID;
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, assign) uint64_t generation;
@end

@implementation WearableRetiredSDPQuery
@end

@interface WearableClassicPairingOperation : NSObject
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *pairingID;
@property(nonatomic, copy) NSString *candidateID;
@property(nonatomic, copy) NSString *advertisedName;
@property(nonatomic, copy) NSString *addressKey;
@property(nonatomic, assign) uint64_t generation;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, strong) NSTimer *timeout;
@property(nonatomic, assign) BOOL completed;
@property(nonatomic, assign) BOOL directedExactAddress;
@end

@implementation WearableClassicPairingOperation
@end

@interface WearableClassicPairingAttempt : NSObject <IOBluetoothDevicePairDelegate>
@property(nonatomic, weak) WearableBluetoothBridge *bridge;
@property(nonatomic, weak) WearableClassicPairingOperation *operation;
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) IOBluetoothDevicePair *pair;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, strong) NSAlert *activePrompt;
@property(nonatomic, assign) BOOL pairingStartReturned;
@property(nonatomic, assign) IOReturn pairingStartStatus;
- (instancetype)initWithBridge:(WearableBluetoothBridge *)bridge
                     operation:(WearableClassicPairingOperation *)operation
                        device:(IOBluetoothDevice *)device;
- (void)start;
- (void)cancel;
- (void)dispatchPairingCallbackStage:(NSString *)stage
                       nativeStage:(NSString *)nativeStage
                            sender:(id)sender
                           message:(NSString *)message
                      nativeDomain:(NSString *)nativeDomain
                        nativeCode:(NSNumber *)nativeCode
                            action:(void (^)(WearableClassicPairingAttempt *attempt))action;
- (void)emitStage:(NSString *)stage
          message:(NSString *)message
     nativeDomain:(NSString *)domain
       nativeCode:(NSNumber *)code
       nativeStage:(NSString *)nativeStage;
- (NSDictionary<NSString *, id> *)diagnosticSnapshot;
- (void)dismissActivePrompt;
- (void)prepareApplicationForPrompt;
@end

@interface WearableBluetoothBridge : NSObject <IOBluetoothDeviceInquiryDelegate, IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, strong) IOBluetoothDeviceInquiry *inquiry;
@property(nonatomic, copy) NSString *scanID;
@property(nonatomic, copy) NSString *scanRequestID;
@property(nonatomic, copy) NSString *scanStopRequestID;

@property(nonatomic, strong) IOBluetoothDevice *pendingDevice;
@property(nonatomic, strong) IOBluetoothSDPUUID *pendingServiceUUID;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *openingChannel;
@property(nonatomic, strong) IOBluetoothDevice *openingDevice;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) NSMutableDictionary<NSString *, IOBluetoothDevice *> *deviceCache;
@property(nonatomic, copy) NSString *activeConnectionID;
@property(nonatomic, copy) NSString *activeConnectRequestID;
@property(nonatomic, copy) NSString *activeAddress;
@property(nonatomic, copy) NSString *activeAddressKey;
@property(nonatomic, copy) NSString *activeServiceUUID;
@property(nonatomic, copy) NSString *activeLookupSource;
@property(nonatomic, copy) NSString *activeEndpoint;
@property(nonatomic, copy) NSString *activeDeviceName;
@property(nonatomic, copy) NSString *activeServiceName;
@property(nonatomic, assign) BluetoothRFCOMMChannelID activeRFCOMMChannelID;
@property(nonatomic, assign) NSInteger activeServiceRecordIndex;
@property(nonatomic, assign) uint64_t activeConnectionGeneration;
@property(nonatomic, assign) BOOL activeDevicePaired;
@property(nonatomic, assign) BOOL activeDeviceBasebandConnected;
@property(nonatomic, assign) BOOL activePairingKnown;
@property(nonatomic, assign) BOOL activeBasebandKnown;
@property(nonatomic, copy) NSString *disconnectRequestID;
@property(nonatomic, assign) uint64_t attemptGeneration;
@property(nonatomic, assign) uint64_t openingGeneration;
@property(nonatomic, assign) BOOL rfcommOpenPending;
@property(nonatomic, assign) BluetoothRFCOMMChannelID openingChannelID;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *closingChannel;
@property(nonatomic, assign) uint64_t closingGeneration;
@property(nonatomic, assign) BluetoothRFCOMMChannelID closingChannelID;
@property(nonatomic, strong) WearableSDPQueryDelegate *pendingSDPDelegate;
@property(nonatomic, strong) NSTimer *sdpCachePollTimer;
@property(nonatomic, assign) uint64_t sdpCachePollGeneration;
@property(nonatomic, copy) NSString *sdpCachePollConnectionID;
@property(nonatomic, strong) NSDate *sdpBaselineServicesUpdate;
@property(nonatomic, strong) NSDate *sdpQueryStartedAt;
@property(nonatomic, assign) BOOL sdpCacheRefreshObserved;
@property(nonatomic, strong) IOBluetoothDevice *sdpDrainDevice;
@property(nonatomic, copy) NSString *sdpDrainAddressKey;
@property(nonatomic, copy) NSString *sdpDrainConnectionID;
@property(nonatomic, copy) NSString *sdpDrainRequestID;
@property(nonatomic, strong) WearableSDPQueryDelegate *sdpDrainDelegate;
@property(nonatomic, assign) uint64_t sdpDrainGeneration;
@property(nonatomic, assign) BOOL sdpDrainPending;
@property(nonatomic, strong) NSDate *sdpDrainDeadline;
@property(nonatomic, strong) NSMutableArray<WearableRetiredSDPQuery *> *retiredSDPQueries;
@property(nonatomic, assign) BOOL serialProbeInFlight;
@property(nonatomic, copy) NSString *serialProbeRequestID;
@property(nonatomic, copy) NSString *helperSessionID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *confirmedIdentityMappings;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *provisionalIdentityMappings;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *identityCandidateCache;
@property(nonatomic, strong) WearableClassicPairingOperation *pairingOperation;
@property(nonatomic, strong) WearableClassicPairingAttempt *pairingAttempt;
@property(nonatomic, assign) uint64_t identityGeneration;
@property(nonatomic, copy) NSString *activeCandidateID;
@property(nonatomic, copy) NSString *activeIdentityState;

- (void)completeSDPQueryForDevice:(IOBluetoothDevice *)device
                            status:(IOReturn)status
                        generation:(uint64_t)generation
                  completionSource:(NSString *)completionSource
                 completionDelegate:(WearableSDPQueryDelegate *)completionDelegate;
- (void)handleSDPCallbackForDevice:(IOBluetoothDevice *)device
                             status:(IOReturn)status
                         generation:(uint64_t)generation
                           delegate:(WearableSDPQueryDelegate *)delegate;
- (void)recordSDPCallbackEntryForDevice:(IOBluetoothDevice *)device
                                  status:(IOReturn)status
                              generation:(uint64_t)generation
                                delegate:(WearableSDPQueryDelegate *)delegate
                         callbackThread:(NSString *)callbackThread
                        callbackAtMillis:(int64_t)callbackAtMillis;
- (void)beginConnectionWithDevice:(IOBluetoothDevice *)device
                         requestID:(NSString *)requestID
                      connectionID:(NSString *)connectionID
                               key:(NSString *)key
                            address:(NSString *)address
                         apiAddress:(NSString *)apiAddress
                        serviceUUID:(IOBluetoothSDPUUID *)serviceUUID
              requestedServiceUUID:(NSString *)requestedServiceUUID
                       lookupSource:(NSString *)lookupSource
                        candidateID:(NSString *)candidateID
                     identityState:(NSString *)identityState;
- (void)clearRFCOMMOpeningState;
- (void)clearRFCOMMClosingState;
- (void)scheduleRFCOMMCloseTimeoutForGeneration:(uint64_t)generation
                                   connectionID:(NSString *)connectionID
                                     channelID:(BluetoothRFCOMMChannelID)channelID
                                        channel:(IOBluetoothRFCOMMChannel *)channel;
- (void)serialProbe:(NSDictionary *)command requestID:(NSString *)requestID;
- (void)endConnectionWithReason:(NSString *)reason
                      errorCode:(NSString *)errorCode
                        message:(NSString *)message
                      requestID:(NSString *)requestID;
- (void)endConnectionWithReason:(NSString *)reason
                      errorCode:(NSString *)errorCode
                        message:(NSString *)message
                      requestID:(NSString *)requestID
                    nativeDomain:(NSString *)nativeDomain
                      nativeCode:(NSNumber *)nativeCode;
- (void)emitError:(NSString *)code
           message:(NSString *)message
         requestID:(NSString *)requestID
      connectionID:(NSString *)connectionID
         metadata:(NSDictionary<NSString *, id> *)metadata
      nativeDomain:(NSString *)nativeDomain
        nativeCode:(NSNumber *)nativeCode;
- (void)expireSDPDrainIfNeeded;
- (void)scheduleSDPDrainExpiry;
- (void)retireSDPDrainWithKind:(NSString *)kind;
- (BOOL)retirePendingSDPQueryToTombstoneWithKind:(NSString *)kind;
- (void)emitPairingStage:(NSString *)stage
                operation:(WearableClassicPairingOperation *)operation
                  message:(NSString *)message
             nativeDomain:(NSString *)nativeDomain
               nativeCode:(NSNumber *)nativeCode;
- (void)emitPairingStage:(NSString *)stage
                operation:(WearableClassicPairingOperation *)operation
                  message:(NSString *)message
             nativeDomain:(NSString *)nativeDomain
               nativeCode:(NSNumber *)nativeCode
                  details:(NSDictionary<NSString *, id> *)details;
- (void)completePairingOperation:(WearableClassicPairingOperation *)operation
                         device:(IOBluetoothDevice *)device
                    matchMode:(NSString *)matchMode
                     source:(NSString *)source;
- (void)failPairingOperation:(WearableClassicPairingOperation *)operation
                         code:(NSString *)code
                      message:(NSString *)message
                 nativeDomain:(NSString *)nativeDomain
                   nativeCode:(NSNumber *)nativeCode
                        stage:(NSString *)stage;
- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
            emitStage:(NSString *)stage
               message:(NSString *)message
          nativeDomain:(NSString *)nativeDomain
            nativeCode:(NSNumber *)nativeCode;
- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
            emitStage:(NSString *)stage
               message:(NSString *)message
          nativeDomain:(NSString *)nativeDomain
            nativeCode:(NSNumber *)nativeCode
           nativeStage:(NSString *)nativeStage
        callbackThread:(NSString *)callbackThread
   callbackTimestampMs:(NSNumber *)callbackTimestampMs
    senderMatchesPair:(NSNumber *)senderMatchesPair;
- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
       didFinishDevice:(IOBluetoothDevice *)device
                status:(IOReturn)status;
- (void)startPairing:(NSDictionary *)command requestID:(NSString *)requestID;
- (void)cancelPairing:(NSDictionary *)command requestID:(NSString *)requestID;
- (void)confirmIdentity:(NSDictionary *)command requestID:(NSString *)requestID;
- (void)forgetIdentity:(NSDictionary *)command requestID:(NSString *)requestID;
- (void)resolveIdentity:(NSDictionary *)command requestID:(NSString *)requestID;
@end

@implementation WearableBluetoothBridge

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _helperSessionID = NSUUID.UUID.UUIDString;
    _deviceCache = [NSMutableDictionary dictionary];
    _retiredSDPQueries = [NSMutableArray array];
    _activeServiceRecordIndex = NSNotFound;
    _provisionalIdentityMappings = [NSMutableDictionary dictionary];
    _identityCandidateCache = [NSMutableDictionary dictionary];
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kTuiIdentityMappingsDefaultsKey];
    _confirmedIdentityMappings = [stored isKindOfClass:NSDictionary.class]
        ? [(NSDictionary *)stored mutableCopy]
        : [NSMutableDictionary dictionary];
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

- (void)addActiveConnectionMetadataToEvent:(NSMutableDictionary<NSString *, id> *)event
                              connectionID:(NSString *)connectionID {
  if (connectionID == nil || ![connectionID isEqualToString:self.activeConnectionID]) return;
  [event addEntriesFromDictionary:[self activeConnectionMetadataSnapshot]];
}

- (NSDictionary<NSString *, id> *)activeConnectionMetadataSnapshot {
  NSMutableDictionary<NSString *, id> *metadata = [@{
    @"transport": @"classic-rfcomm",
    @"generation": @(self.activeConnectionGeneration),
    @"attemptGeneration": @(self.activeConnectionGeneration),
    @"pairingState": self.activePairingKnown
        ? (self.activeDevicePaired ? @"paired" : @"unpaired")
        : @"unknown",
  } mutableCopy];
  if (self.activeEndpoint != nil) metadata[@"endpoint"] = self.activeEndpoint;
  if (self.activeServiceUUID != nil) metadata[@"serviceUuid"] = self.activeServiceUUID;
  if (self.activeLookupSource != nil) metadata[@"lookupSource"] = self.activeLookupSource;
  if (self.activeDeviceName != nil) metadata[@"deviceName"] = self.activeDeviceName;
  if (self.activeServiceName != nil) metadata[@"serviceName"] = self.activeServiceName;
  if (self.activeServiceRecordIndex != NSNotFound) {
    metadata[@"serviceRecordIndex"] = @(self.activeServiceRecordIndex);
  }
  if (self.activePairingKnown) metadata[@"paired"] = @(self.activeDevicePaired);
  if (self.activeBasebandKnown) metadata[@"basebandConnected"] = @(self.activeDeviceBasebandConnected);
  if (self.activeRFCOMMChannelID != 0) metadata[@"channel"] = @(self.activeRFCOMMChannelID);
  if (self.activeCandidateID != nil) metadata[@"candidateId"] = self.activeCandidateID;
  if (self.activeIdentityState != nil) metadata[@"identityState"] = self.activeIdentityState;
  return metadata;
}

- (void)emitError:(NSString *)code
           message:(NSString *)message
         requestID:(NSString *)requestID
      connectionID:(NSString *)connectionID {
  [self emitError:code
           message:message
         requestID:requestID
      connectionID:connectionID
      nativeDomain:nil
        nativeCode:nil];
}

- (void)emitError:(NSString *)code
           message:(NSString *)message
         requestID:(NSString *)requestID
      connectionID:(NSString *)connectionID
      nativeDomain:(NSString *)nativeDomain
        nativeCode:(NSNumber *)nativeCode {
  [self emitError:code
           message:message
         requestID:requestID
      connectionID:connectionID
         metadata:nil
      nativeDomain:nativeDomain
        nativeCode:nativeCode];
}

- (void)emitError:(NSString *)code
           message:(NSString *)message
         requestID:(NSString *)requestID
      connectionID:(NSString *)connectionID
         metadata:(NSDictionary<NSString *, id> *)metadata
      nativeDomain:(NSString *)nativeDomain
        nativeCode:(NSNumber *)nativeCode {
  NSMutableDictionary<NSString *, id> *event = [@{
    @"event": @"error",
    @"code": code ?: @"native_error",
    @"message": message ?: @"Native Bluetooth operation failed.",
    @"timestampMs": @(UnixMillisecondsNow()),
  } mutableCopy];
  if (requestID != nil) event[@"requestId"] = requestID;
  if (connectionID != nil) event[@"connectionId"] = connectionID;
  if (metadata != nil) {
    [event addEntriesFromDictionary:metadata];
  } else if (connectionID != nil && [connectionID isEqualToString:self.activeConnectionID]) {
    if (self.activeAddress != nil) event[@"address"] = self.activeAddress;
    if (self.activeAddressKey != nil) event[@"addressKey"] = self.activeAddressKey;
    [self addActiveConnectionMetadataToEvent:event connectionID:connectionID];
  }
  [event addEntriesFromDictionary:NativeStatusFields(nativeDomain, nativeCode)];
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
    @"timestampMs": @(UnixMillisecondsNow()),
  } mutableCopy];
  if (requestID != nil) event[@"requestId"] = requestID;
  [event addEntriesFromDictionary:fields ?: @{}];
  if (self.activeAddress != nil) event[@"address"] = self.activeAddress;
  if (self.activeAddressKey != nil) event[@"addressKey"] = self.activeAddressKey;
  [self addActiveConnectionMetadataToEvent:event connectionID:connectionID];
  [self emit:event];
}

- (void)emitConnectionDiagnostic:(NSString *)kind
                       requestID:(NSString *)requestID
                    connectionID:(NSString *)connectionID
                          fields:(NSDictionary<NSString *, id> *)fields {
  NSMutableDictionary<NSString *, id> *event = [@{
    @"event": @"connection.diagnostic",
    @"kind": kind ?: @"native.diagnostic",
    @"connectionId": connectionID ?: @"",
    @"timestampMs": @(UnixMillisecondsNow()),
  } mutableCopy];
  if (requestID != nil) event[@"requestId"] = requestID;
  if (self.activeAddress != nil &&
      (connectionID == nil || [connectionID isEqualToString:self.activeConnectionID])) {
    event[@"address"] = self.activeAddress;
  }
  if (self.activeAddressKey != nil &&
      (connectionID == nil || [connectionID isEqualToString:self.activeConnectionID])) {
    event[@"addressKey"] = self.activeAddressKey;
  }
  [event addEntriesFromDictionary:fields ?: @{}];
  [self addActiveConnectionMetadataToEvent:event connectionID:connectionID];
  [self emit:event];
}

- (void)recordSDPCallbackEntryForDevice:(IOBluetoothDevice *)device
                                  status:(IOReturn)status
                              generation:(uint64_t)generation
                                delegate:(WearableSDPQueryDelegate *)delegate
                         callbackThread:(NSString *)callbackThread
                        callbackAtMillis:(int64_t)callbackAtMillis {
  void (^recordBlock)(void) = ^{
    NSString *rawAddress = device.addressString ?: @"";
    NSString *addressKey = [self addressKeyFromString:rawAddress] ?: @"";
    NSString *address = ColonAddressForKey(addressKey) ?: rawAddress;
    NSString *connectionID = @"";
    NSString *requestID = nil;
    NSString *disposition = @"unmatched";
    uint64_t expectedGeneration = self.attemptGeneration;
    if (delegate == self.pendingSDPDelegate &&
        generation == self.attemptGeneration &&
        device == self.pendingDevice) {
      connectionID = self.activeConnectionID ?: @"";
      requestID = self.activeConnectRequestID;
      disposition = @"active_pending";
    } else if (self.sdpDrainPending &&
               delegate == self.sdpDrainDelegate &&
               generation == self.sdpDrainGeneration &&
               device == self.sdpDrainDevice) {
      connectionID = self.sdpDrainConnectionID ?: @"";
      requestID = self.sdpDrainRequestID;
      disposition = @"drain_pending";
    } else {
      for (WearableRetiredSDPQuery *retired in self.retiredSDPQueries) {
        if (delegate != retired.delegate || generation != retired.generation ||
            device != retired.device) continue;
        connectionID = retired.connectionID ?: @"";
        requestID = retired.requestID;
        disposition = @"retired";
        break;
      }
    }
    [self emitConnectionDiagnostic:@"sdp.callback.entered"
                         requestID:requestID
                      connectionID:connectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": address,
                              @"addressKey": addressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"callbackThread": callbackThread ?: @"unknown",
                              @"callbackTimestampMs": @(callbackAtMillis),
                              @"callbackAddress": address,
                              @"callbackAddressKey": addressKey,
                              @"callbackGeneration": @(generation),
                              @"expectedGeneration": @(expectedGeneration),
                              @"callbackDisposition": disposition,
                              @"status": @(status),
                              @"nativeDomain": @"IOReturn",
                              @"nativeCode": @((int32_t)status),
                              @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
                            }];
  };
  if (NSThread.isMainThread) {
    recordBlock();
  } else {
    // Capture tuple ownership synchronously on the bridge main-thread state
    // queue while preserving the native callback timestamp and thread.
    dispatch_sync(dispatch_get_main_queue(), recordBlock);
  }
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
  // With no pre-query cache, accept only a contemporaneous refresh. The GUI
  // backend uses this exact cache transition as a guarded fallback when the
  // SDK never delivers its terminal callback. Its inferred nature remains
  // explicit in the completion diagnostics.
  return self.sdpQueryStartedAt != nil &&
      lastUpdate.timeIntervalSince1970 >= self.sdpQueryStartedAt.timeIntervalSince1970 - 1.0;
}

- (void)invalidateSDPCachePolling {
  [self.sdpCachePollTimer invalidate];
  self.sdpCachePollTimer = nil;
  self.sdpCachePollGeneration = 0;
  self.sdpCachePollConnectionID = nil;
}

- (BOOL)retirePendingSDPQueryToTombstoneWithKind:(NSString *)kind {
  WearableSDPQueryDelegate *delegate = self.pendingSDPDelegate;
  IOBluetoothDevice *device = self.pendingDevice;
  if (delegate == nil || device == nil ||
      delegate.generation != self.attemptGeneration ||
      self.activeConnectionID == nil || self.activeAddressKey == nil) {
    return NO;
  }
  WearableRetiredSDPQuery *retired = [[WearableRetiredSDPQuery alloc] init];
  retired.device = device;
  retired.delegate = delegate;
  retired.addressKey = self.activeAddressKey;
  retired.connectionID = self.activeConnectionID;
  retired.requestID = self.activeConnectRequestID;
  retired.generation = delegate.generation;
  [self.retiredSDPQueries addObject:retired];
  self.pendingSDPDelegate = nil;
  [self emitConnectionDiagnostic:kind
                       requestID:retired.requestID
                    connectionID:retired.connectionID
                          fields:@{
                            @"transport": @"classic-rfcomm",
                            @"address": ColonAddressForKey(retired.addressKey) ?: @"",
                            @"addressKey": retired.addressKey,
                            @"generation": @(retired.generation),
                            @"callbackDisposition": @"tombstoned",
                          }];
  return YES;
}

- (void)movePendingSDPQueryToDrain {
  if (self.pendingDevice == nil || self.pendingSDPDelegate == nil) return;
  if (self.sdpDrainPending) [self retireSDPDrainWithKind:@"sdp.drain.superseded"];
  self.sdpDrainDevice = self.pendingDevice;
  self.sdpDrainAddressKey = self.activeAddressKey;
  self.sdpDrainConnectionID = self.activeConnectionID;
  self.sdpDrainRequestID = self.activeConnectRequestID;
  self.sdpDrainDelegate = self.pendingSDPDelegate;
  self.sdpDrainGeneration = self.pendingSDPDelegate.generation;
  self.sdpDrainPending = YES;
  self.sdpDrainDeadline = [NSDate dateWithTimeIntervalSinceNow:
      (NSTimeInterval)kSDPDrainQuarantineMilliseconds / 1000.0];
  self.pendingSDPDelegate = nil;
  [self scheduleSDPDrainExpiry];
}

- (void)clearSDPDrain {
  self.sdpDrainPending = NO;
  self.sdpDrainDevice = nil;
  self.sdpDrainAddressKey = nil;
  self.sdpDrainConnectionID = nil;
  self.sdpDrainRequestID = nil;
  self.sdpDrainDelegate = nil;
  self.sdpDrainGeneration = 0;
  self.sdpDrainDeadline = nil;
}

- (void)retireSDPDrainWithKind:(NSString *)kind {
  if (!self.sdpDrainPending) return;
  WearableSDPQueryDelegate *delegate = self.sdpDrainDelegate;
  IOBluetoothDevice *device = self.sdpDrainDevice;
  NSString *addressKey = self.sdpDrainAddressKey ?: @"";
  NSString *connectionID = self.sdpDrainConnectionID ?: @"";
  NSString *requestID = self.sdpDrainRequestID;
  const uint64_t generation = self.sdpDrainGeneration;
  NSNumber *deadlineMs = [self millisecondsFieldForDate:self.sdpDrainDeadline];
  if (delegate != nil && device != nil) {
    WearableRetiredSDPQuery *retired = [[WearableRetiredSDPQuery alloc] init];
    retired.device = device;
    retired.delegate = delegate;
    retired.addressKey = addressKey;
    retired.connectionID = connectionID;
    retired.requestID = requestID;
    retired.generation = generation;
    [self.retiredSDPQueries addObject:retired];
  }
  [self clearSDPDrain];
  [self emitConnectionDiagnostic:kind
                       requestID:requestID
                    connectionID:connectionID
                          fields:@{
                            @"transport": @"classic-rfcomm",
                            @"address": ColonAddressForKey(addressKey) ?: @"",
                            @"addressKey": addressKey,
                            @"generation": @(generation),
                            @"deadlineMillis": deadlineMs,
                            @"callbackDisposition": @"quarantined",
                          }];
}

- (void)expireSDPDrainIfNeeded {
  if (!self.sdpDrainPending || self.sdpDrainDeadline == nil ||
      self.sdpDrainDeadline.timeIntervalSinceNow > 0) return;
  [self retireSDPDrainWithKind:@"sdp.drain.expired"];
}

- (void)scheduleSDPDrainExpiry {
  WearableSDPQueryDelegate *delegate = self.sdpDrainDelegate;
  const uint64_t generation = self.sdpDrainGeneration;
  NSDate *deadline = self.sdpDrainDeadline;
  if (delegate == nil || deadline == nil) return;
  __weak WearableBluetoothBridge *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kSDPDrainQuarantineMilliseconds * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        WearableBluetoothBridge *strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.sdpDrainPending ||
            strongSelf.sdpDrainDelegate != delegate ||
            strongSelf.sdpDrainGeneration != generation ||
            strongSelf.sdpDrainDeadline != deadline) return;
        [strongSelf expireSDPDrainIfNeeded];
      });
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
    // IOBluetooth does not always deliver sdpQueryComplete: even though its
    // service cache was refreshed for this exact request. Mirror the GUI
    // fallback, but retain the original callback target for process lifetime:
    // there is no cancellation API or acknowledgement that native code has
    // stopped retaining it. This must not use the temporary drain because that
    // intentionally blocks a same-device reconnect.
    WearableSDPQueryDelegate *completionDelegate = strongSelf.pendingSDPDelegate;
    if (completionDelegate == nil ||
        ![strongSelf retirePendingSDPQueryToTombstoneWithKind:@"sdp.cache_fallback.tombstone"]) {
      [strongSelf emitConnectionDiagnostic:@"sdp.cache_fallback.rejected"
                               requestID:strongSelf.activeConnectRequestID
                            connectionID:connectionID
                                  fields:@{
                                    @"transport": @"classic-rfcomm",
                                    @"completionSource": @"cache_poll",
                                    @"reason": @"tombstone_retain_failed",
                                    @"generation": @(generation),
                                    @"delegateCallbackObserved": @NO,
                                  }];
      return;
    }
    [strongSelf completeSDPQueryForDevice:device
                                   status:kIOReturnSuccess
                               generation:generation
                         completionSource:@"cache_poll"
                        completionDelegate:completionDelegate];
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
                             message:@"SDP query did not deliver its terminal callback within 35000 ms."
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
                              @"nativeDomain": @"IOReturn",
                              @"nativeCode": @((int32_t)kIOReturnTimeout),
                              @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", kIOReturnTimeout],
                            }];
        [self endConnectionWithReason:@"error"
                           errorCode:@"rfcomm_open_timeout"
                             message:@"RFCOMM channel open did not deliver its terminal callback within 15000 ms."
                           requestID:self.activeConnectRequestID
                     nativeDomain:@"IOReturn"
                       nativeCode:@((int32_t)kIOReturnTimeout)];
      });
}

- (void)clearRFCOMMOpeningState {
  self.rfcommOpenPending = NO;
  self.openingGeneration = 0;
  self.openingChannelID = 0;
  self.openingChannel = nil;
  self.openingDevice = nil;
}

- (void)clearRFCOMMClosingState {
  self.closing = NO;
  self.closingChannel = nil;
  self.closingGeneration = 0;
  self.closingChannelID = 0;
}

- (void)scheduleRFCOMMCloseTimeoutForGeneration:(uint64_t)generation
                                   connectionID:(NSString *)connectionID
                                     channelID:(BluetoothRFCOMMChannelID)channelID
                                        channel:(IOBluetoothRFCOMMChannel *)channel {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kRFCOMMCloseTimeoutMilliseconds * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        if (generation != self.attemptGeneration ||
            ![connectionID isEqualToString:self.activeConnectionID] ||
            !self.closing ||
            self.closingGeneration != generation ||
            self.closingChannelID != channelID ||
            self.closingChannel != channel ||
            self.channel != channel) return;
        [self emitConnectionStage:@"rfcomm.close.timeout"
                        requestID:self.disconnectRequestID
                     connectionID:connectionID
                          fields:@{
                            @"channel": @(channelID),
                            @"timeoutMs": @(kRFCOMMCloseTimeoutMilliseconds),
                            @"nativeDomain": @"IOReturn",
                            @"nativeCode": @((int32_t)kIOReturnTimeout),
                            @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", kIOReturnTimeout],
                          }];
        [self endConnectionWithReason:@"error"
                           errorCode:@"rfcomm_close_timeout"
                             message:@"RFCOMM close did not deliver its terminal callback within 15000 ms."
                           requestID:self.disconnectRequestID
                     nativeDomain:@"IOReturn"
                       nativeCode:@((int32_t)kIOReturnTimeout)];
      });
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

// Identity matching accepts exact names plus a strict four-hex instance suffix
// on either BLE or Classic names; address validation remains authoritative.
- (NSString *)canonicalIdentityName:(NSString *)value {
  return WearableCanonicalIdentityName(value);
}

- (NSString *)classicDisplayName:(IOBluetoothDevice *)device {
  if (device == nil) return @"";
  NSString *name = device.name;
  if (![name isKindOfClass:NSString.class] || name.length == 0) name = device.nameOrAddress;
  return [name isKindOfClass:NSString.class] ? name : @"";
}

- (NSString *)identityNameMatchMode:(NSString *)advertised classic:(NSString *)classic {
  return WearableIdentityNameMatchMode(advertised, classic);
}

- (BOOL)candidateAllowsDirectedExactAddress:(NSDictionary *)candidate
                                  addressKey:(NSString *)addressKey {
  if (![candidate isKindOfClass:NSDictionary.class] ||
      ![addressKey isKindOfClass:NSString.class]) return NO;
  NSString *candidateKey = [self addressKeyFromString:candidate[@"addressKey"] ?: candidate[@"address"]];
  return [candidate[@"directedExactAddress"] isKindOfClass:NSNumber.class] &&
      [candidate[@"directedExactAddress"] boolValue] &&
      [candidateKey isEqualToString:addressKey];
}

- (NSString *)identityNameMatchModeForDevice:(IOBluetoothDevice *)device
                                  advertised:(NSString *)advertised
                              expectedAddress:(NSString *)expectedAddressKey
                          directedExactAddress:(BOOL)directedExactAddress {
  if (device == nil || expectedAddressKey == nil) return nil;
  return WearableIdentityDeviceMatchMode(advertised, device.name, device.nameOrAddress,
                                         [self displayAddressForKey:expectedAddressKey],
                                         directedExactAddress);
}

- (NSDictionary *)identityCandidate:(NSString *)candidateID {
  NSDictionary *candidate = self.identityCandidateCache[candidateID];
  return [candidate isKindOfClass:NSDictionary.class] ? candidate : nil;
}

- (IOBluetoothDevice *)directDeviceForIdentity:(NSString *)addressKey {
  NSString *address = [self displayAddressForKey:addressKey];
  if (address == nil) return nil;
  IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:
      [address stringByReplacingOccurrencesOfString:@"-" withString:@":"]];
  NSString *resolved = [self addressKeyFromString:device.addressString];
  if (device != nil && [resolved isEqualToString:addressKey]) {
    self.deviceCache[addressKey] = device;
    return device;
  }
  return nil;
}

- (void)resolveIdentity:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *candidateID = command[@"candidateId"];
  NSString *advertised = command[@"advertisedName"];
  // Every new resolve is a new authorization transaction. Revoke a previous
  // exact-address exception before validating the rest of this request so a
  // malformed or stricter follow-up cannot leave a stale pairing grant usable.
  NSDictionary *cachedCandidate = [candidateID isKindOfClass:NSString.class] ? [self identityCandidate:candidateID] : nil;
  if ([cachedCandidate[@"directedExactAddress"] boolValue]) {
    NSMutableDictionary *revokedCandidate = [cachedCandidate mutableCopy];
    [revokedCandidate removeObjectForKey:@"directedExactAddress"];
    self.identityCandidateCache[candidateID] = revokedCandidate;
  }
  if (![candidateID isKindOfClass:NSString.class] || candidateID.length == 0 ||
      ![advertised isKindOfClass:NSString.class] ||
      [self canonicalIdentityName:advertised].length == 0) {
    [self emitError:@"invalid_identity_candidate" message:@"identity.resolve requires candidateId and advertisedName." requestID:requestID connectionID:nil];
    return;
  }
  id rawRequestedAddress = command[@"addressKey"] ?: command[@"address"];
  NSString *requestedKey = rawRequestedAddress == nil ? nil : [self addressKeyFromString:rawRequestedAddress];
  if (rawRequestedAddress != nil && requestedKey == nil) {
    [self emitError:@"invalid_identity_address" message:@"identity.resolve address/addressKey is malformed." requestID:requestID connectionID:nil];
    return;
  }
  id rawDirectedExactAddress = command[@"directedExactAddress"];
  if (rawDirectedExactAddress != nil &&
      (![rawDirectedExactAddress isKindOfClass:NSNumber.class] ||
       CFGetTypeID((__bridge CFTypeRef)rawDirectedExactAddress) != CFBooleanGetTypeID())) {
    [self emitError:@"invalid_identity_candidate" message:@"identity.resolve directedExactAddress must be a boolean." requestID:requestID connectionID:nil];
    return;
  }
  const BOOL directedExactAddress = [rawDirectedExactAddress boolValue];
  if (directedExactAddress && requestedKey == nil) {
    [self emitError:@"invalid_identity_address" message:@"identity.resolve directedExactAddress requires a valid exact Classic Bluetooth address." requestID:requestID connectionID:nil];
    return;
  }
  const uint64_t generation = ++self.identityGeneration;
  NSMutableDictionary *candidateRecord = [@{
    @"candidateId": candidateID,
    @"advertisedName": advertised,
    @"generation": @(generation),
  } mutableCopy];
  if (requestedKey != nil) {
    candidateRecord[@"addressKey"] = requestedKey;
    candidateRecord[@"address"] = [self displayAddressForKey:requestedKey];
  }
  if (directedExactAddress) candidateRecord[@"directedExactAddress"] = @YES;
  NSDictionary *existingCandidate = [self identityCandidate:candidateID];
  NSString *existingKey = [self addressKeyFromString:existingCandidate[@"addressKey"] ?: existingCandidate[@"address"]];
  if (existingCandidate != nil &&
      (![[self canonicalIdentityName:existingCandidate[@"advertisedName"]] isEqualToString:[self canonicalIdentityName:advertised]] ||
       (existingKey != nil && requestedKey != nil && ![existingKey isEqualToString:requestedKey]))) {
    [self emitError:@"identity_candidate_mismatch" message:@"identity.resolve reused candidateId for a different advertised device." requestID:requestID connectionID:nil];
    return;
  }

  NSMutableDictionary *(^resolvedRecord)(IOBluetoothDevice *) = ^NSMutableDictionary *(IOBluetoothDevice *device) {
    NSString *key = [self addressKeyFromString:device.addressString];
    NSString *address = [self displayAddressForKey:key];
    NSString *name = [self classicDisplayName:device];
    NSString *mode = [self identityNameMatchModeForDevice:device
                                                advertised:advertised
                                            expectedAddress:requestedKey ?: key
                                        directedExactAddress:directedExactAddress];
    if (device == nil || key == nil || address == nil || ![device isPaired] || mode == nil) return nil;
    if (requestedKey != nil && ![requestedKey isEqualToString:key]) return nil;
    NSMutableDictionary *record = [@{
      @"candidateId": candidateID, @"advertisedName": advertised,
      @"address": address, @"addressKey": key, @"name": name,
      @"matchMode": mode, @"generation": @(generation),
    } mutableCopy];
    if (directedExactAddress) record[@"directedExactAddress"] = @YES;
    return record;
  };
  void (^emitResolved)(NSDictionary *, NSString *, NSString *, NSString *) =
      ^(NSDictionary *record, NSString *resolution, NSString *identityState, NSString *source) {
    NSMutableDictionary *event = [@{
      @"event": @"identity.resolve.done", @"requestId": requestID,
      @"candidateId": candidateID, @"resolution": resolution,
      @"identityState": identityState, @"source": source,
      @"generation": @(generation), @"paired": @YES,
      @"address": record[@"address"], @"addressKey": record[@"addressKey"],
      @"name": record[@"name"], @"matchMode": record[@"matchMode"],
    } mutableCopy];
    [self emit:event];
  };
  void (^emitUnresolved)(NSString *, NSUInteger) = ^(NSString *resolution, NSUInteger matchCount) {
    NSMutableDictionary *event = [@{
      @"event": @"identity.resolve.done", @"requestId": requestID,
      @"candidateId": candidateID, @"resolution": resolution,
      @"identityState": @"unresolved", @"source": @"paired_name",
      @"generation": @(generation), @"paired": @NO, @"matchCount": @(matchCount),
    } mutableCopy];
    if (requestedKey != nil) {
      event[@"addressKey"] = requestedKey;
      event[@"address"] = [self displayAddressForKey:requestedKey];
    }
    [self emit:event];
  };

  NSDictionary *confirmed = self.confirmedIdentityMappings[candidateID];
  if ([confirmed isKindOfClass:NSDictionary.class]) {
    NSString *mappedKey = [self addressKeyFromString:confirmed[@"addressKey"] ?: confirmed[@"address"]];
    if (requestedKey != nil && mappedKey != nil && ![requestedKey isEqualToString:mappedKey]) {
      [self emitError:@"identity_candidate_address_mismatch" message:@"The confirmed Classic identity does not belong to the selected device address." requestID:requestID connectionID:nil];
      return;
    }
    NSMutableDictionary *record = mappedKey == nil ? nil : resolvedRecord([self directDeviceForIdentity:mappedKey]);
    if (record != nil) {
      self.identityCandidateCache[candidateID] = record;
      emitResolved(record, @"confirmed", @"confirmed", @"confirmed_mapping");
      return;
    }
    [self.confirmedIdentityMappings removeObjectForKey:candidateID];
    [NSUserDefaults.standardUserDefaults setObject:self.confirmedIdentityMappings forKey:kTuiIdentityMappingsDefaultsKey];
  }

  NSDictionary *provisional = self.provisionalIdentityMappings[candidateID];
  if ([provisional isKindOfClass:NSDictionary.class]) {
    NSString *mappedKey = [self addressKeyFromString:provisional[@"addressKey"] ?: provisional[@"address"]];
    if (requestedKey != nil && mappedKey != nil && ![requestedKey isEqualToString:mappedKey]) {
      [self emitError:@"identity_candidate_address_mismatch" message:@"The provisional Classic identity does not belong to the selected device address." requestID:requestID connectionID:nil];
      return;
    }
    NSMutableDictionary *record = mappedKey == nil ? nil : resolvedRecord([self directDeviceForIdentity:mappedKey]);
    if (record != nil) {
      self.identityCandidateCache[candidateID] = record;
      NSMutableDictionary *provisionalRecord = [record mutableCopy];
      [provisionalRecord removeObjectForKey:@"directedExactAddress"];
      self.provisionalIdentityMappings[candidateID] = provisionalRecord;
      emitResolved(record, @"provisional", @"provisional", @"provisional_mapping");
      return;
    }
    [self.provisionalIdentityMappings removeObjectForKey:candidateID];
  }

  if (requestedKey != nil) {
    NSMutableDictionary *record = resolvedRecord([self directDeviceForIdentity:requestedKey]);
    if (record != nil) {
      self.identityCandidateCache[candidateID] = record;
      NSMutableDictionary *provisionalRecord = [record mutableCopy];
      [provisionalRecord removeObjectForKey:@"directedExactAddress"];
      self.provisionalIdentityMappings[candidateID] = provisionalRecord;
      emitResolved(record, @"directClassic", @"provisional", @"explicit_classic_address");
      return;
    }
    // A direct unresolved result is still a valid pairing binding, but only
    // after persisted identity-address conflicts above have been rejected.
    // This intentionally replaces any earlier session-only directed grant
    // with exactly the intent of this resolve request.
    self.identityCandidateCache[candidateID] = candidateRecord;
    emitUnresolved(@"notPaired", 0);
    return;
  }

  NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
  for (id item in IOBluetoothDevice.pairedDevices ?: @[]) {
    IOBluetoothDevice *device = [item isKindOfClass:IOBluetoothDevice.class] ? item : nil;
    NSMutableDictionary *record = resolvedRecord(device);
    if (record != nil) [matches addObject:record];
  }
  if (matches.count == 1) {
    NSMutableDictionary *record = [matches.firstObject mutableCopy];
    self.identityCandidateCache[candidateID] = record;
    NSMutableDictionary *provisionalRecord = [record mutableCopy];
    [provisionalRecord removeObjectForKey:@"directedExactAddress"];
    self.provisionalIdentityMappings[candidateID] = provisionalRecord;
    emitResolved(record, @"uniquePaired", @"provisional", @"unique_paired");
    return;
  }
  // There is no address-capable pairing route for an unqualified scan result,
  // but retain the current unresolved request record for diagnostics without
  // preserving a prior directed-address authorization.
  self.identityCandidateCache[candidateID] = candidateRecord;
  emitUnresolved(matches.count > 1 ? @"needsSelection" : @"notPaired", matches.count);
}

- (void)emitPairingStage:(NSString *)stage
                operation:(WearableClassicPairingOperation *)operation
                  message:(NSString *)message
             nativeDomain:(NSString *)nativeDomain
               nativeCode:(NSNumber *)nativeCode {
  [self emitPairingStage:stage
               operation:operation
                 message:message
            nativeDomain:nativeDomain
              nativeCode:nativeCode
                 details:nil];
}

- (void)emitPairingStage:(NSString *)stage
                operation:(WearableClassicPairingOperation *)operation
                  message:(NSString *)message
             nativeDomain:(NSString *)nativeDomain
               nativeCode:(NSNumber *)nativeCode
                  details:(NSDictionary<NSString *, id> *)details {
  NSCAssert(NSThread.isMainThread, @"Pairing state must run on main thread");
  if (operation == nil) return;
  NSMutableDictionary *event = [@{
    @"event": @"pairing.stage",
    @"requestId": operation.requestID ?: @"",
    @"pairingId": operation.pairingID ?: @"",
    @"candidateId": operation.candidateID ?: @"",
    @"stage": stage ?: @"failed",
    @"generation": @(operation.generation),
    @"timestampMs": @(UnixMillisecondsNow()),
  } mutableCopy];
  if (message != nil) event[@"message"] = message;
  if (details != nil) [event addEntriesFromDictionary:details];
  [event addEntriesFromDictionary:NativeStatusFields(nativeDomain, nativeCode)];
  [self emit:event];
}

- (void)failPairingOperation:(WearableClassicPairingOperation *)operation
                         code:(NSString *)code
                      message:(NSString *)message
                 nativeDomain:(NSString *)nativeDomain
                   nativeCode:(NSNumber *)nativeCode
                        stage:(NSString *)stage {
  if (operation == nil || self.pairingOperation != operation || operation.completed) return;
  NSMutableDictionary<NSString *, id> *details = [NSMutableDictionary dictionary];
  WearableClassicPairingAttempt *attempt = self.pairingAttempt;
  if (attempt != nil && attempt.operation == operation) {
    [details addEntriesFromDictionary:[attempt diagnosticSnapshot]];
    details[@"nativeStage"] = @"operationFailure";
    if (code != nil) details[@"failureCode"] = code;
  }
  operation.completed = YES;
  [operation.timeout invalidate];
  operation.timeout = nil;
  [self emitPairingStage:stage ?: @"failed"
               operation:operation
                 message:message
            nativeDomain:nativeDomain
              nativeCode:nativeCode
                 details:details.count == 0 ? nil : details];
  if (self.pairingAttempt != nil && self.pairingAttempt.operation == operation) {
    [self.pairingAttempt cancel];
    self.pairingAttempt = nil;
  }
  self.pairingOperation = nil;
  [self emitError:code ?: @"pairing_failed" message:message ?: @"Classic Bluetooth pairing failed." requestID:operation.requestID connectionID:nil nativeDomain:nativeDomain nativeCode:nativeCode];
}

- (void)completePairingOperation:(WearableClassicPairingOperation *)operation
                         device:(IOBluetoothDevice *)device
                    matchMode:(NSString *)matchMode
                     source:(NSString *)source {
  if (operation == nil || self.pairingOperation != operation || operation.completed) return;
  NSString *key = [self addressKeyFromString:device.addressString];
  NSString *address = [self displayAddressForKey:key];
  NSString *name = [self classicDisplayName:device];
  NSString *validatedMatch = matchMode ?: [self identityNameMatchModeForDevice:device
                                                                   advertised:operation.advertisedName
                                                               expectedAddress:operation.addressKey
                                                           directedExactAddress:operation.directedExactAddress];
  if (key == nil || address == nil || ![key isEqualToString:operation.addressKey] ||
      ![device isPaired] || validatedMatch == nil) {
    [self failPairingOperation:operation
                           code:@"pairing_identity_mismatch"
                        message:@"The direct Classic device is not the exact paired, name-validated match for the selected candidate."
                   nativeDomain:nil
                     nativeCode:nil
                          stage:@"failed"];
    return;
  }
  operation.completed = YES;
  [operation.timeout invalidate];
  operation.timeout = nil;
  if (self.pairingAttempt != nil && self.pairingAttempt.operation == operation) self.pairingAttempt = nil;
  self.pairingOperation = nil;
  NSMutableDictionary *identity = [@{
    @"candidateId": operation.candidateID, @"advertisedName": operation.advertisedName,
    @"address": address, @"addressKey": key, @"name": name,
    @"matchMode": validatedMatch,
  } mutableCopy];
  if (operation.directedExactAddress) identity[@"directedExactAddress"] = @YES;
  self.identityCandidateCache[operation.candidateID] = identity;
  NSMutableDictionary *provisionalIdentity = [identity mutableCopy];
  [provisionalIdentity removeObjectForKey:@"directedExactAddress"];
  self.provisionalIdentityMappings[operation.candidateID] = provisionalIdentity;
  [self emitPairingStage:@"completed" operation:operation message:@"Classic Bluetooth pairing completed; application authentication is still required." nativeDomain:nil nativeCode:nil];
  [self emit:@{ @"event": @"pair.done", @"requestId": operation.requestID, @"pairingId": operation.pairingID,
               @"candidateId": operation.candidateID, @"generation": @(operation.generation),
               @"identityState": @"provisional", @"address": address, @"addressKey": key,
               @"name": name, @"paired": @YES, @"source": source ?: @"direct",
               @"matchMode": validatedMatch }];
}

- (void)beginSystemPairingForDevice:(IOBluetoothDevice *)device
                            operation:(WearableClassicPairingOperation *)operation {
  if (self.pairingOperation != operation || operation.completed) return;
  operation.phase = @"pairing";
  [self emitPairingStage:@"pairingStarted" operation:operation message:@"Starting macOS Classic Bluetooth pairing." nativeDomain:nil nativeCode:nil];
  WearableClassicPairingAttempt *attempt = [[WearableClassicPairingAttempt alloc] initWithBridge:self operation:operation device:device];
  self.pairingAttempt = attempt;
  [attempt start];
}

- (void)startPairing:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *pairingID = command[@"pairingId"];
  NSString *candidateID = command[@"candidateId"];
  NSString *advertised = command[@"advertisedName"];
  if (![pairingID isKindOfClass:NSString.class] || pairingID.length == 0 ||
      ![candidateID isKindOfClass:NSString.class] || candidateID.length == 0 ||
      ![advertised isKindOfClass:NSString.class] || [self canonicalIdentityName:advertised].length == 0) {
    [self emitError:@"invalid_pairing_request" message:@"pair.start requires pairingId, candidateId, and advertisedName." requestID:requestID connectionID:nil];
    return;
  }
  if (self.activeConnectionID != nil) {
    [self emitError:@"rfcomm_active" message:@"Disconnect the active RFCOMM connection before pairing another device." requestID:requestID connectionID:nil];
    return;
  }
  if (self.pairingOperation != nil) {
    [self emitError:@"pairing_in_progress" message:@"A Classic Bluetooth pairing operation is already active." requestID:requestID connectionID:nil];
    return;
  }
  NSDictionary *existing = [self identityCandidate:candidateID];
  if (existing == nil) {
    [self emitError:@"candidate_address_required" message:@"pair.start requires the candidate binding created by identity.resolve." requestID:requestID connectionID:nil];
    return;
  }
  if (![[self canonicalIdentityName:existing[@"advertisedName"]] isEqualToString:[self canonicalIdentityName:advertised]]) {
    [self emitError:@"identity_candidate_mismatch" message:@"pair.start candidate does not match the preceding identity.resolve candidate." requestID:requestID connectionID:nil];
    return;
  }
  NSMutableDictionary *candidate = [existing mutableCopy] ?: [NSMutableDictionary dictionary];
  candidate[@"candidateId"] = candidateID; candidate[@"advertisedName"] = advertised;
  NSString *key = [self addressKeyFromString:candidate[@"addressKey"] ?: candidate[@"address"]];
  if (key == nil) {
    [self emitError:@"candidate_address_required" message:@"pair.start requires the exact Classic address from identity.resolve." requestID:requestID connectionID:nil];
    return;
  }
  id suppliedAddress = command[@"addressKey"] ?: command[@"address"];
  NSString *suppliedKey = suppliedAddress == nil ? nil : [self addressKeyFromString:suppliedAddress];
  if (suppliedAddress != nil && (suppliedKey == nil || ![suppliedKey isEqualToString:key])) {
    [self emitError:@"identity_candidate_address_mismatch" message:@"pair.start address does not match the preceding identity.resolve candidate." requestID:requestID connectionID:nil];
    return;
  }
  self.identityCandidateCache[candidateID] = candidate;
  [self.provisionalIdentityMappings removeObjectForKey:candidateID];
  WearableClassicPairingOperation *operation = [[WearableClassicPairingOperation alloc] init];
  operation.requestID = requestID; operation.pairingID = pairingID; operation.candidateID = candidateID;
  operation.advertisedName = advertised; operation.addressKey = key;
  operation.directedExactAddress = [self candidateAllowsDirectedExactAddress:candidate addressKey:key];
  operation.generation = ++self.identityGeneration; operation.phase = @"resolving";
  self.pairingOperation = operation;
  [self emitPairingStage:@"resolving" operation:operation message:@"Resolving the selected TUI candidate to a Classic Bluetooth identity." nativeDomain:nil nativeCode:nil];
  __weak WearableBluetoothBridge *weakSelf = self;
  operation.timeout = [NSTimer timerWithTimeInterval:90 repeats:NO block:^(NSTimer *timer) {
    WearableBluetoothBridge *strongSelf = weakSelf;
    if (strongSelf != nil && strongSelf.pairingOperation == operation && !operation.completed) {
      [strongSelf failPairingOperation:operation code:@"pairing_timeout" message:@"Classic Bluetooth pairing timed out after 90 seconds." nativeDomain:nil nativeCode:nil stage:@"failed"];
    }
  }];
  [[NSRunLoop mainRunLoop] addTimer:operation.timeout forMode:NSRunLoopCommonModes];
  IOBluetoothDevice *direct = [self directDeviceForIdentity:key];
  if (direct == nil) {
    [self failPairingOperation:operation code:@"direct_device_unavailable" message:@"The exact Classic Bluetooth device address is not available to IOBluetooth." nativeDomain:nil nativeCode:nil stage:@"failed"];
    return;
  }
  NSString *mode = [self identityNameMatchModeForDevice:direct
                                             advertised:advertised
                                         expectedAddress:key
                                     directedExactAddress:operation.directedExactAddress];
  if (mode == nil) {
    [self failPairingOperation:operation code:@"identity_name_mismatch" message:@"The exact Classic address resolved to a device whose name does not match the selected candidate." nativeDomain:nil nativeCode:nil stage:@"failed"];
    return;
  }
  if ([direct isPaired]) {
    [self completePairingOperation:operation device:direct matchMode:mode source:@"direct_paired"];
  } else {
    [self beginSystemPairingForDevice:direct operation:operation];
  }
}

- (void)cancelPairing:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *requestedPairingID = command[@"pairingId"];
  WearableClassicPairingOperation *operation = self.pairingOperation;
  if (requestedPairingID != nil && (![requestedPairingID isKindOfClass:NSString.class] ||
      operation == nil || ![requestedPairingID isEqualToString:operation.pairingID])) {
    [self emitError:@"pairing_mismatch" message:@"pair.cancel must name the active pairingId." requestID:requestID connectionID:nil];
    return;
  }
  NSString *pairingID = operation.pairingID ?: requestedPairingID;
  if (operation != nil) {
    [self failPairingOperation:operation code:@"pairing_cancelled" message:@"Classic Bluetooth pairing was cancelled by the TUI." nativeDomain:nil nativeCode:nil stage:@"cancelled"];
  }
  NSMutableDictionary *cancelEvent = [@{ @"event": @"pair.cancel.done", @"requestId": requestID } mutableCopy];
  if (pairingID != nil) cancelEvent[@"pairingId"] = pairingID;
  [self emit:cancelEvent];
}

- (void)confirmIdentity:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *candidateID = command[@"candidateId"];
  NSString *connectionID = command[@"connectionId"];
  NSString *key = [self addressKeyFromString:command[@"addressKey"] ?: command[@"address"]];
  NSString *advertised = command[@"advertisedName"];
  NSNumber *generation = command[@"generation"];
  if (![candidateID isKindOfClass:NSString.class] || candidateID.length == 0 ||
      ![connectionID isKindOfClass:NSString.class] || connectionID.length == 0 || key == nil ||
      ![advertised isKindOfClass:NSString.class]) {
    [self emitError:@"invalid_identity_confirmation" message:@"identity.confirm requires candidateId, advertisedName, address, and connectionId." requestID:requestID connectionID:connectionID];
    return;
  }
  if (![connectionID isEqualToString:self.activeConnectionID] ||
      ![key isEqualToString:self.activeAddressKey] ||
      ![candidateID isEqualToString:self.activeCandidateID] ||
      (generation != nil && (![generation isKindOfClass:NSNumber.class] || generation.unsignedLongLongValue != self.activeConnectionGeneration))) {
    [self emitError:@"identity_confirmation_stale" message:@"identity.confirm does not belong to the active RFCOMM connection generation." requestID:requestID connectionID:connectionID];
    return;
  }
  NSDictionary *candidate = [self identityCandidate:candidateID] ?: self.provisionalIdentityMappings[candidateID];
  IOBluetoothDevice *device = [self directDeviceForIdentity:key];
  NSString *candidateKey = [self addressKeyFromString:candidate[@"addressKey"] ?: candidate[@"address"]];
  NSString *candidateAdvertised = candidate[@"advertisedName"];
  const BOOL directedExactAddress = [self candidateAllowsDirectedExactAddress:candidate addressKey:key];
  NSString *mode = [self identityNameMatchModeForDevice:device
                                             advertised:advertised
                                         expectedAddress:key
                                     directedExactAddress:directedExactAddress];
  if (candidate == nil || ![candidateKey isEqualToString:key] ||
      ![[self canonicalIdentityName:candidateAdvertised] isEqualToString:[self canonicalIdentityName:advertised]] ||
      device == nil || ![device isPaired] || mode == nil) {
    [self emitError:@"device_identity_unconfirmed" message:@"The authenticated Classic Bluetooth identity is no longer paired and name-validated." requestID:requestID connectionID:connectionID];
    return;
  }
  NSMutableDictionary *sessionConfirmed = [candidate mutableCopy];
  sessionConfirmed[@"candidateId"] = candidateID; sessionConfirmed[@"advertisedName"] = advertised;
  sessionConfirmed[@"addressKey"] = key; sessionConfirmed[@"address"] = [self displayAddressForKey:key] ?: @"";
  sessionConfirmed[@"name"] = [self classicDisplayName:device];
  sessionConfirmed[@"matchMode"] = mode;
  if (directedExactAddress) sessionConfirmed[@"directedExactAddress"] = @YES;
  self.identityCandidateCache[candidateID] = sessionConfirmed;
  NSMutableDictionary *confirmed = [sessionConfirmed mutableCopy];
  [confirmed removeObjectForKey:@"directedExactAddress"];
  self.confirmedIdentityMappings[candidateID] = confirmed;
  [self.provisionalIdentityMappings removeObjectForKey:candidateID];
  [NSUserDefaults.standardUserDefaults setObject:self.confirmedIdentityMappings forKey:kTuiIdentityMappingsDefaultsKey];
  self.activeCandidateID = candidateID; self.activeIdentityState = @"confirmed";
  [self emit:@{ @"event": @"identity.confirm.done", @"requestId": requestID, @"candidateId": candidateID,
               @"connectionId": connectionID, @"generation": @(self.activeConnectionGeneration),
               @"resolution": @"confirmed", @"identityState": @"confirmed",
               @"address": confirmed[@"address"], @"addressKey": key, @"name": confirmed[@"name"],
               @"paired": @YES, @"source": @"authenticated_session", @"matchMode": mode }];
}

- (void)forgetIdentity:(NSDictionary *)command requestID:(NSString *)requestID {
  NSString *candidateID = command[@"candidateId"];
  if (![candidateID isKindOfClass:NSString.class] || candidateID.length == 0) {
    [self emitError:@"invalid_identity_candidate" message:@"identity.forget requires candidateId." requestID:requestID connectionID:nil];
    return;
  }
  BOOL forgotten = self.confirmedIdentityMappings[candidateID] != nil ||
      self.provisionalIdentityMappings[candidateID] != nil || self.identityCandidateCache[candidateID] != nil;
  [self.confirmedIdentityMappings removeObjectForKey:candidateID];
  [self.provisionalIdentityMappings removeObjectForKey:candidateID];
  [self.identityCandidateCache removeObjectForKey:candidateID];
  [NSUserDefaults.standardUserDefaults setObject:self.confirmedIdentityMappings forKey:kTuiIdentityMappingsDefaultsKey];
  if ([self.activeCandidateID isEqualToString:candidateID]) { self.activeCandidateID = nil; self.activeIdentityState = nil; }
  [self emit:@{ @"event": @"identity.forget.done", @"requestId": requestID, @"candidateId": candidateID,
               @"forgotten": @(forgotten), @"unpaired": @NO, @"disconnected": @NO }];
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
  else if ([name isEqualToString:@"identity.resolve"]) [self resolveIdentity:command requestID:requestID];
  else if ([name isEqualToString:@"pair.start"]) [self startPairing:command requestID:requestID];
  else if ([name isEqualToString:@"pair.cancel"]) [self cancelPairing:command requestID:requestID];
  else if ([name isEqualToString:@"identity.confirm"]) [self confirmIdentity:command requestID:requestID];
  else if ([name isEqualToString:@"identity.forget"]) [self forgetIdentity:command requestID:requestID];
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
  NSString *candidateID = command[@"candidateId"];
  NSString *advertised = command[@"advertisedName"];
  NSString *identityState = command[@"identityState"];
  const BOOL hasCandidateFields = candidateID != nil || advertised != nil || identityState != nil;
  if (hasCandidateFields &&
      (![candidateID isKindOfClass:NSString.class] || candidateID.length == 0 ||
       ![advertised isKindOfClass:NSString.class] || [self canonicalIdentityName:advertised].length == 0 ||
       !([identityState isEqualToString:@"confirmed"] || [identityState isEqualToString:@"provisional"]))) {
    [self emitError:@"invalid_connect_identity" message:@"connect candidateId, advertisedName, and identityState must be supplied together." requestID:requestID connectionID:connectionID];
    return;
  }
  if (!hasCandidateFields) {
    NSMutableArray<NSDictionary *> *matchingCandidates = [NSMutableArray array];
    for (NSDictionary *candidate in self.identityCandidateCache.allValues) {
      NSString *candidateKey = [self addressKeyFromString:candidate[@"addressKey"] ?: candidate[@"address"]];
      if ([candidateKey isEqualToString:key]) [matchingCandidates addObject:candidate];
    }
    if (matchingCandidates.count != 1) {
      [self emitError:@"connect_identity_required" message:@"connect requires one previously resolved candidate identity." requestID:requestID connectionID:connectionID];
      return;
    }
    NSDictionary *candidate = matchingCandidates.firstObject;
    candidateID = candidate[@"candidateId"];
    advertised = candidate[@"advertisedName"];
    NSDictionary *confirmed = self.confirmedIdentityMappings[candidateID];
    NSString *confirmedKey = [self addressKeyFromString:confirmed[@"addressKey"] ?: confirmed[@"address"]];
    identityState = [confirmedKey isEqualToString:key] ? @"confirmed" : @"provisional";
  }
  NSDictionary *candidate = [self identityCandidate:candidateID];
  NSString *candidateKey = [self addressKeyFromString:candidate[@"addressKey"] ?: candidate[@"address"]];
  if (candidate == nil || ![candidateKey isEqualToString:key] ||
      ![[self canonicalIdentityName:candidate[@"advertisedName"]] isEqualToString:[self canonicalIdentityName:advertised]]) {
    [self emitError:@"connect_identity_mismatch" message:@"connect candidate does not match the resolved Classic identity." requestID:requestID connectionID:connectionID];
    return;
  }
  NSDictionary *mappedIdentity = [identityState isEqualToString:@"confirmed"]
      ? self.confirmedIdentityMappings[candidateID]
      : self.provisionalIdentityMappings[candidateID];
  NSString *mappedKey = [self addressKeyFromString:mappedIdentity[@"addressKey"] ?: mappedIdentity[@"address"]];
  if (![mappedKey isEqualToString:key]) {
    [self emitError:@"connect_identity_state_mismatch" message:@"connect identityState is not valid for the selected Classic address." requestID:requestID connectionID:connectionID];
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
                        @"candidateId": candidateID,
                        @"identityState": identityState,
                      }];
  // Do not enumerate pairedDevices or initiate authentication here. A cache
  // hit is accepted only when the native object's canonical address still
  // matches the requested classic MAC; otherwise use the public direct lookup.
  IOBluetoothDevice *cachedDevice = self.deviceCache[key];
  NSString *cachedAddressKey = [self addressKeyFromString:cachedDevice.addressString];
  const BOOL cacheAddressMatches =
      cachedDevice != nil && [cachedAddressKey isEqualToString:key];
  IOBluetoothDevice *device = cacheAddressMatches ? cachedDevice : nil;
  NSString *lookupSource = @"scan_cache";
  if (device == nil) {
    lookupSource = @"direct_classic_mac";
    IOBluetoothDevice *directDevice = [IOBluetoothDevice deviceWithAddressString:apiAddress];
    NSString *directAddressKey = [self addressKeyFromString:directDevice.addressString];
    if (directDevice != nil && [directAddressKey isEqualToString:key]) {
      device = directDevice;
      self.deviceCache[key] = directDevice;
    }
  }
  NSString *resolvedAddressKey = [self addressKeyFromString:device.addressString];
  const BOOL addressMatches = device != nil && [resolvedAddressKey isEqualToString:key];
  [self emitConnectionStage:@"device.lookup.completed"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"address": address,
                        @"addressKey": key,
                        @"deviceFound": @(device != nil),
                        @"lookupSource": lookupSource,
                        @"addressMatches": @(addressMatches),
                        @"cachePresent": @(cachedDevice != nil),
                        @"cacheAddressMatches": @(cacheAddressMatches),
                        @"resolvedAddress": device.addressString ?: @"",
                        @"resolvedAddressKey": resolvedAddressKey ?: @"",
                        @"paired": device != nil ? @([device isPaired]) : NSNull.null,
                        @"basebandConnected": device != nil ? @([device isConnected]) : NSNull.null,
                        @"deviceName": device.name ?: @"",
                        @"candidateId": candidateID,
                        @"identityState": identityState,
                      }];
  if (device == nil || !addressMatches) {
    [self emitError:@"device_lookup_not_found"
             message:@"IOBluetooth could not resolve the requested classic Bluetooth address to a matching device object."
           requestID:requestID
        connectionID:connectionID];
    return;
  }
  const BOOL directedExactAddress = [self candidateAllowsDirectedExactAddress:candidate addressKey:key];
  NSString *matchMode = [self identityNameMatchModeForDevice:device
                                                   advertised:advertised
                                               expectedAddress:key
                                           directedExactAddress:directedExactAddress];
  if (![device isPaired] || matchMode == nil) {
    [self emitError:@"connect_identity_unconfirmed" message:@"connect requires a paired, name-validated Classic identity." requestID:requestID connectionID:connectionID];
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
                      lookupSource:lookupSource
                       candidateID:candidateID
                    identityState:identityState];
}

- (void)beginConnectionWithDevice:(IOBluetoothDevice *)device
                         requestID:(NSString *)requestID
                      connectionID:(NSString *)connectionID
                               key:(NSString *)key
                            address:(NSString *)address
                         apiAddress:(NSString *)apiAddress
                      serviceUUID:(IOBluetoothSDPUUID *)serviceUUID
              requestedServiceUUID:(NSString *)requestedServiceUUID
                       lookupSource:(NSString *)lookupSource
                        candidateID:(NSString *)candidateID
                     identityState:(NSString *)identityState {
  [self expireSDPDrainIfNeeded];
  if (self.sdpDrainPending && [key isEqualToString:self.sdpDrainAddressKey]) {
    [self emitError:@"sdp_drain_required"
             message:@"The previous SDP query for this classic Bluetooth address has not delivered its terminal callback yet."
           requestID:requestID
        connectionID:connectionID];
    return;
  }
  const uint64_t generation = ++self.attemptGeneration;
  self.activeConnectionID = connectionID;
  self.activeConnectRequestID = requestID;
  self.activeAddress = address;
  self.activeAddressKey = key;
  self.activeCandidateID = candidateID;
  self.activeIdentityState = identityState;
  self.activeServiceUUID = requestedServiceUUID;
  self.activeLookupSource = lookupSource;
  self.activeEndpoint = nil;
  self.activeDeviceName = device.name;
  self.activeServiceName = nil;
  self.activeRFCOMMChannelID = 0;
  self.activeServiceRecordIndex = NSNotFound;
  self.activeConnectionGeneration = generation;
  self.activeDevicePaired = [device isPaired];
  self.activeDeviceBasebandConnected = [device isConnected];
  self.activePairingKnown = YES;
  self.activeBasebandKnown = YES;
  self.disconnectRequestID = nil;
  [self clearRFCOMMOpeningState];
  [self clearRFCOMMClosingState];
  self.pendingDevice = device;
  self.pendingServiceUUID = serviceUUID;
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
  // Both observers are active before the asynchronous full query starts.
  // The GUI backend intentionally asks IOBluetooth for the complete SDP
  // record set. Endpoint selection still occurs only after the terminal
  // delegate callback and filters that returned set by pendingServiceUUID.
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
    [self endConnectionWithReason:@"error"
                       errorCode:@"sdp_start_failed"
                         message:[NSString stringWithFormat:@"Could not start SDP query: 0x%08x", status]
                       requestID:requestID
                 nativeDomain:@"IOReturn"
                   nativeCode:@((int32_t)status)];
  }
}

- (void)handleSDPCallbackForDevice:(IOBluetoothDevice *)device
                             status:(IOReturn)status
                         generation:(uint64_t)generation
                           delegate:(WearableSDPQueryDelegate *)delegate {
  NSCAssert(NSThread.isMainThread, @"SDP callback state must run on the main thread");
  NSString *callbackAddressKey = [self addressKeyFromString:device.addressString] ?: @"";
  NSString *callbackAddress = ColonAddressForKey(callbackAddressKey) ?: device.addressString ?: @"";
  NSString *activeCallbackConnectionID =
      (generation == self.attemptGeneration && device == self.pendingDevice)
          ? self.activeConnectionID : nil;
  if (self.sdpDrainPending &&
      delegate == self.sdpDrainDelegate &&
      generation == self.sdpDrainGeneration &&
      device == self.sdpDrainDevice) {
    [self emitConnectionDiagnostic:@"sdp.callback.accepted"
                         requestID:self.sdpDrainRequestID
                      connectionID:self.sdpDrainConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"callbackDisposition": @"drain_quarantine",
                              @"callbackAddress": callbackAddress,
                              @"callbackAddressKey": callbackAddressKey,
                              @"callbackGeneration": @(generation),
                              @"status": @(status),
                            }];
    [self emitConnectionDiagnostic:@"sdp.drain.completed"
                         requestID:self.sdpDrainRequestID
                      connectionID:self.sdpDrainConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": ColonAddressForKey(self.sdpDrainAddressKey ?: @"") ?: @"",
                              @"generation": @(generation),
                              @"addressKey": self.sdpDrainAddressKey ?: @"",
                              @"status": @(status),
                              @"nativeDomain": @"IOReturn",
                              @"nativeCode": @((int32_t)status),
                              @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
                              @"callbackDisposition": @"drain_completed",
                            }];
    [self clearSDPDrain];
    return;
  }
  for (NSUInteger index = 0; index < self.retiredSDPQueries.count; ++index) {
    WearableRetiredSDPQuery *retired = self.retiredSDPQueries[index];
    if (delegate != retired.delegate || generation != retired.generation || device != retired.device) continue;
    [self emitConnectionDiagnostic:@"sdp.callback.accepted"
                         requestID:retired.requestID
                      connectionID:retired.connectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"callbackDisposition": @"retired_quarantine",
                              @"callbackAddress": callbackAddress,
                              @"callbackAddressKey": callbackAddressKey,
                              @"callbackGeneration": @(generation),
                              @"status": @(status),
                            }];
    [self emitConnectionDiagnostic:@"sdp.drain.late_callback"
                         requestID:retired.requestID
                      connectionID:retired.connectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": ColonAddressForKey(retired.addressKey ?: @"") ?: @"",
                              @"generation": @(generation),
                              @"addressKey": retired.addressKey ?: @"",
                              @"status": @(status),
                              @"nativeDomain": @"IOReturn",
                              @"nativeCode": @((int32_t)status),
                              @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
                              @"callbackDisposition": @"retired",
                            }];
    // Keep this tuple for the helper lifetime. IOBluetooth does not expose a
    // completion acknowledgement or cancellation API, so a second or very
    // late callback must still land on a live delegate and must never mutate a
    // later same-device connection.
    return;
  }
  if (delegate != self.pendingSDPDelegate) {
    [self emitConnectionDiagnostic:@"sdp.callback.rejected"
                         requestID:activeCallbackConnectionID == nil ? nil : self.activeConnectRequestID
                      connectionID:activeCallbackConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"reason": @"delegate_not_pending",
                              @"callbackAddress": callbackAddress,
                              @"callbackAddressKey": callbackAddressKey,
                              @"callbackGeneration": @(generation),
                              @"expectedGeneration": @(self.attemptGeneration),
                              @"status": @(status),
                            }];
    return;
  }
  if (generation != self.attemptGeneration) {
    [self emitConnectionDiagnostic:@"sdp.callback.rejected"
                         requestID:self.activeConnectRequestID
                      connectionID:self.activeConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"reason": @"generation_mismatch",
                              @"expectedGeneration": @(self.attemptGeneration),
                              @"status": @(status),
                            }];
    return;
  }
  if (device != self.pendingDevice) {
    [self emitConnectionDiagnostic:@"sdp.callback.rejected"
                         requestID:self.activeConnectRequestID
                      connectionID:self.activeConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"reason": @"device_not_pending",
                              @"expectedGeneration": @(self.attemptGeneration),
                              @"status": @(status),
                            }];
    return;
  }
  if (self.activeConnectionID == nil) {
    [self emitConnectionDiagnostic:@"sdp.callback.rejected"
                         requestID:nil
                      connectionID:nil
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"address": callbackAddress,
                              @"addressKey": callbackAddressKey,
                              @"generation": @(generation),
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"reason": @"no_active_connection",
                              @"expectedGeneration": @(self.attemptGeneration),
                              @"status": @(status),
                            }];
    return;
  }
  [self completeSDPQueryForDevice:device
                           status:status
                       generation:generation
                 completionSource:@"delegate"
                completionDelegate:delegate];
}

- (void)completeSDPQueryForDevice:(IOBluetoothDevice *)device
                            status:(IOReturn)status
                        generation:(uint64_t)generation
                  completionSource:(NSString *)completionSource
                 completionDelegate:(WearableSDPQueryDelegate *)completionDelegate {
  const BOOL completionFromDelegate = [completionSource isEqualToString:@"delegate"];
  const BOOL completionFromCachePoll = [completionSource isEqualToString:@"cache_poll"];
  if (!completionFromDelegate && !completionFromCachePoll) {
    [self emitConnectionDiagnostic:@"sdp.completion.rejected"
                         requestID:self.activeConnectRequestID
                      connectionID:self.activeConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"completionSource": completionSource ?: @"",
                              @"reason": @"unsupported_completion_source",
                              @"callbackSelector": @"sdpQueryComplete:status:",
                              @"callbackGeneration": @(generation),
                              @"addressKey": [self addressKeyFromString:device.addressString] ?: @"",
                            }];
    return;
  }
  if (generation != self.attemptGeneration ||
      device != self.pendingDevice ||
      self.activeConnectionID == nil) return;

  // Delegate completion must still own the active query. Cache completion is
  // accepted only after its exact original delegate/device/connection tuple
  // has been retained in a permanent tombstone. This rejects a stale cache
  // poll from a prior connection even when it targets the same Classic MAC.
  const BOOL completionDelegateMatches = completionFromDelegate &&
      completionDelegate == self.pendingSDPDelegate;
  BOOL cacheTombstoneMatches = NO;
  if (completionFromCachePoll && completionDelegate != nil) {
    for (WearableRetiredSDPQuery *retired in self.retiredSDPQueries) {
      if (retired.delegate != completionDelegate ||
          retired.device != device ||
          retired.generation != generation ||
          ![retired.connectionID isEqualToString:self.activeConnectionID] ||
          ![retired.requestID isEqualToString:self.activeConnectRequestID] ||
          ![retired.addressKey isEqualToString:self.activeAddressKey]) continue;
      cacheTombstoneMatches = YES;
      break;
    }
  }
  if (!completionDelegateMatches && !cacheTombstoneMatches) {
    [self emitConnectionDiagnostic:@"sdp.completion.rejected"
                         requestID:self.activeConnectRequestID
                      connectionID:self.activeConnectionID
                            fields:@{
                              @"transport": @"classic-rfcomm",
                              @"completionSource": completionSource ?: @"",
                              @"reason": completionFromDelegate
                                  ? @"delegate_not_active"
                                  : @"cache_tombstone_tuple_mismatch",
                              @"generation": @(generation),
                              @"callbackGeneration": @(generation),
                              @"delegateCallbackObserved": @(completionFromDelegate),
                            }];
    return;
  }
  NSString *requestID = self.activeConnectRequestID;
  NSString *connectionID = self.activeConnectionID;
  [self emitConnectionDiagnostic:completionFromDelegate
                               ? @"sdp.callback.accepted"
                               : @"sdp.cache_fallback.accepted"
                       requestID:requestID
                    connectionID:connectionID
                          fields:@{
                            @"transport": @"classic-rfcomm",
                            @"callbackSelector": completionFromDelegate
                                ? @"sdpQueryComplete:status:"
                                : @"service_cache_refresh",
                            @"callbackDisposition": completionFromDelegate
                                ? @"active_query"
                                : @"cache_poll_tombstone",
                            @"callbackAddress": ColonAddressForKey(self.activeAddressKey ?: @"") ?: @"",
                            @"callbackAddressKey": self.activeAddressKey ?: @"",
                            @"callbackGeneration": @(generation),
                            @"status": @(status),
                          }];
  NSArray<IOBluetoothSDPServiceRecord *> *records = [self serviceRecordsForDevice:device];
  [self invalidateSDPCachePolling];
  if (completionFromDelegate) self.pendingSDPDelegate = nil;
  [self emitConnectionStage:@"sdp.completed"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"status": @(status),
                        @"queryKind": @"full",
                        @"completionSource": completionSource,
                        @"completionStatusInferred": @(completionFromCachePoll),
                        @"completionStatusSource": completionFromCachePoll
                            ? @"service_cache_refresh"
                            : @"sdk_delegate_callback",
                        @"delegateCallbackObserved": @(completionFromDelegate),
                        @"nativeDomain": @"IOReturn",
                        @"nativeCode": @((int32_t)status),
                        @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
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
  NSInteger selectedServiceRecordIndex = NSNotFound;
  NSString *selectedServiceName = nil;
  NSUInteger matchingServiceCount = 0;
  for (NSUInteger index = 0; index < records.count; ++index) {
    IOBluetoothSDPServiceRecord *record = records[index];
    const BOOL matchesRequestedService = [record matchesUUIDArray:@[ self.pendingServiceUUID ]];
    BluetoothRFCOMMChannelID candidateChannel = 0;
    const IOReturn channelStatus = [record getRFCOMMChannelID:&candidateChannel];
    [self emitConnectionDiagnostic:@"sdp.service_record"
                         requestID:requestID
                      connectionID:connectionID
                            fields:@{
                              @"index": @(index),
                              @"queryKind": @"full",
                              @"completionSource": completionSource ?: @"",
                              @"serviceName": [record getServiceName] ?: @"",
                              @"matchesRequestedService": @(matchesRequestedService),
                              @"rfcommChannelStatus": @(channelStatus),
                              @"rfcommChannelId": channelStatus == kIOReturnSuccess ? @(candidateChannel) : @(-1),
                              @"endpoint": channelStatus == kIOReturnSuccess ? [NSString stringWithFormat:@"rfcomm:%u", candidateChannel] : @"",
                            }];
    if (!matchesRequestedService) continue;
    ++matchingServiceCount;
    if (channelStatus == kIOReturnSuccess) {
      [channels addObject:@(candidateChannel)];
      if (selectedServiceRecordIndex == NSNotFound) {
        selectedServiceRecordIndex = (NSInteger)index;
        selectedServiceName = [record getServiceName];
      }
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
  self.activeRFCOMMChannelID = channelID;
  self.activeEndpoint = [NSString stringWithFormat:@"rfcomm:%u", channelID];
  self.activeServiceRecordIndex = selectedServiceRecordIndex;
  self.activeServiceName = selectedServiceName;
  [self emitConnectionStage:@"sdp.endpoint.selected"
                  requestID:requestID
               connectionID:connectionID
                      fields:@{
                        @"channel": @(channelID),
                        @"endpoint": self.activeEndpoint,
                        @"serviceRecordIndex": @(selectedServiceRecordIndex),
                        @"serviceName": selectedServiceName ?: @"",
                      }];
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
  self.openingDevice = device;
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
                        @"nativeDomain": @"IOReturn",
                        @"nativeCode": @((int32_t)openStatus),
                        @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", openStatus],
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
    [self endConnectionWithReason:@"error"
                       errorCode:@"rfcomm_open_start_failed"
                         message:[NSString stringWithFormat:@"Could not start RFCOMM channel %u: 0x%08x", channelID, openStatus]
                       requestID:requestID
                 nativeDomain:@"IOReturn"
                   nativeCode:@((int32_t)openStatus)];
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
  IOBluetoothDevice *callbackDevice = [rfcommChannel getDevice];
  IOBluetoothDevice *openingDevice = self.openingDevice;
  const BluetoothDeviceAddress *callbackAddress = [callbackDevice getAddress];
  const BluetoothDeviceAddress *openingAddress = [openingDevice getAddress];
  const BOOL deviceMatches = callbackDevice != nil &&
      (callbackDevice == openingDevice ||
       (callbackAddress != nullptr && openingAddress != nullptr &&
        memcmp(callbackAddress->data, openingAddress->data, sizeof(callbackAddress->data)) == 0));
  const BOOL belongsToOpeningRequest =
      self.rfcommOpenPending &&
      self.openingGeneration == self.attemptGeneration &&
      self.activeConnectionID != nil &&
      deviceMatches &&
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
                        @"nativeDomain": @"IOReturn",
                        @"nativeCode": @((int32_t)status),
                        @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
                      }];
  if (status != kIOReturnSuccess) {
    [rfcommChannel closeChannel];
    [self endConnectionWithReason:@"error"
                       errorCode:@"rfcomm_open_failed"
                         message:[NSString stringWithFormat:@"RFCOMM open failed: 0x%08x", status]
                       requestID:requestID
                 nativeDomain:@"IOReturn"
                   nativeCode:@((int32_t)status)];
    return;
  }
  self.channel = rfcommChannel;
  NSUInteger mtu = [rfcommChannel getMTU];
  NSMutableDictionary<NSString *, id> *event = [@{
    @"event": @"connect.done",
    @"timestampMs": @(UnixMillisecondsNow()),
    @"requestId": requestID,
    @"connectionId": connectionID,
    @"address": self.activeAddress,
    @"addressKey": self.activeAddressKey,
    @"channel": @([rfcommChannel getChannelID]),
    @"mtu": @(mtu),
  } mutableCopy];
  [event addEntriesFromDictionary:[self activeConnectionMetadataSnapshot]];
  [self emit:event];
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
  NSString *address = self.activeAddress ?: @"";
  NSString *addressKey = self.activeAddressKey ?: @"";
  const uint64_t generation = self.activeConnectionGeneration;
  NSMutableArray<NSDictionary<NSString *, id> *> *writes = [NSMutableArray array];
  for (NSUInteger offset = 0; offset < data.length; offset += mtu) {
    NSUInteger length = MIN(mtu, data.length - offset);
    IOReturn status = [self.channel writeSync:(void *)(bytes + offset) length:(UInt16)length];
    if (status != kIOReturnSuccess) {
      [self emitConnectionDiagnostic:@"raw.tx.failed"
                           requestID:requestID
                        connectionID:connectionID
                              fields:@{
                                @"transport": @"classic-rfcomm",
                                @"endpoint": self.activeEndpoint ?: @"",
                                @"channel": @(self.activeRFCOMMChannelID),
                                @"offset": @(offset),
                                @"length": @(length),
                                @"hex": HexStringForData([data subdataWithRange:NSMakeRange(offset, length)], kMaximumTransportDiagnosticHexBytes),
                                @"writeResult": @"failed",
                                @"nativeDomain": @"IOReturn",
                                @"nativeCode": @((int32_t)status),
                                @"nativeStatusHex": [NSString stringWithFormat:@"0x%08x", status],
                              }];
      [self emitError:@"write_failed" message:[NSString stringWithFormat:@"RFCOMM write failed at byte %lu: 0x%08x", (unsigned long)offset, status] requestID:requestID connectionID:connectionID nativeDomain:@"IOReturn" nativeCode:@((int32_t)status)];
      return;
    }
    [writes addObject:@{
      @"offset": @(offset),
      @"length": @(length),
      @"hex": HexStringForData([data subdataWithRange:NSMakeRange(offset, length)], kMaximumTransportDiagnosticHexBytes),
      @"writeResult": @"success",
    }];
  }
  [self emitConnectionDiagnostic:@"raw.tx"
                       requestID:requestID
                    connectionID:connectionID
                          fields:@{
                            @"transport": @"classic-rfcomm",
                            @"endpoint": self.activeEndpoint ?: @"",
                            @"channel": @(self.activeRFCOMMChannelID),
                            @"length": @(data.length),
                            @"hex": HexStringForData(data, kMaximumTransportDiagnosticHexBytes),
                            @"writeResult": @"success",
                            @"chunks": writes,
                          }];
  [self emit:@{ @"event": @"write.done", @"requestId": requestID, @"connectionId": connectionID, @"address": address, @"addressKey": addressKey, @"generation": @(generation), @"timestampMs": @(UnixMillisecondsNow()), @"transport": @"classic-rfcomm", @"endpoint": self.activeEndpoint ?: @"", @"channel": @(self.activeRFCOMMChannelID), @"byteCount": @(data.length), @"length": @(data.length), @"hex": HexStringForData(data, kMaximumTransportDiagnosticHexBytes), @"writeResult": @"success", @"nativeDomain": @"IOReturn", @"nativeCode": @0, @"nativeStatusHex": @"0x00000000" }];
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
    self.closingChannel = self.channel;
    self.closingGeneration = self.attemptGeneration;
    self.closingChannelID = [self.channel getChannelID];
    [self emitConnectionStage:@"rfcomm.close.started" requestID:requestID connectionID:connectionID fields:@{ @"channel": @(self.closingChannelID), @"endpoint": self.activeEndpoint ?: @"", @"timeoutMs": @(kRFCOMMCloseTimeoutMilliseconds) }];
    IOReturn status = [self.closingChannel closeChannel];
    if (status != kIOReturnSuccess) {
      [self endConnectionWithReason:@"error" errorCode:@"disconnect_failed" message:[NSString stringWithFormat:@"Could not close RFCOMM channel: 0x%08x", status] requestID:requestID nativeDomain:@"IOReturn" nativeCode:@((int32_t)status)];
    } else {
      [self scheduleRFCOMMCloseTimeoutForGeneration:self.closingGeneration connectionID:connectionID channelID:self.closingChannelID channel:self.closingChannel];
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
  [self endConnectionWithReason:reason errorCode:errorCode message:message requestID:requestID nativeDomain:nil nativeCode:nil];
}

- (void)endConnectionWithReason:(NSString *)reason errorCode:(NSString *)errorCode message:(NSString *)message requestID:(NSString *)requestID nativeDomain:(NSString *)nativeDomain nativeCode:(NSNumber *)nativeCode {
  NSCAssert(NSThread.isMainThread, @"Connection state must run on main thread");
  NSString *connectionID = self.activeConnectionID;
  if (connectionID == nil) return;
  NSString *address = self.activeAddress ?: @"";
  NSString *addressKey = self.activeAddressKey ?: @"";
  NSString *candidateID = self.activeCandidateID;
  NSString *identityState = self.activeIdentityState;
  NSString *endpoint = self.activeEndpoint;
  NSString *serviceUUID = self.activeServiceUUID;
  const uint64_t connectionGeneration = self.activeConnectionGeneration;
  NSString *disconnectRequestID = self.disconnectRequestID;
  IOBluetoothRFCOMMChannel *openingChannel = self.openingChannel;
  IOBluetoothRFCOMMChannel *activeChannel = self.channel;
  IOBluetoothRFCOMMChannel *closingChannel = self.closingChannel;
  NSMutableDictionary<NSString *, id> *terminalMetadata = [@{
    @"address": address,
    @"addressKey": addressKey,
    @"generation": @(connectionGeneration),
    @"attemptGeneration": @(connectionGeneration),
    @"transport": @"classic-rfcomm",
  } mutableCopy];
  if (candidateID != nil) terminalMetadata[@"candidateId"] = candidateID;
  if (identityState != nil) terminalMetadata[@"identityState"] = identityState;
  if (endpoint != nil) terminalMetadata[@"endpoint"] = endpoint;
  if (serviceUUID != nil) terminalMetadata[@"serviceUuid"] = serviceUUID;
  ++self.attemptGeneration;
  [self invalidateSDPCachePolling];
  self.pendingDevice = nil; self.pendingServiceUUID = nil; self.pendingSDPDelegate = nil; self.channel = nil;
  [self clearRFCOMMOpeningState];
  self.sdpBaselineServicesUpdate = nil; self.sdpQueryStartedAt = nil; self.sdpCacheRefreshObserved = NO;
  self.activeConnectionID = nil; self.activeConnectRequestID = nil; self.activeAddress = nil; self.activeAddressKey = nil;
  self.activeCandidateID = nil; self.activeIdentityState = nil;
  self.activeServiceUUID = nil; self.activeLookupSource = nil; self.activeEndpoint = nil;
  self.activeDeviceName = nil; self.activeServiceName = nil;
  self.activeRFCOMMChannelID = 0; self.activeServiceRecordIndex = NSNotFound;
  self.activeConnectionGeneration = 0;
  self.activeDevicePaired = NO; self.activeDeviceBasebandConnected = NO;
  self.activePairingKnown = NO; self.activeBasebandKnown = NO;
  self.disconnectRequestID = nil; [self clearRFCOMMClosingState];
  if (openingChannel != nil && openingChannel != activeChannel) [openingChannel closeChannel];
  if (activeChannel != nil) [activeChannel closeChannel];
  if (closingChannel != nil && closingChannel != activeChannel && closingChannel != openingChannel) [closingChannel closeChannel];
  // Active native state is already cleared. Emit the terminal error from the
  // captured tuple so Dart can complete the pending request without weakening
  // generation fencing or consulting mutable replacement-connection state.
  if (errorCode != nil) {
    [self emitError:errorCode
             message:message
           requestID:requestID
        connectionID:connectionID
           metadata:terminalMetadata
        nativeDomain:nativeDomain
          nativeCode:nativeCode];
  }
  [self emit:@{
    @"event": @"connection.stage",
    @"stage": @"cleanup.completed",
    @"timestampMs": @(UnixMillisecondsNow()),
    @"requestId": requestID ?: disconnectRequestID ?: @"",
    @"connectionId": connectionID,
    @"address": address,
    @"addressKey": addressKey,
    @"generation": @(connectionGeneration),
    @"transport": @"classic-rfcomm",
    @"reason": reason,
  }];
  NSMutableDictionary *closed = [@{
    @"event": @"closed", @"timestampMs": @(UnixMillisecondsNow()),
    @"connectionId": connectionID, @"address": address, @"addressKey": addressKey,
    @"generation": @(connectionGeneration), @"transport": @"classic-rfcomm",
    @"reason": reason ?: @"unknown",
  } mutableCopy];
  if (candidateID != nil) closed[@"candidateId"] = candidateID;
  if (identityState != nil) closed[@"identityState"] = identityState;
  if (endpoint != nil) closed[@"endpoint"] = endpoint;
  if (serviceUUID != nil) closed[@"serviceUuid"] = serviceUUID;
  [self emit:closed];
  if (disconnectRequestID != nil) {
    [self emit:@{ @"event": @"disconnect.done", @"timestampMs": @(UnixMillisecondsNow()), @"requestId": disconnectRequestID, @"connectionId": connectionID, @"address": address, @"addressKey": addressKey, @"generation": @(connectionGeneration), @"reason": reason ?: @"unknown" }];
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
  NSString *connectionID = self.activeConnectionID;
  NSString *address = self.activeAddress ?: @"";
  NSString *addressKey = self.activeAddressKey ?: @"";
  const uint64_t generation = self.activeConnectionGeneration;
  [self emitConnectionDiagnostic:@"raw.rx" requestID:nil connectionID:connectionID fields:@{ @"transport": @"classic-rfcomm", @"endpoint": self.activeEndpoint ?: @"", @"channel": @(self.activeRFCOMMChannelID), @"length": @(data.length), @"hex": HexStringForData(data, kMaximumTransportDiagnosticHexBytes), @"readResult": @"success" }];
  [self emit:@{ @"event": @"data", @"timestampMs": @(UnixMillisecondsNow()), @"connectionId": connectionID, @"address": address, @"addressKey": addressKey, @"generation": @(generation), @"transport": @"classic-rfcomm", @"endpoint": self.activeEndpoint ?: @"", @"channel": @(self.activeRFCOMMChannelID), @"length": @(data.length), @"hex": HexStringForData(data, kMaximumTransportDiagnosticHexBytes), @"readResult": @"success", @"nativeDomain": @"IOReturn", @"nativeCode": @0, @"nativeStatusHex": @"0x00000000", @"base64": [data base64EncodedStringWithOptions:0] }];
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)rfcommChannel {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self rfcommChannelClosed:rfcommChannel]; }); return; }
  if (rfcommChannel != self.channel) return;
  const BOOL locallyClosing = self.closing && rfcommChannel == self.closingChannel;
  self.channel = nil;
  if (locallyClosing) {
    [self emitConnectionStage:@"rfcomm.close.completed" requestID:self.disconnectRequestID connectionID:self.activeConnectionID fields:@{ @"channel": @(self.closingChannelID), @"status": @0 }];
    // The channel has already delivered its terminal callback. Do not pass it
    // into endConnection, which otherwise closes all still-owned channels.
    self.closingChannel = nil;
  }
  [self endConnectionWithReason:locallyClosing ? @"local" : @"remote" errorCode:nil message:nil requestID:nil];
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
  WearableClassicPairingOperation *pairingOperation = self.pairingOperation;
  WearableClassicPairingAttempt *pairingAttempt = self.pairingAttempt;
  pairingOperation.completed = YES;
  [pairingOperation.timeout invalidate];
  pairingOperation.timeout = nil;
  self.pairingAttempt = nil;
  self.pairingOperation = nil;
  [pairingAttempt cancel];
  ++self.attemptGeneration;
  if (openingChannel != nil && openingChannel != activeChannel) [openingChannel closeChannel];
  if (activeChannel != nil) [activeChannel closeChannel];
}

- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
            emitStage:(NSString *)stage
               message:(NSString *)message
          nativeDomain:(NSString *)nativeDomain
            nativeCode:(NSNumber *)nativeCode {
  [self pairingAttempt:attempt
             emitStage:stage
                message:message
           nativeDomain:nativeDomain
             nativeCode:nativeCode
            nativeStage:stage
         callbackThread:@"main"
    callbackTimestampMs:@(UnixMillisecondsNow())
     senderMatchesPair:@YES];
}

- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
            emitStage:(NSString *)stage
               message:(NSString *)message
          nativeDomain:(NSString *)nativeDomain
            nativeCode:(NSNumber *)nativeCode
           nativeStage:(NSString *)nativeStage
        callbackThread:(NSString *)callbackThread
   callbackTimestampMs:(NSNumber *)callbackTimestampMs
    senderMatchesPair:(NSNumber *)senderMatchesPair {
  NSCAssert(NSThread.isMainThread, @"Pairing callbacks must be handled on main thread");
  if (attempt == nil || attempt.operation == nil ||
      self.pairingAttempt != attempt ||
      self.pairingOperation != attempt.operation || attempt.operation.completed) return;
  // The Dart contract intentionally exposes a small stable stage enum. Native
  // progress that has no distinct TUI state is folded into its nearest public
  // state instead of emitting an unknown enum value and invalidating JSONL.
  NSString *publicStage = @"pairingStarted";
  if ([stage isEqualToString:@"waitingPin"] || [stage isEqualToString:@"waitingPinSubmitted"]) {
    publicStage = @"waitingPin";
  } else if ([stage isEqualToString:@"waitingConfirmation"] ||
             [stage isEqualToString:@"waitingConfirmationSubmitted"] ||
             [stage isEqualToString:@"waitingPasskey"]) {
    publicStage = @"waitingConfirmation";
  }
  NSMutableDictionary<NSString *, id> *details = [NSMutableDictionary dictionary];
  if (nativeStage != nil) details[@"nativeStage"] = nativeStage;
  if (callbackThread != nil) details[@"callbackThread"] = callbackThread;
  if (callbackTimestampMs != nil) details[@"callbackTimestampMs"] = callbackTimestampMs;
  if (senderMatchesPair != nil) details[@"senderMatchesPair"] = senderMatchesPair;
  [details addEntriesFromDictionary:[attempt diagnosticSnapshot]];
  [self emitPairingStage:publicStage
               operation:attempt.operation
                 message:message
            nativeDomain:nativeDomain
              nativeCode:nativeCode
                 details:details];
}

- (void)pairingAttempt:(WearableClassicPairingAttempt *)attempt
       didFinishDevice:(IOBluetoothDevice *)device
                status:(IOReturn)status {
  if (attempt == nil || attempt.operation == nil ||
      self.pairingAttempt != attempt ||
      self.pairingOperation != attempt.operation || attempt.operation.completed) return;
  [self failPairingOperation:attempt.operation
                         code:@"pairing_failed"
                      message:[NSString stringWithFormat:@"Classic Bluetooth pairing failed: 0x%08x", status]
                 nativeDomain:@"IOReturn"
                   nativeCode:@((int32_t)status)
                        stage:@"failed"];
}

@end

@implementation WearableClassicPairingAttempt

- (instancetype)initWithBridge:(WearableBluetoothBridge *)bridge
                      operation:(WearableClassicPairingOperation *)operation
                         device:(IOBluetoothDevice *)device {
  self = [super init];
  if (self != nil) {
    _bridge = bridge;
    _operation = operation;
    _device = device;
  }
  return self;
}

- (void)start {
  NSCAssert(NSThread.isMainThread, @"Pairing start must run on main thread");
  if (self.finished || self.bridge == nil || self.operation.completed) return;
  IOBluetoothDevicePair *pair = [IOBluetoothDevicePair pairWithDevice:self.device];
  if (pair == nil) {
    [self.bridge failPairingOperation:self.operation
                                 code:@"pairing_controller"
                              message:@"macOS could not create a Classic Bluetooth pairing operation."
                         nativeDomain:nil
                           nativeCode:nil
                                stage:@"failed"];
    self.finished = YES;
    return;
  }
  self.pair = pair;
  pair.delegate = self;
  IOReturn status = [pair start];
  self.pairingStartReturned = YES;
  self.pairingStartStatus = status;
  [self emitStage:@"pairingStarted"
          message:@"macOS pairing start request returned."
     nativeDomain:@"IOReturn"
       nativeCode:@((int32_t)status)
      nativeStage:@"pairingStartReturned"];
  if (status != kIOReturnSuccess && !self.finished) {
    [self.bridge failPairingOperation:self.operation
                                 code:@"pairing_start_failed"
                              message:[NSString stringWithFormat:@"Classic Bluetooth pairing could not start: 0x%08x", status]
                         nativeDomain:@"IOReturn"
                           nativeCode:@((int32_t)status)
                                stage:@"failed"];
    self.finished = YES;
  }
}

- (void)cancel {
  NSCAssert(NSThread.isMainThread, @"Pairing cancellation must run on main thread");
  if (self.finished) return;
  self.finished = YES;
  [self dismissActivePrompt];
  IOBluetoothDevicePair *pair = self.pair;
  self.pair = nil;
  pair.delegate = nil;
  [pair stop];
}

- (NSDictionary<NSString *, id> *)diagnosticSnapshot {
  NSCAssert(NSThread.isMainThread, @"Pairing diagnostics must run on main thread");
  NSApplication *application = NSApp;
  return @{
    @"appKitInitialized": @(application != nil),
    @"applicationRunning": @(application.isRunning),
    @"applicationActive": @(application.isActive),
    @"promptPresented": @(self.activePrompt != nil),
    @"pairObjectPresent": @(self.pair != nil),
    @"attemptFinished": @(self.finished),
    @"pairingStartReturned": @(self.pairingStartReturned),
    @"pairingStartStatus": self.pairingStartReturned
        ? @((int32_t)self.pairingStartStatus)
        : NSNull.null,
    @"devicePaired": @([self.device isPaired]),
    @"deviceConnected": @([self.device isConnected]),
  };
}

- (void)dismissActivePrompt {
  NSCAssert(NSThread.isMainThread, @"Pairing prompt dismissal must run on main thread");
  NSAlert *prompt = self.activePrompt;
  if (prompt == nil) return;
  [NSApp abortModal];
  [prompt.window close];
  self.activePrompt = nil;
}

- (void)prepareApplicationForPrompt {
  NSCAssert(NSThread.isMainThread, @"Pairing prompts must run on main thread");
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
  if (!application.isRunning) [application finishLaunching];
  [application activateIgnoringOtherApps:YES];
}

- (void)emitStage:(NSString *)stage
          message:(NSString *)message
     nativeDomain:(NSString *)domain
       nativeCode:(NSNumber *)code
       nativeStage:(NSString *)nativeStage {
  [self.bridge pairingAttempt:self
                    emitStage:stage
                       message:message
                  nativeDomain:domain
                    nativeCode:code
                   nativeStage:nativeStage
                callbackThread:@"main"
           callbackTimestampMs:@(UnixMillisecondsNow())
            senderMatchesPair:@YES];
}

- (void)dispatchPairingCallbackStage:(NSString *)stage
                       nativeStage:(NSString *)nativeStage
                            sender:(id)sender
                           message:(NSString *)message
                      nativeDomain:(NSString *)nativeDomain
                        nativeCode:(NSNumber *)nativeCode
                            action:(void (^)(WearableClassicPairingAttempt *attempt))action {
  NSString *callbackThread = NSThread.isMainThread ? @"main" : @"background";
  NSNumber *callbackTimestampMs = @(UnixMillisecondsNow());
  void (^handleOnMain)(void) = ^{
    NSCAssert(NSThread.isMainThread, @"Pairing callbacks must be handled on main thread");
    WearableBluetoothBridge *bridge = self.bridge;
    const BOOL senderMatchesPair = sender != nil && sender == self.pair;
    const BOOL bridgeMatchesAttempt = bridge != nil && bridge.pairingAttempt == self;
    if (self.finished || !senderMatchesPair || !bridgeMatchesAttempt) return;
    [bridge pairingAttempt:self
                      emitStage:stage
                         message:message
                    nativeDomain:nativeDomain
                      nativeCode:nativeCode
                     nativeStage:nativeStage
                  callbackThread:callbackThread
             callbackTimestampMs:callbackTimestampMs
              senderMatchesPair:@(senderMatchesPair)];
    if (action != nil && !self.finished && sender == self.pair &&
        bridge.pairingAttempt == self) {
      action(self);
    }
  };
  if (NSThread.isMainThread) {
    handleOnMain();
  } else {
    dispatch_async(dispatch_get_main_queue(), handleOnMain);
  }
}

- (void)devicePairingStarted:(id)sender {
  [self dispatchPairingCallbackStage:@"pairingStarted" nativeStage:@"pairingStarted" sender:sender message:@"macOS pairing started." nativeDomain:nil nativeCode:nil action:nil];
}

- (void)devicePairingConnecting:(id)sender {
  [self dispatchPairingCallbackStage:@"pairingConnecting" nativeStage:@"pairingConnecting" sender:sender message:@"macOS is connecting the Classic baseband." nativeDomain:nil nativeCode:nil action:nil];
}

- (void)devicePairingConnected:(id)sender {
  [self dispatchPairingCallbackStage:@"pairingConnected" nativeStage:@"pairingConnected" sender:sender message:@"Classic baseband connection established." nativeDomain:nil nativeCode:nil action:nil];
}

- (void)devicePairingPINCodeRequest:(id)sender {
  [self dispatchPairingCallbackStage:@"waitingPin" nativeStage:@"pinCodeRequest" sender:sender message:@"The device requested a PIN code." nativeDomain:nil nativeCode:nil action:^(WearableClassicPairingAttempt *attempt) {
    [attempt prepareApplicationForPrompt];
    NSAlert *alert = [[NSAlert alloc] init];
    attempt.activePrompt = alert;
    alert.messageText = @"Bluetooth PIN required";
    alert.informativeText = @"Enter the PIN shown or requested by the wearable.";
    [alert addButtonWithTitle:@"Pair"];
    [alert addButtonWithTitle:@"Cancel"];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.placeholderString = @"PIN";
    alert.accessoryView = field;
    NSModalResponse response = [alert runModal];
    attempt.activePrompt = nil;
    if (attempt.finished || sender != attempt.pair) return;
    if (response != NSAlertFirstButtonReturn) {
      [attempt.bridge failPairingOperation:attempt.operation code:@"pairing_user_input_cancelled" message:@"Classic Bluetooth pairing was cancelled before a PIN was provided." nativeDomain:nil nativeCode:nil stage:@"cancelled"];
      [attempt cancel];
      return;
    }
    NSData *bytes = [field.stringValue dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length == 0 || bytes.length > 16) {
      [attempt.bridge failPairingOperation:attempt.operation code:@"pairing_user_input_invalid" message:@"PIN must contain between 1 and 16 bytes." nativeDomain:nil nativeCode:nil stage:@"failed"];
      [attempt cancel];
      return;
    }
    BluetoothPINCode pin = {};
    memcpy(pin.data, bytes.bytes, MIN(bytes.length, sizeof(pin.data)));
    [attempt.pair replyPINCode:bytes.length PINCode:&pin];
    [attempt emitStage:@"waitingPinSubmitted" message:@"PIN submitted to IOBluetooth." nativeDomain:nil nativeCode:nil nativeStage:@"pinCodeReplied"];
  }];
}

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)value {
  [self dispatchPairingCallbackStage:@"waitingConfirmation" nativeStage:@"userConfirmationRequest" sender:sender message:@"Numeric comparison requires explicit confirmation." nativeDomain:nil nativeCode:nil action:^(WearableClassicPairingAttempt *attempt) {
    [attempt prepareApplicationForPrompt];
    NSAlert *alert = [[NSAlert alloc] init];
    attempt.activePrompt = alert;
    alert.messageText = @"Confirm Bluetooth pairing";
    alert.informativeText = [NSString stringWithFormat:@"Confirm that the wearable shows %06u.", value];
    [alert addButtonWithTitle:@"Confirm"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    attempt.activePrompt = nil;
    if (attempt.finished || sender != attempt.pair) return;
    const BOOL accepted = response == NSAlertFirstButtonReturn;
    [attempt.pair replyUserConfirmation:accepted];
    if (!accepted) {
      [attempt.bridge failPairingOperation:attempt.operation code:@"pairing_user_input_cancelled" message:@"Numeric comparison was not confirmed." nativeDomain:nil nativeCode:nil stage:@"cancelled"];
      [attempt cancel];
    } else {
      [attempt emitStage:@"waitingConfirmationSubmitted" message:@"Numeric comparison accepted." nativeDomain:nil nativeCode:nil nativeStage:@"userConfirmationReplied"];
    }
  }];
}

- (void)devicePairingUserPasskeyNotification:(id)sender passkey:(BluetoothPasskey)passkey {
  (void)passkey;
  [self dispatchPairingCallbackStage:@"waitingPasskey" nativeStage:@"userPasskeyNotification" sender:sender message:@"The wearable requested a passkey entry; enter it on the device." nativeDomain:nil nativeCode:nil action:nil];
}

- (void)deviceSimplePairingComplete:(id)sender status:(BluetoothHCIEventStatus)status {
  [self dispatchPairingCallbackStage:@"simplePairingComplete" nativeStage:@"simplePairingComplete" sender:sender message:@"Simple pairing phase completed; waiting for final pairing callback." nativeDomain:@"BluetoothHCI" nativeCode:@((int32_t)status) action:nil];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
  [self dispatchPairingCallbackStage:@"pairingFinished" nativeStage:@"pairingFinished" sender:sender message:@"Classic Bluetooth pairing finished callback received." nativeDomain:@"IOReturn" nativeCode:@((int32_t)error) action:^(WearableClassicPairingAttempt *attempt) {
    const BOOL paired = [attempt.device isPaired];
    attempt.finished = YES;
    attempt.pair.delegate = nil;
    attempt.pair = nil;
    if (error != kIOReturnSuccess || !paired) {
      [attempt.bridge pairingAttempt:attempt didFinishDevice:attempt.device status:error];
      return;
    }
    [attempt.bridge completePairingOperation:attempt.operation device:attempt.device matchMode:nil source:@"pairing"];
  }];
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
  const BOOL onMainThread = NSThread.isMainThread;
  [self.bridge recordSDPCallbackEntryForDevice:device
                                        status:status
                                    generation:self.generation
                                      delegate:self
                               callbackThread:onMainThread ? @"main" : @"background"
                              callbackAtMillis:UnixMillisecondsNow()];
  if (!onMainThread) {
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
