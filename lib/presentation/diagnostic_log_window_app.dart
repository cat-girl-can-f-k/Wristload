import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../application/diagnostic_log_service.dart';
import '../application/diagnostic_log_window_coordinator.dart';
import '../application/theme_controller.dart';

enum _CategoryFilter {
  all,
  runtime,
  storage,
  communication,
  installation,
  security,
  ui,
  system,
  general,
}

enum _LevelFilter { trace, debug, info, warning, error, fatal }

class DiagnosticLogWindowApp extends StatefulWidget {
  const DiagnosticLogWindowApp({super.key});

  @override
  State<DiagnosticLogWindowApp> createState() => _DiagnosticLogWindowAppState();
}

class _DiagnosticLogWindowAppState extends State<DiagnosticLogWindowApp>
    with WindowListener {
  final WindowMethodChannel _channel = const WindowMethodChannel(
    diagnosticLogWindowChannelName,
    mode: ChannelMode.bidirectional,
  );
  final TextEditingController _searchController = TextEditingController();
  List<DiagnosticLogEntry> _entries = const [];
  DiagnosticLogCategory? _category;
  DiagnosticLogLevel _minimumLevel = DiagnosticLogLevel.trace;
  Color _themeSeedColor = ThemeController.defaultSeedColor;
  bool _persistenceEnabled = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _searchController.addListener(_refresh);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await windowManager.ensureInitialized();
      await _channel.setMethodCallHandler(_handleMainCall);
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1040, 680),
          minimumSize: Size(720, 440),
          title: 'Wristload - 诊断日志',
        ),
        () async => windowManager.setPreventClose(true),
      );
      await _channel.invokeMethod<void>('ready');
    } on Object {
      // The main engine can continue if this secondary engine closes early.
    }
  }

  Future<Object?> _handleMainCall(MethodCall call) async {
    if (call.method != 'snapshot' &&
        call.method != 'append' &&
        call.method != 'reset')
      return null;
    final values = call.arguments;
    if (values is! Map || !mounted) return true;
    final entries = <DiagnosticLogEntry>[];
    final rawEntries = values['entries'];
    if (rawEntries is List) {
      for (final value in rawEntries) {
        if (value is Map) {
          try {
            entries.add(
              DiagnosticLogEntry.fromJson(Map<String, Object?>.from(value)),
            );
          } on Object {
            // Ignore malformed records from an older engine.
          }
        }
      }
    }
    final rawSeed = values['themeSeedColor'];
    final seed = rawSeed is int ? Color(rawSeed) : null;
    setState(() {
      if (call.method == 'snapshot' || call.method == 'reset') {
        _entries = entries;
      } else {
        final rawRemoveFirst = values['removeFirst'];
        final removeFirst = rawRemoveFirst is int
            ? rawRemoveFirst.clamp(0, _entries.length).toInt()
            : 0;
        _entries = List<DiagnosticLogEntry>.of(_entries.skip(removeFirst))
          ..addAll(entries);
      }
      _persistenceEnabled = values['persistenceEnabled'] == true;
      if (seed != null) _themeSeedColor = seed;
    });
    return true;
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  List<DiagnosticLogEntry> get _filteredEntries {
    final query = _searchController.text.trim().toLowerCase();
    return _entries
        .where((entry) {
          if (entry.level.index < _minimumLevel.index) return false;
          if (_category != null && entry.category != _category) return false;
          return query.isEmpty ||
              entry.displayText.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _copyVisible() async {
    await Clipboard.setData(
      ClipboardData(
        text: _filteredEntries.map((entry) => entry.displayText).join('\n'),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 ' + _filteredEntries.length.toString() + ' 条可见日志'),
      ),
    );
  }

  Future<void> _clear() => _channel.invokeMethod<void>('clear');

  @override
  void onWindowClose() {
    // Keep the secondary engine alive so reopening the switch is instant.
    unawaited(_channel.invokeMethod<void>('closed').catchError((_) {}));
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_refresh)
      ..dispose();
    windowManager.removeListener(this);
    unawaited(_channel.setMethodCallHandler(null));
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _themeSeedColor,
      brightness: brightness,
    ),
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: _DiagnosticLogScaffold(
      entries: _entries,
      filteredEntries: _filteredEntries,
      searchController: _searchController,
      category: _category,
      minimumLevel: _minimumLevel,
      persistenceEnabled: _persistenceEnabled,
      onCategoryChanged: (value) => setState(() => _category = value),
      onMinimumLevelChanged: (value) => setState(() => _minimumLevel = value),
      onCopy: _filteredEntries.isEmpty ? null : _copyVisible,
      onClear: _entries.isEmpty ? null : _clear,
    ),
  );
}

class _DiagnosticLogScaffold extends StatelessWidget {
  const _DiagnosticLogScaffold({
    required this.entries,
    required this.filteredEntries,
    required this.searchController,
    required this.category,
    required this.minimumLevel,
    required this.persistenceEnabled,
    required this.onCategoryChanged,
    required this.onMinimumLevelChanged,
    required this.onCopy,
    required this.onClear,
  });

  final List<DiagnosticLogEntry> entries;
  final List<DiagnosticLogEntry> filteredEntries;
  final TextEditingController searchController;
  final DiagnosticLogCategory? category;
  final DiagnosticLogLevel minimumLevel;
  final bool persistenceEnabled;
  final ValueChanged<DiagnosticLogCategory?> onCategoryChanged;
  final ValueChanged<DiagnosticLogLevel> onMinimumLevelChanged;
  final Future<void> Function()? onCopy;
  final Future<void> Function()? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filteredCount = filteredEntries.length;
    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,
      appBar: AppBar(
        titleSpacing: 20,
        title: const Row(
          children: [
            Icon(Icons.manage_search_outlined),
            SizedBox(width: 10),
            Text('诊断日志'),
          ],
        ),
        actions: [
          _PersistenceStatus(enabled: persistenceEnabled),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '复制当前筛选结果',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空全部日志',
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            color: colors.surfaceContainer,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 860;
                final search = TextField(
                  controller: searchController,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: searchController.clear,
                            icon: const Icon(Icons.close),
                          ),
                    labelText: '搜索日志',
                    hintText: '消息、分类、级别或字段',
                  ),
                );
                final filters = Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CategoryMenu(
                      value: category,
                      onChanged: onCategoryChanged,
                    ),
                    _LevelMenu(
                      value: minimumLevel,
                      onChanged: onMinimumLevelChanged,
                    ),
                  ],
                );
                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [search, const SizedBox(height: 10), filters],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 12),
                    filters,
                  ],
                );
              },
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            color: colors.surfaceContainerLow,
            child: Row(
              children: [
                Icon(
                  Icons.list_alt_outlined,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  '显示 $filteredCount / ${entries.length} 条记录',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const Spacer(),
                Text(
                  '实时同步 · Trace 级别',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filteredEntries.isEmpty
                ? _EmptyLogState(hasEntries: entries.isNotEmpty)
                : SelectionArea(
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: filteredEntries.length,
                      itemBuilder: (context, index) {
                        final entry =
                            filteredEntries[filteredEntries.length - 1 - index];
                        return _LogEntryTile(entry: entry);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PersistenceStatus extends StatelessWidget {
  const _PersistenceStatus({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = enabled ? colors.primary : colors.onSurfaceVariant;
    return Tooltip(
      message: enabled ? '日志正在写入应用支持目录' : '日志仅保留在当前运行中',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              enabled ? Icons.save_outlined : Icons.memory_outlined,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              enabled ? 'JSONL 已启用' : '仅本次运行',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryMenu extends StatelessWidget {
  const _CategoryMenu({required this.value, required this.onChanged});

  final DiagnosticLogCategory? value;
  final ValueChanged<DiagnosticLogCategory?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value;
    return PopupMenuButton<_CategoryFilter>(
      tooltip: '筛选日志分类',
      onSelected: (filter) {
        onChanged(
          filter == _CategoryFilter.all
              ? null
              : DiagnosticLogCategory.values[filter.index - 1],
        );
      },
      itemBuilder: (context) => [
        _categoryItem(_CategoryFilter.all, '全部分类', selected == null),
        for (final category in DiagnosticLogCategory.values)
          _categoryItem(
            _CategoryFilter.values[category.index + 1],
            category.label,
            selected == category,
          ),
      ],
      child: _FilterButton(
        icon: Icons.category_outlined,
        label: selected?.label ?? '全部分类',
      ),
    );
  }

  PopupMenuItem<_CategoryFilter> _categoryItem(
    _CategoryFilter value,
    String label,
    bool selected,
  ) => PopupMenuItem<_CategoryFilter>(
    value: value,
    child: Row(
      children: [
        Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 18,
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    ),
  );
}

class _LevelMenu extends StatelessWidget {
  const _LevelMenu({required this.value, required this.onChanged});

  final DiagnosticLogLevel value;
  final ValueChanged<DiagnosticLogLevel> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_LevelFilter>(
    tooltip: '筛选最低严重度',
    onSelected: (filter) => onChanged(DiagnosticLogLevel.values[filter.index]),
    itemBuilder: (context) => [
      for (final level in DiagnosticLogLevel.values)
        PopupMenuItem<_LevelFilter>(
          value: _LevelFilter.values[level.index],
          child: Row(
            children: [
              _SeverityIcon(level: level, size: 18),
              const SizedBox(width: 8),
              Text('最低 ${level.label}'),
              if (level == value) ...[
                const Spacer(),
                const Icon(Icons.check, size: 18),
              ],
            ],
          ),
        ),
    ],
    child: _FilterButton(
      icon: Icons.filter_list_outlined,
      label: '最低 ${value.label}',
    ),
  );
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 18),
        ],
      ),
    );
  }
}

class _EmptyLogState extends StatelessWidget {
  const _EmptyLogState({required this.hasEntries});

  final bool hasEntries;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasEntries ? Icons.filter_alt_off_outlined : Icons.receipt_long,
            size: 40,
            color: colors.outline,
          ),
          const SizedBox(height: 12),
          Text(
            hasEntries ? '没有符合当前筛选条件的日志' : '等待日志记录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            hasEntries ? '调整搜索词、分类或最低严重度' : '通信、存储和运行时事件会显示在这里',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry});

  final DiagnosticLogEntry entry;

  Color _color(ColorScheme colors) => switch (entry.level) {
    DiagnosticLogLevel.trace => colors.outline,
    DiagnosticLogLevel.debug => colors.primary,
    DiagnosticLogLevel.info => colors.secondary,
    DiagnosticLogLevel.warning => colors.tertiary,
    DiagnosticLogLevel.error => colors.error,
    DiagnosticLogLevel.fatal => colors.onErrorContainer,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final severityColor = _color(colors);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          left: BorderSide(color: severityColor, width: 3),
          bottom: BorderSide(color: colors.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: _SeverityIcon(level: entry.level, size: 17),
            ),
            Expanded(
              child: Text(
                entry.displayText,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: entry.level.index >= DiagnosticLogLevel.error.index
                      ? severityColor
                      : colors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeverityLabel extends StatelessWidget {
  const _SeverityLabel({required this.level, required this.color});

  final DiagnosticLogLevel level;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _SeverityIcon(level: level, size: 16),
      const SizedBox(width: 5),
      Text(
        level.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _SeverityIcon extends StatelessWidget {
  const _SeverityIcon({required this.level, required this.size});

  final DiagnosticLogLevel level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = switch (level) {
      DiagnosticLogLevel.trace => Icons.radio_button_unchecked,
      DiagnosticLogLevel.debug => Icons.bug_report_outlined,
      DiagnosticLogLevel.info => Icons.info_outline,
      DiagnosticLogLevel.warning => Icons.warning_amber_outlined,
      DiagnosticLogLevel.error => Icons.error_outline,
      DiagnosticLogLevel.fatal => Icons.crisis_alert,
    };
    final colors = Theme.of(context).colorScheme;
    final color = switch (level) {
      DiagnosticLogLevel.trace => colors.outline,
      DiagnosticLogLevel.debug => colors.primary,
      DiagnosticLogLevel.info => colors.secondary,
      DiagnosticLogLevel.warning => colors.tertiary,
      DiagnosticLogLevel.error || DiagnosticLogLevel.fatal => colors.error,
    };
    return Icon(icon, size: size, color: color);
  }
}
