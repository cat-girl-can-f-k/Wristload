#undef _HAS_EXCEPTIONS

#include "central_manager_impl.h"

namespace bluetooth_low_energy_windows
{
	CentralManagerImpl::CentralManagerImpl(flutter::BinaryMessenger *messenger, PlatformTaskPoster post_to_platform)
	{
		const auto api = CentralManagerFlutterApi(messenger);
		const auto watcher = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher();
		watcher.ScanningMode(winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEScanningMode::Active);
		m_api = api;
		m_watcher = watcher;
		m_post_to_platform = std::move(post_to_platform);
	}

	CentralManagerImpl::~CentralManagerImpl()
	{
		try
		{
			if (m_watcher.has_value() &&
				m_watcher->Status() == winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStatus::Started)
			{
				m_watcher->Stop();
			}
		}
		catch (...)
		{
		}
		m_watcher_received_revoker.reset();
		m_radio_state_changed_revoker.reset();
		m_device_connection_status_changed_revokers.clear();
		m_session_max_pdu_size_changed_revokers.clear();
		m_characteristic_value_changed_revokers.clear();
		m_api.reset();
	}

	void CentralManagerImpl::PostToPlatform(std::function<void(CentralManagerFlutterApi &)> callback)
	{
		if (!m_post_to_platform)
		{
			return;
		}
		m_post_to_platform([this, callback = std::move(callback)]() mutable
		{
			if (m_api.has_value())
			{
				callback(m_api.value());
			}
		});
	}

	void CentralManagerImpl::Initialize(std::function<void(std::optional<FlutterError> reply)> result)
	{
		InitializeAsync(std::move(result));
	}

