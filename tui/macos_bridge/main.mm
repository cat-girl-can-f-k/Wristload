#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

#include <dispatch/dispatch.h>
#include <iostream>
#include <string>
#include <thread>

static NSString *const kCommandKey = @"command";
static NSString *const kRequestIDKey = @"requestId";
static const NSUInteger kMaximumWriteBytes = 256 * 1024;

@interface WearableBluetoothBridge : NSObject <IOBluetoothDeviceInquiryDelegate, IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, strong) IOBluetoothDeviceInquiry *inquiry;
@property(nonatomic, copy) NSString *scanID;
@property(nonatomic, copy) NSString *scanRequestID;
@property(nonatomic, copy) NSString *scanStopRequestID;

@property(nonatomic, strong) IOBluetoothDevice *pendingDevice;
@property(nonatomic, strong) IOBluetoothSDPUUID *pendingServiceUUID;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *openingChannel;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, copy) NSString *activeConnectionID;
@property(nonatomic, copy) NSString *activeConnectRequestID;
@property(nonatomic, copy) NSString *activeAddress;
@property(nonatomic, copy) NSString *activeAddressKey;
@property(nonatomic, copy) NSString *disconnectRequestID;
@property(nonatomic, assign) uint64_t attemptGeneration;
@property(nonatomic, assign) uint64_t openingGeneration;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, strong) IOBluetoothDevice *sdpDrainDevice;
@property(nonatomic, copy) NSString *sdpDrainAddressKey;
@property(nonatomic, assign) BOOL sdpDrainPending;
@property(nonatomic, copy) NSString *helperSessionID;
@end

@implementation WearableBluetoothBridge

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _helperSessionID = NSUUID.UUID.UUIDString;
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

  if ([name isEqualToString:@"hello"]) [self hello:requestID];
  else if ([name isEqualToString:@"paired.list"]) [self listPaired:requestID];
  else if ([name isEqualToString:@"scan.start"]) [self startScan:command requestID:requestID];
  else if ([name isEqualToString:@"scan.stop"]) [self stopScan:command requestID:requestID];
  else if ([name isEqualToString:@"connect"]) [self connect:command requestID:requestID];
  else if ([name isEqualToString:@"write"]) [self write:command requestID:requestID];
  else if ([name isEqualToString:@"disconnect"]) [self disconnect:command requestID:requestID];
  else [self emitError:@"invalid_command" message:[NSString stringWithFormat:@"Unsupported command: %@", name] requestID:requestID connectionID:nil];
}

- (void)hello:(NSString *)requestID {
  [self emit:@{ @"event": @"hello.done", @"requestId": requestID, @"protocolVersion": @1, @"helperSessionId": self.helperSessionID }];
}

