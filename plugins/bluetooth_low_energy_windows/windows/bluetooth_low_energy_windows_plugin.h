#ifndef FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_WINDOWS_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <deque>
#include <functional>
#include <mutex>

#include "central_manager_impl.h"
#include "peripheral_manager_impl.h"

namespace bluetooth_low_energy_windows
{
	class BluetoothLowEnergyWindowsPlugin : public flutter::Plugin
	{
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

		explicit BluetoothLowEnergyWindowsPlugin(flutter::PluginRegistrarWindows *registrar);

		virtual ~BluetoothLowEnergyWindowsPlugin();

		// Disallow copy and assign.
		BluetoothLowEnergyWindowsPlugin(const BluetoothLowEnergyWindowsPlugin &) = delete;
		BluetoothLowEnergyWindowsPlugin &operator=(const BluetoothLowEnergyWindowsPlugin &) = delete;

	private:
		bool PostToPlatform(std::function<void()> task);
		std::optional<LRESULT> HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

		flutter::PluginRegistrarWindows *m_registrar;
		HWND m_window = nullptr;
		DWORD m_platform_thread_id = 0;
		UINT m_dispatch_message = 0;
		int m_window_proc_delegate_id = -1;
		std::atomic_bool m_shutting_down = false;
		std::mutex m_task_mutex;
		std::deque<std::function<void()>> m_tasks;
		std::unique_ptr<CentralManagerImpl> m_central_manager;
		std::unique_ptr<PeripheralManagerImpl> m_peripheral_manager;
	};
} // namespace bluetooth_low_energy_windows

#endif // FLUTTER_PLUGIN_BLUETOOTH_LOW_ENERGY_WINDOWS_PLUGIN_H_
