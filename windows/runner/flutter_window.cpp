#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <unordered_map>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

bool IsValidAuthKey(const std::string& value) {
  if (value.size() != 32) return false;
  for (const unsigned char character : value) {
    const bool decimal = character >= '0' && character <= '9';
    const bool lower = character >= 'a' && character <= 'f';
    const bool upper = character >= 'A' && character <= 'F';
    if (!decimal && !lower && !upper) return false;
  }
  return true;
}

std::filesystem::path LocalAppDataPath() {
  PWSTR raw_path = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw_path))) {
    throw std::runtime_error("Unable to find LocalAppData");
  }
  const std::filesystem::path path(raw_path);
  CoTaskMemFree(raw_path);
  return path;
}

std::filesystem::path AuthKeyPath() {
  const std::filesystem::path directory = LocalAppDataPath() / L"Wristload";
  std::filesystem::create_directories(directory);
  return directory / L"authkey.dpapi";
}

std::filesystem::path LegacyAuthKeyPath() {
  return LocalAppDataPath() / L"MiWearableInstallTool" / L"authkey.dpapi";
}

void WriteProtectedAuthKey(const std::string& value) {
  if (!IsValidAuthKey(value)) {
    throw std::runtime_error("Authkey must be 32 hexadecimal characters");
  }
  DATA_BLOB input{static_cast<DWORD>(value.size()),
                  reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
  DATA_BLOB protected_data{};
  if (!CryptProtectData(&input, L"Wristload authkey", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &protected_data)) {
    throw std::runtime_error("Windows DPAPI encryption failed");
  }
  const auto path = AuthKeyPath();
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(protected_data.pbData), protected_data.cbData);
  LocalFree(protected_data.pbData);
  if (!output) throw std::runtime_error("Unable to store protected authkey");
}

std::optional<std::string> ReadProtectedAuthKeyAt(
    const std::filesystem::path& path) {
  if (!std::filesystem::exists(path)) return std::nullopt;
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  const auto size = input.tellg();
  if (size <= 0 || size > 4096) {
    throw std::runtime_error("Protected authkey file has an invalid size");
  }
  std::vector<BYTE> encrypted(static_cast<size_t>(size));
  input.seekg(0);
  input.read(reinterpret_cast<char*>(encrypted.data()), encrypted.size());
  DATA_BLOB source{static_cast<DWORD>(encrypted.size()), encrypted.data()};
  DATA_BLOB plain{};
  if (!CryptUnprotectData(&source, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &plain)) {
    throw std::runtime_error("Windows DPAPI decryption failed");
  }
  std::string value(reinterpret_cast<char*>(plain.pbData), plain.cbData);
  LocalFree(plain.pbData);
  if (!IsValidAuthKey(value)) {
    throw std::runtime_error("Protected authkey payload is invalid");
  }
  return value;
}

std::optional<std::string> ReadProtectedAuthKey() {
  const auto current = ReadProtectedAuthKeyAt(AuthKeyPath());
  if (current) return current;

  const auto legacy = ReadProtectedAuthKeyAt(LegacyAuthKeyPath());
  if (legacy) WriteProtectedAuthKey(*legacy);
  return legacy;
}

void DeleteProtectedAuthKey() {
  for (const auto& path : {AuthKeyPath(), LegacyAuthKeyPath()}) {
    std::error_code error;
    std::filesystem::remove(path, error);
    if (error) throw std::runtime_error("Unable to remove protected authkey");
  }
}

void RegisterSecureStore(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "wristload/secure_store", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const auto& call, auto result) {
        try {
          if (call.method_name() == "read") {
            const auto value = ReadProtectedAuthKey();
            if (value) result->Success(flutter::EncodableValue(*value));
            else result->Success();
          } else if (call.method_name() == "write") {
            const auto* value = std::get_if<std::string>(call.arguments());
            if (value == nullptr) throw std::runtime_error("Missing secure value");
            WriteProtectedAuthKey(*value);
            result->Success();
          } else if (call.method_name() == "delete") {
            DeleteProtectedAuthKey();
            result->Success();
          } else {
            result->NotImplemented();
          }
        } catch (const std::exception& error) {
          result->Error("secure_store", error.what());
        }
      });
  // The messenger keeps the handler; this object is only a registration wrapper.
}

