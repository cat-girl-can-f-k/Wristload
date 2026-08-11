/// Central verification switches for private protocol writes.
///
/// Authentication is mandatory before any business command. V2 auth uses
/// `f=26`/`f=27`; business protobuf then uses encrypted L2 channel 1 while Mass
/// file data uses channel 2. The controller calls [VerificationGate] before it
/// reads an install file or sends a private frame, so UI state alone can never
/// bypass the safety gate.
library;

/// Verified on a Xiaomi Smart Band 9 Pro (n67cn): RFCOMM, L1START and the
/// `sendAppVerify → sendAppConfirm` sequence.
const bool kSppAuthProtocolVerified = true;

/// Verified V2 install transport: encrypted PB control, Mass channel, ACKs and
/// completion events. RPK success still requires a matching package name in
/// the device's `20/2` response.
const bool kProtocolVerified = true;

class VerificationGate {
  const VerificationGate();

  void ensureCanSend() {
    if (!kProtocolVerified) {
      throw StateError('协议尚未通过真机 HCI 验证，禁止发送私有帧');
    }
  }
}