- (void)listPaired:(NSString *)requestID {
  NSMutableArray *devices = [NSMutableArray array];
  for (IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices) {
    NSString *key = [self addressKeyFromString:device.addressString];
    NSString *address = [self displayAddressForKey:key];
    if (key == nil || address == nil) continue;
    NSMutableDictionary *entry = [@{ @"address": address, @"addressKey": key, @"paired": @YES } mutableCopy];
    if (device.name != nil) entry[@"name"] = device.name;
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
  IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:apiAddress];
  if (device == nil) {
    [self emitError:@"device_not_found" message:@"macOS could not create an IOBluetoothDevice for this address." requestID:requestID connectionID:connectionID];
    return;
  }
  if (self.sdpDrainPending && [key isEqualToString:self.sdpDrainAddressKey]) {
    [self emitError:@"sdp_drain_required"
             message:@"The previous SDP query for this device has not delivered its terminal callback; restart the helper before reconnecting it."
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
  ++self.attemptGeneration;
  IOReturn status = [device performSDPQuery:self uuids:@[ serviceUUID ]];
  if (status != kIOReturnSuccess) {
    [self endConnectionWithReason:@"error" errorCode:@"sdp_start_failed" message:[NSString stringWithFormat:@"Could not start SDP query: 0x%08x", status] requestID:requestID];
  }
}

- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self sdpQueryComplete:device status:status]; }); return; }
  if (self.sdpDrainPending && device == self.sdpDrainDevice) {
    self.sdpDrainPending = NO;
    self.sdpDrainDevice = nil;
    self.sdpDrainAddressKey = nil;
    return;
  }
  if (device != self.pendingDevice || self.activeConnectionID == nil) return;
  const uint64_t generation = self.attemptGeneration;
  NSString *requestID = self.activeConnectRequestID;
  NSString *connectionID = self.activeConnectionID;
  if (status != kIOReturnSuccess) {
    [self endConnectionWithReason:@"error" errorCode:@"sdp_query_failed" message:[NSString stringWithFormat:@"SDP query failed: 0x%08x", status] requestID:requestID];
    return;
  }
  IOBluetoothSDPServiceRecord *selected = nil;
  for (IOBluetoothSDPServiceRecord *record in device.services) {
    if ([record matchesUUIDArray:@[ self.pendingServiceUUID ]]) {
      BluetoothRFCOMMChannelID channelID = 0;
      if ([record getRFCOMMChannelID:&channelID] == kIOReturnSuccess) { selected = record; break; }
    }
  }
  if (selected == nil) {
    [self endConnectionWithReason:@"error" errorCode:@"rfcomm_service_not_found" message:@"The requested SDP service has no RFCOMM channel." requestID:requestID];
    return;
  }
  BluetoothRFCOMMChannelID channelID = 0;
  [selected getRFCOMMChannelID:&channelID];
  IOBluetoothRFCOMMChannel *channel = nil;
  IOReturn openStatus = [device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self];
  if (generation != self.attemptGeneration || ![connectionID isEqualToString:self.activeConnectionID]) {
    if (channel != nil) [channel closeChannel];
    return;
  }
  self.pendingDevice = nil;
  self.pendingServiceUUID = nil;
  if (openStatus != kIOReturnSuccess || channel == nil) {
    [self endConnectionWithReason:@"error" errorCode:@"rfcomm_open_start_failed" message:[NSString stringWithFormat:@"Could not start RFCOMM channel %u: 0x%08x", channelID, openStatus] requestID:requestID];
    return;
  }
  self.openingChannel = channel;
  self.openingGeneration = generation;
}

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel status:(IOReturn)status {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self rfcommChannelOpenComplete:rfcommChannel status:status]; }); return; }
  if (rfcommChannel != self.openingChannel || self.openingGeneration != self.attemptGeneration || self.activeConnectionID == nil) {
    if (status == kIOReturnSuccess) [rfcommChannel closeChannel];
    return;
  }
  NSString *requestID = self.activeConnectRequestID;
  NSString *connectionID = self.activeConnectionID;
  self.openingChannel = nil;
  if (status != kIOReturnSuccess) {
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
  ++self.attemptGeneration;
  if (self.channel == nil) {
    if (self.pendingDevice != nil) {
      self.sdpDrainDevice = self.pendingDevice;
      self.sdpDrainAddressKey = self.activeAddressKey;
      self.sdpDrainPending = YES;
    }
    [self endConnectionWithReason:@"local" errorCode:nil message:nil requestID:nil];
    return;
  }
  self.closing = YES;
  IOReturn status = [self.channel closeChannel];
  if (status != kIOReturnSuccess) {
    [self endConnectionWithReason:@"error" errorCode:@"disconnect_failed" message:[NSString stringWithFormat:@"Could not close RFCOMM channel: 0x%08x", status] requestID:requestID];
  }
}

- (void)endConnectionWithReason:(NSString *)reason errorCode:(NSString *)errorCode message:(NSString *)message requestID:(NSString *)requestID {
  NSCAssert(NSThread.isMainThread, @"Connection state must run on main thread");
  NSString *connectionID = self.activeConnectionID;
  if (connectionID == nil) return;
  NSString *address = self.activeAddress ?: @"";
  NSString *addressKey = self.activeAddressKey ?: @"";
  NSString *disconnectRequestID = self.disconnectRequestID;
  ++self.attemptGeneration;
  self.pendingDevice = nil; self.pendingServiceUUID = nil; self.openingChannel = nil; self.channel = nil;
  self.activeConnectionID = nil; self.activeConnectRequestID = nil; self.activeAddress = nil; self.activeAddressKey = nil;
  self.disconnectRequestID = nil; self.closing = NO;
  if (errorCode != nil) [self emitError:errorCode message:message requestID:requestID connectionID:connectionID];
  [self emit:@{ @"event": @"closed", @"connectionId": connectionID, @"address": address, @"addressKey": addressKey, @"reason": reason }];
  if (disconnectRequestID != nil && ![disconnectRequestID isEqualToString:requestID]) {
    [self emit:@{ @"event": @"disconnect.done", @"requestId": disconnectRequestID, @"connectionId": connectionID }];
  }
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self deviceInquiryDeviceFound:sender device:device]; }); return; }
  if (sender != self.inquiry || self.scanID == nil) return;
  NSDictionary *event = [self deviceEventForDevice:device source:@"inquiry" scanID:self.scanID];
  if ([event[@"addressKey"] length] != 0) [self emit:event];
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
  [self endConnectionWithReason:self.closing ? @"local" : @"remote" errorCode:nil message:nil requestID:nil];
}

- (void)shutdownForEOF {
  NSCAssert(NSThread.isMainThread, @"EOF shutdown must run on main thread");
  if (self.inquiry != nil) [self.inquiry stop];
  if (self.channel != nil) [self.channel closeChannel];
  ++self.attemptGeneration;
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
