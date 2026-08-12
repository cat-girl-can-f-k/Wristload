#include "bluetooth_low_energy_windows_plugin.h"

namespace bluetooth_low_energy_windows
{
	// static
	void BluetoothLowEnergyWindowsPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar)
	{
		auto messenger = registrar->messenger();
		auto plugin = std::make_unique<BluetoothLowEnergyWindowsPlugin>(registrar);
		CentralManagerHostApi::SetUp(messenger, plugin->m_central_manager.get());
		PeripheralManagerHostApi::SetUp(messenger, plugin->m_peripheral_manager.get());
		registrar->AddPlugin(std::move(plugin));
	}

	BluetoothLowEnergyWindowsPlugin::BluetoothLowEnergyWindowsPlugin(flutter::PluginRegistrarWindows *registrar)
		: m_registrar(registrar),
		  m_platform_thread_id(GetCurrentThreadId()),
		  m_dispatch_message(RegisterWindowMessageW(L"Wristload.BluetoothLowEnergy.PlatformDispatch.v1"))
	{
		if (auto view = registrar->GetView())
		{
			const auto flutter_window = view->GetNativeWindow();
			m_window = GetAncestor(flutter_window, GA_ROOT);
			if (!m_window)
			{
				m_window = flutter_window;
			}
		}
		m_window_proc_delegate_id = registrar->RegisterTopLevelWindowProcDelegate(
			[this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
			{
				return HandleWindowMessage(hwnd, message, wparam, lparam);
			});
		auto messenger = registrar->messenger();
		m_central_manager = std::make_unique<CentralManagerImpl>(messenger,
			[this](std::function<void()> task) { return PostToPlatform(std::move(task)); });
		m_peripheral_manager = std::make_unique<PeripheralManagerImpl>(messenger);
	}

	BluetoothLowEnergyWindowsPlugin::~BluetoothLowEnergyWindowsPlugin()
	{
		m_shutting_down = true;
		m_central_manager.reset();
		m_peripheral_manager.reset();
		{
			const std::lock_guard<std::mutex> lock(m_task_mutex);
			m_tasks.clear();
		}
		if (m_window_proc_delegate_id >= 0)
		{
			m_registrar->UnregisterTopLevelWindowProcDelegate(m_window_proc_delegate_id);
		}
	}

	bool BluetoothLowEnergyWindowsPlugin::PostToPlatform(std::function<void()> task)
	{
		if (m_shutting_down)
		{
			return false;
		}
		if (GetCurrentThreadId() == m_platform_thread_id)
		{
			task();
			return true;
		}
		{
			const std::lock_guard<std::mutex> lock(m_task_mutex);
			if (m_shutting_down)
			{
				return false;
			}
			m_tasks.emplace_back(std::move(task));
		}
		if (!m_window || !PostMessageW(m_window, m_dispatch_message, 0, 0))
		{
			const std::lock_guard<std::mutex> lock(m_task_mutex);
			if (!m_tasks.empty())
			{
				m_tasks.pop_back();
			}
			return false;
		}
		return true;
	}

	std::optional<LRESULT> BluetoothLowEnergyWindowsPlugin::HandleWindowMessage(
		HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
	{
		if (message != m_dispatch_message)
		{
			return std::nullopt;
		}
		std::deque<std::function<void()>> tasks;
		{
			const std::lock_guard<std::mutex> lock(m_task_mutex);
			tasks.swap(m_tasks);
		}
		if (!m_shutting_down)
		{
			for (auto &task : tasks)
			{
				task();
			}
		}
		return 0;
	}
} // namespace bluetooth_low_energy_windows