std::string IanaTimeZoneId(const std::string& windows_id) {
  // TimeSyncer on Android sends TimeZone.getDefault().getID(), which is an
  // IANA ID. Windows exposes CLDR's Windows ID, so translate common zones.
  static const std::unordered_map<std::string, std::string> kWindowsToIana = {
      {"UTC", "Etc/UTC"},
      {"China Standard Time", "Asia/Shanghai"},
      {"Taipei Standard Time", "Asia/Taipei"},
      {"Tokyo Standard Time", "Asia/Tokyo"},
      {"Korea Standard Time", "Asia/Seoul"},
      {"Singapore Standard Time", "Asia/Singapore"},
      {"SE Asia Standard Time", "Asia/Bangkok"},
      {"India Standard Time", "Asia/Kolkata"},
      {"Russian Standard Time", "Europe/Moscow"},
      {"GMT Standard Time", "Europe/London"},
      {"W. Europe Standard Time", "Europe/Berlin"},
      {"Romance Standard Time", "Europe/Paris"},
      {"Eastern Standard Time", "America/New_York"},
      {"Central Standard Time", "America/Chicago"},
      {"Mountain Standard Time", "America/Denver"},
      {"Pacific Standard Time", "America/Los_Angeles"},
      {"Alaskan Standard Time", "America/Anchorage"},
      {"Hawaiian Standard Time", "Pacific/Honolulu"},
      {"AUS Eastern Standard Time", "Australia/Sydney"},
      {"New Zealand Standard Time", "Pacific/Auckland"},
  };
  const auto match = kWindowsToIana.find(windows_id);
  return match == kWindowsToIana.end() ? windows_id : match->second;
}

flutter::EncodableMap ReadSystemTimeInfo() {
  DYNAMIC_TIME_ZONE_INFORMATION time_zone{};
  const DWORD state = GetDynamicTimeZoneInformation(&time_zone);
  if (state == TIME_ZONE_ID_INVALID) {
    throw std::runtime_error("Unable to read Windows time zone");
  }

  std::wstring zone_key(time_zone.TimeZoneKeyName);
  if (zone_key.empty()) zone_key = time_zone.StandardName;
  const std::string windows_id = Utf8FromUtf16(zone_key.c_str());
  if (windows_id.empty()) {
    throw std::runtime_error("Windows time zone ID is empty");
  }
  const int standard_offset = -(time_zone.Bias + time_zone.StandardBias);
  const int daylight_offset = state == TIME_ZONE_ID_DAYLIGHT
                                  ? time_zone.StandardBias - time_zone.DaylightBias
                                  : 0;

  wchar_t hour_format[8]{};
  if (GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_ITIME, hour_format,
                      static_cast<int>(std::size(hour_format))) == 0) {
    throw std::runtime_error("Unable to read Windows hour format");
  }

  flutter::EncodableMap values;
  values[flutter::EncodableValue("standardOffsetMinutes")] =
      flutter::EncodableValue(standard_offset);
  values[flutter::EncodableValue("daylightOffsetMinutes")] =
      flutter::EncodableValue(daylight_offset);
  values[flutter::EncodableValue("timezoneId")] =
      flutter::EncodableValue(IanaTimeZoneId(windows_id));
  values[flutter::EncodableValue("use24Hour")] =
      flutter::EncodableValue(hour_format[0] == L'1');
  return values;
}

void RegisterSystemTime(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "wristload/system_time",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    try {
      if (call.method_name() != "read") {
        result->NotImplemented();
        return;
      }
      result->Success(flutter::EncodableValue(ReadSystemTimeInfo()));
    } catch (const std::exception& error) {
      result->Error("system_time", error.what());
    }
  });
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // Every desktop_multi_window child engine must register the same generated
  // plugins as the primary engine before its Dart isolate starts using them.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    if (flutter_view_controller == nullptr ||
        flutter_view_controller->engine() == nullptr) {
      return;
    }
    RegisterPlugins(flutter_view_controller->engine());
  });
  RegisterSecureStore(flutter_controller_->engine()->messenger());
  RegisterSystemTime(flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
