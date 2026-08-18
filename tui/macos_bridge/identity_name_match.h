#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *WearableCanonicalIdentityName(NSString *value) {
  NSString *trimmed = [(value ?: @"") stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return [trimmed stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)
                                      locale:NSLocale.currentLocale];
}

static inline BOOL WearableSplitTrailingHexInstance(NSString *value,
                                                     NSString *_Nullable *_Nullable baseOut) {
  if (value.length < 6 || [value characterAtIndex:value.length - 5] != ' ') return NO;
  NSString *base = [value substringToIndex:value.length - 5];
  NSString *suffix = [value substringFromIndex:value.length - 4];
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  if (base.length == 0 || suffix.length != 4 ||
      [suffix rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return NO;
  if (baseOut != nil) *baseOut = base;
  return YES;
}

// Xiaomi firmware may expose the four-hex instance suffix on either side of
// the BLE/Classic identity boundary. Accept only an exact base plus one suffix;
// callers still enforce address equality and reject ambiguous candidates.
static inline NSString *_Nullable WearableIdentityNameMatchMode(NSString *advertised,
                                                                NSString *classic) {
  NSString *wanted = WearableCanonicalIdentityName(advertised);
  NSString *actual = WearableCanonicalIdentityName(classic);
  if (wanted.length == 0 || actual.length == 0) return nil;
  if ([wanted isEqualToString:actual]) return @"exact";

  NSString *base = nil;
  if (WearableSplitTrailingHexInstance(wanted, &base) && [base isEqualToString:actual]) {
    return @"advertised_trailing_hex";
  }
  if (WearableSplitTrailingHexInstance(actual, &base) && [base isEqualToString:wanted]) {
    return @"classic_trailing_hex";
  }
  return nil;
}

static inline NSString *_Nullable WearableCanonicalBluetoothAddressKey(NSString *value) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *compact = [[[[value stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet]
      stringByReplacingOccurrencesOfString:@"-" withString:@""]
      stringByReplacingOccurrencesOfString:@":" withString:@""] uppercaseString];
  if (compact.length != 12) return nil;
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
  return [compact rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound ? compact : nil;
}

// Validate an IOBluetooth identity without confusing nameOrAddress's address
// fallback for a real device name. The address-only exception is deliberately
// gated by a short-lived permission granted by identity.resolve.
static inline NSString *_Nullable WearableIdentityDeviceMatchMode(
    NSString *advertised,
    NSString *_Nullable deviceName,
    NSString *_Nullable nameOrAddress,
    NSString *_Nullable expectedAddress,
    BOOL directedExactAddress) {
  NSString *rawName = [deviceName isKindOfClass:NSString.class] ? deviceName : nil;
  if (rawName.length != 0) {
    NSString *trimmedName = [rawName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // A non-empty all-whitespace value is a malformed real name, not an
    // unavailable name that may authorize the address-only exception.
    if (trimmedName.length == 0) return nil;
    if ([[WearableCanonicalIdentityName(trimmedName) lowercaseString] isEqualToString:@"unknown"]) return nil;
    return WearableIdentityNameMatchMode(advertised, trimmedName);
  }

  NSString *rawFallback = [nameOrAddress isKindOfClass:NSString.class] ? nameOrAddress : nil;
  NSString *fallbackAddress = nil;
  if (rawFallback.length != 0) {
    NSString *trimmedFallback = [rawFallback stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // nameOrAddress is only an address fallback when it is an actual address.
    // Whitespace is an invalid non-empty value and must never grant an
    // address-only identity match.
    if (trimmedFallback.length == 0) return nil;
    fallbackAddress = WearableCanonicalBluetoothAddressKey(trimmedFallback);
    if (fallbackAddress == nil) {
      if ([[WearableCanonicalIdentityName(trimmedFallback) lowercaseString] isEqualToString:@"unknown"]) return nil;
      return WearableIdentityNameMatchMode(advertised, trimmedFallback);
    }
  }

  NSString *expectedKey = WearableCanonicalBluetoothAddressKey(expectedAddress);
  if (!directedExactAddress || expectedKey == nil) return nil;
  if (fallbackAddress != nil && ![fallbackAddress isEqualToString:expectedKey]) return nil;
  return @"directed_exact_address_name_unavailable";
}

NS_ASSUME_NONNULL_END