	ErrorOr<BluetoothLowEnergyStateArgs> CentralManagerImpl::GetState()
	{
		try
		{
			const auto has_adapter = m_adapter.has_value();
			if (has_adapter)
			{
				const auto &adapter = m_adapter.value();
				const auto supported = adapter.IsCentralRoleSupported();
				if (supported)
				{
					const auto &radio = m_radio.value();
					const auto state = radio.State();
					const auto state_args = RadioStateToArgs(state);
					return state_args;
				}
			}
			return BluetoothLowEnergyStateArgs::kUnsupported;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	std::optional<FlutterError> CentralManagerImpl::StartDiscovery(const flutter::EncodableList &service_uuids_args)
	{
		try
		{
			const auto &watcher = m_watcher.value();
			const auto filter = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementFilter::BluetoothLEAdvertisementFilter();
			const auto advertisement = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisement();
			const auto service_uuids = advertisement.ServiceUuids();
			for (const auto &service_uuid_args_value : service_uuids_args)
			{
				const auto &service_uuid_args = std::get<std::string>(service_uuid_args_value);
				const auto service_uuid = winrt::guid(service_uuid_args);
				service_uuids.Append(service_uuid);
			}
			filter.Advertisement(advertisement);
			watcher.AdvertisementFilter(filter);
			watcher.Start();
			const auto generation = ++m_discovery_generation;
			PublishKnownDevicesAsync(generation);
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	std::optional<FlutterError> CentralManagerImpl::StopDiscovery()
	{
		try
		{
			++m_discovery_generation;
			const auto &watcher = m_watcher.value();
			watcher.Stop();
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::PublishKnownDevicesAsync(uint64_t generation)
	{
		try
		{
			const auto selector = winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::GetDeviceSelector();
			const auto devices = co_await winrt::Windows::Devices::Enumeration::DeviceInformation::FindAllAsync(selector);
			for (const auto &device_info : devices)
			{
				if (m_discovery_generation.load() != generation)
				{
					co_return;
				}
				const auto device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromIdAsync(device_info.Id());
				if (device == nullptr)
				{
					continue;
				}
				auto name = device.Name();
				if (name.empty())
				{
					name = device_info.Name();
				}
				const auto name_args = winrt::to_string(name);
				if (name_args.empty())
				{
					continue;
				}
				const auto address_args = static_cast<int64_t>(device.BluetoothAddress());
				const auto peripheral_args = PeripheralArgs(address_args);
				const auto advertisement_args = AdvertisementArgs(
					&name_args,
					flutter::EncodableList(),
					flutter::EncodableMap(),
					flutter::EncodableList());
				PostToPlatform([peripheral_args, advertisement_args](CentralManagerFlutterApi &api)
				{
					api.OnDiscovered(
						peripheral_args,
						0,
						0,
						AdvertisementTypeArgs::kExtended,
						advertisement_args,
						[] {},
						[](auto error) {});
				});
			}
		}
		catch (...)
		{
			// Live advertisement scanning remains active when cached enumeration is unavailable.
		}
	}

	void CentralManagerImpl::Connect(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		ConnectAsync(address_args, std::move(result));
	}

	void CentralManagerImpl::Pair(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		PairAsync(address_args, std::move(result));
	}

	void CentralManagerImpl::UnpairIfPaired(int64_t address_args, std::function<void(ErrorOr<bool> reply)> result)
	{
		UnpairIfPairedAsync(address_args, std::move(result));
	}

	void CentralManagerImpl::ConnectRfcomm(int64_t address_args, const std::string &service_uuid_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		ConnectRfcommAsync(address_args, service_uuid_args, std::move(result));
	}

	std::optional<FlutterError> CentralManagerImpl::DisconnectRfcomm(int64_t address_args)
	{
		try
		{
			{
				const std::lock_guard<std::mutex> lock(m_rfcomm_generation_mutex);
				++m_rfcomm_generations[address_args];
			}
			auto it = m_rfcomm_sockets.find(address_args);
			if (it != m_rfcomm_sockets.end() && it->second.has_value())
			{
				it->second->Close();
			}
			m_rfcomm_readers.erase(address_args);
			m_rfcomm_writers.erase(address_args);
			m_rfcomm_sockets.erase(address_args);
			auto service_it = m_rfcomm_services.find(address_args);
			if (service_it != m_rfcomm_services.end() && service_it->second.has_value())
			{
				service_it->second->Close();
			}
			m_rfcomm_services.erase(address_args);
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	void CentralManagerImpl::RfcommWrite(int64_t address_args, const std::vector<uint8_t> &data_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		RfcommWriteAsync(address_args, data_args, std::move(result));
	}

	winrt::fire_and_forget CentralManagerImpl::RfcommWriteAsync(int64_t address_args, const std::vector<uint8_t> &data_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			auto writer_it = m_rfcomm_writers.find(address_args);
			if (writer_it == m_rfcomm_writers.end() || !writer_it->second.has_value())
			{
				throw BluetoothLowEnergyException("RFCOMM writer is not connected");
			}
			auto writer = writer_it->second.value();
			writer.WriteBytes(data_args);
			co_await writer.StoreAsync();
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			DisconnectRfcomm(address_args);
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ConnectRfcommAsync(int64_t address_args, const std::string &service_uuid_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		std::string stage = "initialize";
		try
		{
			// Replace the previous WinRT objects instead of overwriting map entries.
			// Disconnect invalidates the old read loop before Close() reports EOF.
			DisconnectRfcomm(address_args);
			uint64_t generation;
			{
				const std::lock_guard<std::mutex> lock(m_rfcomm_generation_mutex);
				generation = ++m_rfcomm_generations[address_args];
			}
			// Format the 48-bit MAC into "d0:ae:05:0c:cc:f2" to match the
			// DeviceInformation.Id of RFCOMM services.
			const auto address = static_cast<uint64_t>(address_args);
			char mac_buf[18];
			snprintf(mac_buf, sizeof(mac_buf), "%02x:%02x:%02x:%02x:%02x:%02x",
				static_cast<unsigned>((address >> 40) & 0xff),
				static_cast<unsigned>((address >> 32) & 0xff),
				static_cast<unsigned>((address >> 24) & 0xff),
				static_cast<unsigned>((address >> 16) & 0xff),
				static_cast<unsigned>((address >> 8) & 0xff),
				static_cast<unsigned>(address & 0xff));
			const std::string mac(mac_buf);

			// Pairing a dual-mode wearable through BluetoothLEDevice may create only
			// a BTHLE record. That record does not prove that the BR/EDR identity or
			// its Serial Port Profile is ready, so resolve and pair both identities.
			stage = "resolve BLE identity";
			const auto ble_device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(address);
			if (ble_device == nullptr)
			{
				throw BluetoothLowEnergyException("Bluetooth device not found for address: " + mac);
			}
			stage = "read BLE pairing state";
			const auto ble_device_info = co_await winrt::Windows::Devices::Enumeration::DeviceInformation::CreateFromIdAsync(
				ble_device.BluetoothDeviceId().Id());
			auto ble_pairing = ble_device_info.Pairing();
			bool paired_now = false;
			if (!ble_pairing.IsPaired())
			{
				stage = "pair BLE identity";
				const auto pairing_result = co_await ble_pairing.PairAsync();
				const auto status = pairing_result.Status();
				if (status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::Paired &&
					status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::AlreadyPaired)
				{
					throw BluetoothLowEnergyException("RFCOMM pairing failed (status: " + std::to_string(static_cast<int>(status)) + ") - confirm the pairing on the band screen");
				}
				paired_now = status == winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::Paired;
			}
			// PairAsync can finish before Windows has published the BR/EDR identity.
			if (paired_now)
			{
				co_await winrt::resume_after(std::chrono::milliseconds(800));
			}

			winrt::Windows::Devices::Bluetooth::BluetoothDevice classic_device = nullptr;
			for (int attempt = 0; attempt < 5 && classic_device == nullptr; ++attempt)
			{
				stage = "resolve classic Bluetooth identity";
				classic_device = co_await winrt::Windows::Devices::Bluetooth::BluetoothDevice::FromBluetoothAddressAsync(address);
				if (classic_device == nullptr)
				{
					const auto classic_selector = winrt::Windows::Devices::Bluetooth::BluetoothDevice::GetDeviceSelectorFromBluetoothAddress(address);
					const auto classic_infos = co_await winrt::Windows::Devices::Enumeration::DeviceInformation::FindAllAsync(classic_selector);
					if (classic_infos.Size() > 0)
					{
						auto classic_pairing = classic_infos.GetAt(0).Pairing();
						if (!classic_pairing.IsPaired())
						{
							stage = "pair classic Bluetooth identity";
							const auto pairing_result = co_await classic_pairing.PairAsync();
							const auto status = pairing_result.Status();
							if (status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::Paired &&
								status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::AlreadyPaired)
							{
								throw BluetoothLowEnergyException("Classic Bluetooth pairing failed (status: " + std::to_string(static_cast<int>(status)) + ") - confirm pairing on the band");
							}
						}
					}
					co_await winrt::resume_after(std::chrono::milliseconds(600));
				}
			}

			if (classic_device == nullptr)
			{
				throw BluetoothLowEnergyException("Classic Bluetooth identity was not published for MAC: " + mac +
					" (Windows currently has only the BLE identity; wake the band and confirm its Bluetooth pairing prompt)");
			}
			auto classic_pairing = classic_device.DeviceInformation().Pairing();
			if (!classic_pairing.IsPaired())
			{
				stage = "pair classic Bluetooth identity";
				const auto pairing_result = co_await classic_pairing.PairAsync();
				const auto status = pairing_result.Status();
				if (status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::Paired &&
					status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::AlreadyPaired)
				{
					throw BluetoothLowEnergyException("Classic Bluetooth pairing failed (status: " + std::to_string(static_cast<int>(status)) + ") - confirm pairing on the band");
				}
				co_await winrt::resume_after(std::chrono::milliseconds(800));
			}

			const auto serial_port = winrt::Windows::Devices::Bluetooth::Rfcomm::RfcommServiceId::SerialPort();
			winrt::Windows::Devices::Bluetooth::Rfcomm::RfcommDeviceService service = nullptr;
			int last_rfcomm_error = 0;
			for (int attempt = 0; attempt < 6 && service == nullptr; ++attempt)
			{
				stage = "query target RFCOMM serial service";
				const auto services_result = co_await classic_device.GetRfcommServicesForIdAsync(
					serial_port, winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Uncached);
				last_rfcomm_error = static_cast<int>(services_result.Error());
				const auto target_services = services_result.Services();
				if (last_rfcomm_error == static_cast<int>(winrt::Windows::Devices::Bluetooth::BluetoothError::Success) &&
					target_services.Size() > 0)
				{
					service = target_services.GetAt(0);
					break;
				}
				if (attempt < 5)
				{
					co_await winrt::resume_after(std::chrono::milliseconds(600));
				}
			}
			if (service == nullptr)
			{
				throw BluetoothLowEnergyException("RFCOMM Serial Port service was not published for MAC: " + mac +
					" (BluetoothError: " + std::to_string(last_rfcomm_error) + ")");
			}
			auto socket = winrt::Windows::Networking::Sockets::StreamSocket();
			// RFCOMM advertises the protection level accepted by the service. Using
			// the two-argument overload creates a PlainSocket, which Windows may abort
			// shortly after pairing even though the initial exchange succeeded.
			stage = "connect RFCOMM socket";
			co_await socket.ConnectAsync(
				service.ConnectionHostName(),
				service.ConnectionServiceName(),
				service.MaxProtectionLevel());

			m_rfcomm_services[address_args] = service;
			m_rfcomm_sockets[address_args] = socket;
			auto reader = winrt::Windows::Storage::Streams::DataReader(socket.InputStream());
			reader.InputStreamOptions(winrt::Windows::Storage::Streams::InputStreamOptions::Partial);
			m_rfcomm_readers[address_args] = reader;
			m_rfcomm_writers[address_args] = winrt::Windows::Storage::Streams::DataWriter(socket.OutputStream());
			ReadRfcommLoop(address_args, generation);

			result(std::vector<uint8_t>{});
		}
		catch (const winrt::hresult_error &ex)
		{
			DisconnectRfcomm(address_args);
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = stage + " failed (HRESULT " +
				std::to_string(static_cast<uint32_t>(ex.code().value)) + "): " +
				winrt::to_string(winrt_message);
			result(FlutterError(code, message));
		}
		catch (const std::exception &ex)
		{
			DisconnectRfcomm(address_args);
			const auto code = "std::exception";
			const auto message = ex.what();
			result(FlutterError(code, message));
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ReadRfcommLoop(int64_t address_args, uint64_t generation)
	{
		bool ended = false;
		try
		{
			auto reader_it = m_rfcomm_readers.find(address_args);
			if (reader_it == m_rfcomm_readers.end() || !reader_it->second.has_value())
			{
				co_return;
			}
			auto reader = reader_it->second.value();
			while (true)
			{
				// Version replies and ACKs are commonly 14 bytes or smaller. The
				// default read mode waits for the full requested buffer (1024 bytes),
				// which starves Dart of every short SPP frame. Partial completes as
				// soon as any bytes are available.
				const auto size = co_await reader.LoadAsync(1024);
				if (size == 0)
				{
					ended = true;
					break;
				}
				std::vector<uint8_t> bytes(size);
				reader.ReadBytes(bytes);
				bool is_current_generation;
				{
					const std::lock_guard<std::mutex> lock(m_rfcomm_generation_mutex);
					const auto generation_it = m_rfcomm_generations.find(address_args);
					is_current_generation = generation_it != m_rfcomm_generations.end() &&
						generation_it->second == generation;
				}
				if (!is_current_generation)
				{
					co_return;
				}
				PostToPlatform([address_args, bytes](CentralManagerFlutterApi &api)
				{
					api.OnRfcommData(address_args, bytes, [] {}, [](const FlutterError &) {});
				});
			}
		}
		catch (...)
		{
			// Socket closed or read error; read loop ends.
			ended = true;
		}
		// An RFCOMM read never produces a legitimate zero-length payload. Use an
		// empty event as an explicit EOF signal so Dart learns about a remote close
		// at the time it happens instead of only on the next attempted write.
		bool is_current_generation;
		{
			const std::lock_guard<std::mutex> lock(m_rfcomm_generation_mutex);
			const auto generation_it = m_rfcomm_generations.find(address_args);
			is_current_generation = generation_it != m_rfcomm_generations.end() &&
				generation_it->second == generation;
		}
		if (ended && is_current_generation)
		{
			PostToPlatform([address_args](CentralManagerFlutterApi &api)
			{
				api.OnRfcommData(address_args, std::vector<uint8_t>{}, [] {}, [](const FlutterError &) {});
			});
		}
	}

	winrt::fire_and_forget CentralManagerImpl::PairAsync(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &device = RetrieveDevice(address_args);
			// BluetoothLEDevice has no Id()/Pairing() projection; use BluetoothDeviceId -> DeviceInformation.
			// Async: Windows shows the system pairing UI; co_await does not block the platform thread.
			const auto id_string = device.BluetoothDeviceId().Id();
			const auto device_info = co_await winrt::Windows::Devices::Enumeration::DeviceInformation::CreateFromIdAsync(id_string);
			if (device_info.Pairing().IsPaired())
			{
				result(std::nullopt);
				co_return;
			}
			const auto pairing_result = co_await device_info.Pairing().PairAsync();
			const auto status = pairing_result.Status();
			if (status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::Paired &&
				status != winrt::Windows::Devices::Enumeration::DevicePairingResultStatus::AlreadyPaired)
			{
				throw BluetoothLowEnergyException("Pair failed: status != Paired");
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::UnpairIfPairedAsync(int64_t address_args, std::function<void(ErrorOr<bool> reply)> result)
	{
		try
		{
			// GATT may be unreachable specifically because an old Windows pairing
			// is stale. Resolve from the advertised MAC instead of requiring an
			// already connected entry in m_devices.
			const auto device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(
				static_cast<uint64_t>(address_args));
			if (device == nullptr)
			{
				throw BluetoothLowEnergyException("Bluetooth device not found while checking pairing");
			}
			const auto id_string = device.BluetoothDeviceId().Id();
			const auto device_info = co_await winrt::Windows::Devices::Enumeration::DeviceInformation::CreateFromIdAsync(id_string);
			auto pairing = device_info.Pairing();
			if (!pairing.IsPaired())
			{
				result(false);
				co_return;
			}
			const auto unpair_result = co_await pairing.UnpairAsync();
			const auto status = unpair_result.Status();
			if (status != winrt::Windows::Devices::Enumeration::DeviceUnpairingResultStatus::Unpaired)
			{
				throw BluetoothLowEnergyException("Unpair failed: status != Unpaired");
			}
			OnDisconnected(address_args);
			result(true);
		}
		catch (const winrt::hresult_error &ex)
		{
			result(FlutterError("winrt::hresult_error", winrt::to_string(ex.message())));
		}
		catch (const std::exception &ex)
		{
			result(FlutterError("std::exception", ex.what()));
		}
	}

	std::optional<FlutterError> CentralManagerImpl::Disconnect(int64_t address_args)
	{
		try
		{
			OnDisconnected(address_args);
			const auto peripheral_args = PeripheralArgs(address_args);
			const auto state_args = ConnectionStateArgs::kDisconnected;
			PostToPlatform([peripheral_args, state_args](CentralManagerFlutterApi &api)
			{
				api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
			});
			return std::nullopt;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	ErrorOr<int64_t> CentralManagerImpl::GetMTU(int64_t address_args)
	{
		try
		{
			const auto &session = m_sessions[address_args].value();
			const auto mtu = session.MaxPduSize();
			const auto mtu_args = static_cast<int64_t>(mtu);
			return mtu_args;
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			return FlutterError(code, message);
		}
	}

	void CentralManagerImpl::GetServices(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetServicesAsync(address_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::GetIncludedServices(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetIncludedServicesAsync(address_args, handle_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::GetCharacteristics(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetCharacteristicsAsync(address_args, handle_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::GetDescriptors(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		GetDescriptorsAsync(address_args, handle_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::ReadCharacteristic(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		ReadCharacteristicAsync(address_args, handle_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::WriteCharacteristic(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		WriteCharacteristicAsync(address_args, handle_args, value_args, type_args, std::move(result));
	}

	void CentralManagerImpl::SetCharacteristicNotifyState(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		SetCharacteristicNotifyStateAsync(address_args, handle_args, state_args, std::move(result));
	}

	void CentralManagerImpl::ReadDescriptor(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		ReadDescriptorAsync(address_args, handle_args, mode_args, std::move(result));
	}

	void CentralManagerImpl::WriteDescriptor(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		WriteDescriptorAsync(address_args, handle_args, value_args, std::move(result));
	}

	winrt::fire_and_forget CentralManagerImpl::InitializeAsync(std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &watcher = m_watcher.value();
			const auto status = watcher.Status();
			if (status == winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcherStatus::Started)
			{
				watcher.Stop();
			}

			for (const auto &item : m_devices)
			{
				const auto address_args = item.first;
				OnDisconnected(address_args);
			}

			const auto &adapter = co_await winrt::Windows::Devices::Bluetooth::BluetoothAdapter::GetDefaultAsync();
			if (adapter != NULL)
			{
				const auto supported = adapter.IsCentralRoleSupported();
				if (supported)
				{
					const auto &radio = co_await adapter.GetRadioAsync();
					m_radio_state_changed_revoker = radio.StateChanged(
						winrt::auto_revoke,
						[this](winrt::Windows::Devices::Radios::Radio radio, auto obj)
						{
							const auto state = radio.State();
							const auto state_args = RadioStateToArgs(state);
							PostToPlatform([state_args](CentralManagerFlutterApi &api)
							{
								api.OnStateChanged(state_args, [] {}, [](auto error) {});
							});
						});
					m_radio = radio;
				}
				else
				{
					m_radio.reset();
				}
				m_adapter = adapter;
			}
			else
			{
				m_adapter.reset();
			}

			m_watcher_received_revoker = watcher.Received(
				winrt::auto_revoke,
				[this](winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher watcher, winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementReceivedEventArgs event_args)
				{
					const auto address = event_args.BluetoothAddress();
					const auto address_args = static_cast<int64_t>(address);
					const auto peripheral_args = PeripheralArgs(address_args);
					const auto rssi = event_args.RawSignalStrengthInDBm();
					const auto rssi_args = static_cast<int64_t>(rssi);
					const auto &file_timestamp = event_args.Timestamp();
					const auto timestamp = std::chrono::clock_cast<std::chrono::system_clock>(file_timestamp).time_since_epoch();
					const auto timestamp_args = std::chrono::duration_cast<std::chrono::milliseconds>(timestamp).count();
					const auto type = event_args.AdvertisementType();
					const auto type_args = AdvertisementTypeToArgs(type);
					const auto advertisement = event_args.Advertisement();
					const auto advertisement_args = AdvertisementToArgs(advertisement);
					PostToPlatform([peripheral_args, rssi_args, timestamp_args, type_args, advertisement_args](CentralManagerFlutterApi &api)
					{
						api.OnDiscovered(peripheral_args, rssi_args, timestamp_args, type_args, advertisement_args, [] {}, [](auto error) {});
					});
				});
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ConnectAsync(int64_t address_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto address = static_cast<uint64_t>(address_args);
			const auto &device = co_await winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(address);
			const auto id = device.BluetoothDeviceId();
			const auto &session = co_await winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession::FromDeviceIdAsync(id);
			// Creating a BluetoothLEDevice object by calling this method alone doesn't (necessarily) initiate a
			// connection. To initiate a connection, set GattSession.MaintainConnection to true, or call an
			// uncached service discovery method on BluetoothLEDevice, or perform a read/write operation against
			// the device.
			// See：https://learn.microsoft.com/en-us/windows/uwp/devices-sensors/gatt-client#connecting-to-the-device
			const auto &r = co_await device.GetGattServicesAsync(winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Uncached);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Connect failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto peripheral_args = PeripheralArgs(address_args);
			const auto state_args = ConnectionStateArgs::kConnected;
			const auto mtu = session.MaxPduSize();
			const auto mtu_args = static_cast<int64_t>(mtu);
			PostToPlatform([peripheral_args, state_args, mtu_args](CentralManagerFlutterApi &api)
			{
				api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
				api.OnMTUChanged(peripheral_args, mtu_args, [] {}, [](auto error) {});
			});
			m_device_connection_status_changed_revokers[address_args] = device.ConnectionStatusChanged(
				winrt::auto_revoke,
				[this, address_args](winrt::Windows::Devices::Bluetooth::BluetoothLEDevice device, auto obj)
				{
					const auto status = device.ConnectionStatus();
					if (status == winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Disconnected)
					{
						OnDisconnected(address_args);
					}
					const auto peripheral_args = PeripheralArgs(address_args);
					const auto state_args = ConnectionStatusToArgs(status);
					PostToPlatform([peripheral_args, state_args](CentralManagerFlutterApi &api)
					{
						api.OnConnectionStateChanged(peripheral_args, state_args, [] {}, [](auto error) {});
					});
				});
			m_session_max_pdu_size_changed_revokers[address_args] = session.MaxPduSizeChanged(
				winrt::auto_revoke,
				[this, peripheral_args](winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession session, auto obj)
				{
					const auto mtu = session.MaxPduSize();
					const auto mtu_args = static_cast<int64_t>(mtu);
					PostToPlatform([peripheral_args, mtu_args](CentralManagerFlutterApi &api)
					{
						api.OnMTUChanged(peripheral_args, mtu_args, [] {}, [](auto error) {});
					});
				});
			m_devices[address_args] = device;
			m_sessions[address_args] = session;
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetServicesAsync(int64_t address_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &device = RetrieveDevice(address_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await device.GetGattServicesAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get services failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto services = r.Services();
			auto services_args = flutter::EncodableList();
			for (const auto service : services)
			{
				const auto service_args = ServiceToArgs(service);
				const auto service_args_value = flutter::CustomEncodableValue(service_args);
				const auto service_handle_args = service_args.handle_args();
				m_services[address_args][service_handle_args] = service;
				services_args.emplace_back(service_args_value);
			}
			result(services_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetIncludedServicesAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &service = RetrieveService(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await service.GetIncludedServicesAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get included services failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto included_services = r.Services();
			auto included_services_args = flutter::EncodableList();
			for (const auto included_service : included_services)
			{
				const auto service_args = ServiceToArgs(included_service);
				const auto service_args_value = flutter::CustomEncodableValue(service_args);
				const auto service_handle_args = service_args.handle_args();
				m_services[address_args][service_handle_args] = included_service;
				included_services_args.emplace_back(service_args_value);
			}
			result(included_services_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetCharacteristicsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &service = RetrieveService(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await service.GetCharacteristicsAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get characteristics failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto characteristics = r.Characteristics();
			auto characteristics_args = flutter::EncodableList();
			for (const auto characteristic : characteristics)
			{
				const auto characteristic_args = CharacteristicToArgs(characteristic);
				const auto characteristic_args_value = flutter::CustomEncodableValue(characteristic_args);
				const auto characteristic_handle_args = characteristic_args.handle_args();
				m_characteristic_value_changed_revokers[address_args][characteristic_handle_args] = characteristic.ValueChanged(
					winrt::auto_revoke,
					[this, address_args](const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &characteristic, const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattValueChangedEventArgs &event_args)
					{
						const auto peripheral_args = PeripheralArgs(address_args);
						const auto characteristic_args = CharacteristicToArgs(characteristic);
						const auto value = event_args.CharacteristicValue();
						const auto value_length = value.Length();
						auto value_args = std::vector<uint8_t>(value_length);
						const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
						value_reader.ReadBytes(value_args);
						PostToPlatform([peripheral_args, characteristic_args, value_args](CentralManagerFlutterApi &api)
						{
							api.OnCharacteristicNotified(peripheral_args, characteristic_args, value_args, []() {}, [](const auto &error) {});
						});
					});
				m_characteristics[address_args][characteristic_handle_args] = characteristic;
				characteristics_args.emplace_back(characteristic_args_value);
			}
			result(characteristics_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::GetDescriptorsAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<flutter::EncodableList> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await characteristic.GetDescriptorsAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Get descriptors failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto descriptors = r.Descriptors();
			auto descriptors_args = flutter::EncodableList();
			for (const auto descriptor : descriptors)
			{
				const auto descriptor_args = DescriptorToArgs(descriptor);
				const auto descriptor_args_value = flutter::CustomEncodableValue(descriptor_args);
				const auto descriptor_handle_args = descriptor_args.handle_args();
				m_descriptors[address_args][descriptor_handle_args] = descriptor;
				descriptors_args.emplace_back(descriptor_args_value);
			}
			result(descriptors_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ReadCharacteristicAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await characteristic.ReadValueAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Read characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto value = r.Value();
			const auto value_length = value.Length();
			auto value_args = std::vector<uint8_t>(value_length);
			const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
			value_reader.ReadBytes(value_args);
			result(value_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::WriteCharacteristicAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, const GATTCharacteristicWriteTypeArgs &type_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto value_writer = winrt::Windows::Storage::Streams::DataWriter();
			value_writer.WriteBytes(value_args);
			const auto value = value_writer.DetachBuffer();
			const auto option = ArgsToWriteOption(type_args);
			const auto status = co_await characteristic.WriteValueAsync(value, option);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Write characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::SetCharacteristicNotifyStateAsync(int64_t address_args, int64_t handle_args, const GATTCharacteristicNotifyStateArgs &state_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &characteristic = RetrieveCharacteristic(address_args, handle_args);
			const auto value = ArgsToCCCDescriptorValue(state_args);
			const auto status = co_await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(value);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Notify characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::ReadDescriptorAsync(int64_t address_args, int64_t handle_args, const CacheModeArgs &mode_args, std::function<void(ErrorOr<std::vector<uint8_t>> reply)> result)
	{
		try
		{
			const auto &descriptor = RetrieveDescriptor(address_args, handle_args);
			const auto mode = ArgsToCacheMode(mode_args);
			const auto &r = co_await descriptor.ReadValueAsync(mode);
			const auto status = r.Status();
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Read descriptor failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			const auto value = r.Value();
			const auto value_length = value.Length();
			auto value_args = std::vector<uint8_t>(value_length);
			const auto value_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(value);
			value_reader.ReadBytes(value_args);
			result(value_args);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	winrt::fire_and_forget CentralManagerImpl::WriteDescriptorAsync(int64_t address_args, int64_t handle_args, const std::vector<uint8_t> &value_args, std::function<void(std::optional<FlutterError> reply)> result)
	{
		try
		{
			const auto &descriptor = RetrieveDescriptor(address_args, handle_args);
			const auto value_writer = winrt::Windows::Storage::Streams::DataWriter();
			value_writer.WriteBytes(value_args);
			const auto value = value_writer.DetachBuffer();
			const auto status = co_await descriptor.WriteValueAsync(value);
			if (status != winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCommunicationStatus::Success)
			{
				const auto status_code = static_cast<int>(status);
				const auto message = "Write characteristic failed with status: " + std::to_string(status_code);
				throw BluetoothLowEnergyException(message);
			}
			result(std::nullopt);
		}
		catch (const winrt::hresult_error &ex)
		{
			const auto code = "winrt::hresult_error";
			const auto winrt_message = ex.message();
			const auto message = winrt::to_string(winrt_message);
			const auto error = FlutterError(code, message);
			result(error);
		}
		catch (const std::exception &ex)
		{
			const auto code = "std::exception";
			const auto message = ex.what();
			const auto error = FlutterError(code, message);
			result(error);
		}
	}

	void CentralManagerImpl::OnDisconnected(int64_t address_args)
	{
		m_device_connection_status_changed_revokers.erase(address_args);
		m_session_max_pdu_size_changed_revokers.erase(address_args);
		m_characteristic_value_changed_revokers.erase(address_args);
		m_devices.erase(address_args);
		m_sessions.erase(address_args);
		m_services.erase(address_args);
		m_characteristics.erase(address_args);
		m_descriptors.erase(address_args);
	}

	winrt::Windows::Devices::Bluetooth::BluetoothLEDevice &CentralManagerImpl::RetrieveDevice(int64_t address_args)
	{
		return m_devices[address_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &CentralManagerImpl::RetrieveService(int64_t address_args, int64_t handle_args)
	{
		return m_services[address_args][handle_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &CentralManagerImpl::RetrieveCharacteristic(int64_t address_args, int64_t handle_args)
	{
		return m_characteristics[address_args][handle_args].value();
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &CentralManagerImpl::RetrieveDescriptor(int64_t address_args, int64_t handle_args)
	{
		return m_descriptors[address_args][handle_args].value();
	}

	BluetoothLowEnergyStateArgs CentralManagerImpl::RadioStateToArgs(const winrt::Windows::Devices::Radios::RadioState &state)
	{
		switch (state)
		{
		case winrt::Windows::Devices::Radios::RadioState::Unknown:
			return BluetoothLowEnergyStateArgs::kUnknown;
		case winrt::Windows::Devices::Radios::RadioState::Disabled:
			return BluetoothLowEnergyStateArgs::kDisabled;
		case winrt::Windows::Devices::Radios::RadioState::Off:
			return BluetoothLowEnergyStateArgs::kOff;
		case winrt::Windows::Devices::Radios::RadioState::On:
			return BluetoothLowEnergyStateArgs::kOn;
		default:
			return BluetoothLowEnergyStateArgs::kUnknown;
		}
	}

	AdvertisementTypeArgs CentralManagerImpl::AdvertisementTypeToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType &type)
	{
		switch (type)
		{
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ConnectableUndirected:
			return AdvertisementTypeArgs::kConnectableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ConnectableDirected:
			return AdvertisementTypeArgs::kConnectableDirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ScannableUndirected:
			return AdvertisementTypeArgs::kScannableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::NonConnectableUndirected:
			return AdvertisementTypeArgs::kNonConnectableUndirected;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::ScanResponse:
			return AdvertisementTypeArgs::kScanResponse;
		case winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementType::Extended:
			return AdvertisementTypeArgs::kExtended;
		default:
			throw std::bad_cast();
		}
	}

	ConnectionStateArgs CentralManagerImpl::ConnectionStatusToArgs(const winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus &status)
	{
		switch (status)
		{
		case winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Disconnected:
			return ConnectionStateArgs::kDisconnected;
		case winrt::Windows::Devices::Bluetooth::BluetoothConnectionStatus::Connected:
			return ConnectionStateArgs::kConnected;
		default:
			throw std::bad_cast();
		}
	}

	ManufacturerSpecificDataArgs CentralManagerImpl::ManufacturerDataToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEManufacturerData &manufacturer_data)
	{
		const auto id = manufacturer_data.CompanyId();
		const auto id_args = static_cast<int64_t>(id);
		const auto data = manufacturer_data.Data();
		const auto data_length = data.Length();
		auto data_args = std::vector<uint8_t>(data_length);
		const auto data_reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(data);
		data_reader.ReadBytes(data_args);
		return ManufacturerSpecificDataArgs(id_args, data_args);
	}

	AdvertisementArgs CentralManagerImpl::AdvertisementToArgs(const winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisement &advertisement)
	{
		const auto name = advertisement.LocalName();
		const auto name_args = winrt::to_string(name);
		const auto service_uuids = advertisement.ServiceUuids();
		auto service_uuids_args = flutter::EncodableList();
		for (const auto &service_uuid : service_uuids)
		{
			const auto service_uuid_args = GUIDToArgs(service_uuid);
			service_uuids_args.emplace_back(service_uuid_args);
		}
		const auto data_sections = advertisement.DataSections();
		auto service_data_args = flutter::EncodableMap();
		for (const auto data_section : data_sections)
		{
			const auto section_type = data_section.DataType();
			const auto section_buffer = data_section.Data();
			const auto section_data_length = section_buffer.Length();
			const auto type16 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData16BitUuids();
			const auto type32 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData32BitUuids();
			const auto type128 = winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataTypes::ServiceData128BitUuids();
			if (section_type == type16 && section_data_length > 2)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint16_t();
				std::memcpy(&data1, section_data, 2Ui64);
				const auto uuid_args = std::format("{:04X}", data1);
				const auto data_args = std::vector<uint8_t>(section_data + 2, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
			else if (section_type == type32 && section_data_length > 4)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint32_t();
				std::memcpy(&data1, section_data, 4Ui64);
				const auto uuid_args = std::format("{:08X}", data1);
				const auto data_args = std::vector<uint8_t>(section_data + 4, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
			else if (section_type == type128 && section_data_length > 16)
			{
				const auto section_data = section_buffer.data();
				auto data1 = uint32_t();
				std::memcpy(&data1, section_data, 4Ui64);
				auto data2 = uint16_t();
				std::memcpy(&data2, section_data + 4, 2Ui64);
				auto data3 = uint16_t();
				std::memcpy(&data3, section_data + 6, 2Ui64);
				auto data4 = std::array<uint8_t, 8Ui64>();
				std::memcpy(&data4, section_data + 8, 8Ui64);
				const auto uuid = winrt::guid(data1, data2, data3, data4);
				const auto uuid_args = GUIDToArgs(uuid);
				const auto data_args = std::vector<uint8_t>(section_data + 16, section_data + section_data_length);
				service_data_args[uuid_args] = data_args;
			}
		}
		const auto manufacturer_data = advertisement.ManufacturerData();
		auto manufacturer_specific_data_args = flutter::EncodableList();
		for (const auto &data : manufacturer_data)
		{
			const auto data_args = ManufacturerDataToArgs(data);
			const auto data_args_value = flutter::CustomEncodableValue(data_args);
			manufacturer_specific_data_args.emplace_back(data_args_value);
		}
		return AdvertisementArgs(&name_args, service_uuids_args, service_data_args, manufacturer_specific_data_args);
	}

	GATTServiceArgs CentralManagerImpl::ServiceToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService &service)
	{
		const auto handle = service.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = service.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		const auto is_primary_args = true;
		const auto included_services_args = flutter::EncodableList();
		const auto characteristics_args = flutter::EncodableList();
		return GATTServiceArgs(handle_args, uuid_args, is_primary_args, included_services_args, characteristics_args);
	}

	GATTCharacteristicArgs CentralManagerImpl::CharacteristicToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic &characteristic)
	{
		const auto handle = characteristic.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = characteristic.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		const auto properties = characteristic.CharacteristicProperties();
		const auto property_numbers_args = CharacteristicPropertiesToArgs(properties);
		const auto descriptors_args = flutter::EncodableList();
		return GATTCharacteristicArgs(handle_args, uuid_args, property_numbers_args, descriptors_args);
	}

	flutter::EncodableList CentralManagerImpl::CharacteristicPropertiesToArgs(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties properties)
	{
		const auto readable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Read);
		const auto writable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Write);
		const auto writableWithoutResponse = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::WriteWithoutResponse);
		const auto notifiable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Notify);
		const auto indicatable = static_cast<int>(properties & winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristicProperties::Indicate);
		auto property_numbers_args = flutter::EncodableList();
		if (readable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kRead);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (writable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kWrite);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (writableWithoutResponse)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kWriteWithoutResponse);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (notifiable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kNotify);
			property_numbers_args.emplace_back(property_number_args);
		}
		if (indicatable)
		{
			const auto property_number_args = static_cast<int>(GATTCharacteristicPropertyArgs::kIndicate);
			property_numbers_args.emplace_back(property_number_args);
		}
		return property_numbers_args;
	}

	GATTDescriptorArgs CentralManagerImpl::DescriptorToArgs(const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDescriptor &descriptor)
	{
		const auto handle = descriptor.AttributeHandle();
		const auto handle_args = static_cast<int64_t>(handle);
		const auto uuid = descriptor.Uuid();
		const auto uuid_args = GUIDToArgs(uuid);
		return GATTDescriptorArgs(handle_args, uuid_args);
	}

	std::string CentralManagerImpl::GUIDToArgs(const winrt::guid &guid)
	{
		// const auto uuid_value = winrt::to_hstring(uuid);
		// return winrt::to_string(uuid_value);
		return std::format("{}", guid);
	}

	winrt::Windows::Devices::Bluetooth::BluetoothCacheMode CentralManagerImpl::ArgsToCacheMode(const CacheModeArgs &mode_args)
	{
		switch (mode_args)
		{
		case CacheModeArgs::kCached:
			return winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Cached;
		case CacheModeArgs::kUncached:
			return winrt::Windows::Devices::Bluetooth::BluetoothCacheMode::Uncached;
		default:
			throw std::bad_cast();
		}
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption CentralManagerImpl::ArgsToWriteOption(const GATTCharacteristicWriteTypeArgs &type_args)
	{
		switch (type_args)
		{
		case GATTCharacteristicWriteTypeArgs::kWithoutResponse:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption::WriteWithoutResponse;
		case GATTCharacteristicWriteTypeArgs::kWithResponse:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattWriteOption::WriteWithResponse;
		default:
			throw std::bad_cast();
		}
	}

	winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue CentralManagerImpl::ArgsToCCCDescriptorValue(const GATTCharacteristicNotifyStateArgs &state_args)
	{
		switch (state_args)
		{
		case GATTCharacteristicNotifyStateArgs::kNone:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::None;
		case GATTCharacteristicNotifyStateArgs::kNotify:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::Notify;
		case GATTCharacteristicNotifyStateArgs::kIndicate:
			return winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattClientCharacteristicConfigurationDescriptorValue::Indicate;
		default:
			throw std::bad_cast();
		}
	}
}
