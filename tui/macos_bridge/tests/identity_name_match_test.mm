#import <Foundation/Foundation.h>

#import "../identity_name_match.h"

static void ExpectMode(NSString *advertised, NSString *classic, NSString *expected) {
  NSString *actual = WearableIdentityNameMatchMode(advertised, classic);
  if ((expected == nil && actual != nil) ||
      (expected != nil && ![expected isEqualToString:actual])) {
    NSLog(@"identity match mismatch: advertised=%@ classic=%@ expected=%@ actual=%@",
          advertised, classic, expected, actual);
    abort();
  }
}

static void ExpectDeviceMode(NSString *advertised, NSString *_Nullable deviceName, NSString *_Nullable nameOrAddress,
                             NSString *expectedAddress, BOOL directed, NSString *expected) {
  NSString *actual = WearableIdentityDeviceMatchMode(advertised, deviceName, nameOrAddress,
                                                      expectedAddress, directed);
  if ((expected == nil && actual != nil) ||
      (expected != nil && ![expected isEqualToString:actual])) {
    NSLog(@"device identity match mismatch: advertised=%@ name=%@ fallback=%@ expected=%@ actual=%@",
          advertised, deviceName, nameOrAddress, expected, actual);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    ExpectMode(@"Xiaomi Smart Band 10", @"Xiaomi Smart Band 10", @"exact");
    ExpectMode(@"Xiaomi Smart Band 10", @"Xiaomi Smart Band 10 9D63",
               @"classic_trailing_hex");
    ExpectMode(@"Xiaomi Smart Band 10 9D63", @"Xiaomi Smart Band 10",
               @"advertised_trailing_hex");
    ExpectMode(@"xiaomi smart band 10", @"XIAOMI SMART BAND 10 9d63",
               @"classic_trailing_hex");

    // Prefixes and near-suffixes remain rejected.
    ExpectMode(@"Xiaomi Smart Band 10", @"Xiaomi Smart Band 10 Pro", nil);
    ExpectMode(@"Xiaomi Smart Band 10", @"Xiaomi Smart Band 10 9G63", nil);
    ExpectMode(@"Xiaomi Smart Band 10", @"Xiaomi Smart Band 10 09D63", nil);
    ExpectMode(@"Xiaomi Smart Band 10", @"Other Xiaomi Smart Band 10 9D63", nil);

    // Address-only matching is permitted only for an explicit exact-address
    // resolve intent and only when IOBluetooth exposes no usable name.
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"2C:0D:CF:70:5E:29",
                     @"2C-0D-CF-70-5E-29", YES,
                     @"directed_exact_address_name_unavailable");
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"2C:0D:CF:70:5E:28",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"2C:0D:CF:70:5E:29",
                     @"2C-0D-CF-70-5E-29", NO, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"   ", @"2C:0D:CF:70:5E:29",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"  \n\t",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", nil, nil,
                     @"2C-0D-CF-70-5E-29", YES,
                     @"directed_exact_address_name_unavailable");
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"Unknown", @"2C:0D:CF:70:5E:29",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"Other Device", @"2C:0D:CF:70:5E:29",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"not-an-address",
                     @"2C-0D-CF-70-5E-29", YES, nil);
    ExpectDeviceMode(@"Xiaomi Smart Band 10 Pro 5E29", @"", @"2C:0D:CF:70:5E:29",
                     @"bad-address", YES, nil);
  }
  return 0;
}
