import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/install_preference_store.dart';
import 'install_preference_selector.dart';
import 'oobe_install_preview.dart';

class OobePage extends StatefulWidget {
  const OobePage({
    required this.installPreference,
    required this.onInstallPreferenceChanged,
    required this.onCompleted,
    super.key,
  });

  final InstallPreference installPreference;
  final ValueChanged<InstallPreference> onInstallPreferenceChanged;
  final Future<void> Function() onCompleted;

  @override
  State<OobePage> createState() => _OobePageState();
}

class _OobePageState extends State<OobePage> {
  static const _pageCount = 3;
  static const _pageDuration = Duration(milliseconds: 450);

  final PageController _pageController = PageController();
  late InstallPreference _installPreference;
  int _page = 0;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    _installPreference = widget.installPreference;
  }

  @override
  void didUpdateWidget(covariant OobePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.installPreference != oldWidget.installPreference) {
      _installPreference = widget.installPreference;
    }
  }

  void _setInstallPreference(InstallPreference preference) {
    if (_installPreference == preference) return;
    setState(() => _installPreference = preference);
    widget.onInstallPreferenceChanged(preference);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _goTo(int page) async {
    if (page < 0 || page >= _pageCount || _completing) return;
    await _pageController.animateToPage(
      page,
      duration: _pageDuration,
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  Future<void> _next() async {
    if (_page < _pageCount - 1) {
      await _goTo(_page + 1);
      return;
    }
    setState(() => _completing = true);
    try {
      await widget.onCompleted();
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                key: const ValueKey('oobe-page-view'),
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  const _WelcomePage(),
                  _PreferencePage(
                    value: _installPreference,
                    onChanged: _setInstallPreference,
                  ),
                  const _ReadyPage(),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 148,
                          child: _page == 0
                              ? null
                              : TextButton.icon(
                                  key: const ValueKey('oobe-previous'),
                                  onPressed: _completing
                                      ? null
                                      : () => unawaited(_goTo(_page - 1)),
                                  icon: const Icon(Icons.arrow_back),
                                  label: const Text('上一步'),
                                ),
                        ),
                        Expanded(
                          child: Center(
                            child: _PageIndicator(
                              page: _page,
                              count: _pageCount,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 148,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              key: const ValueKey('oobe-next'),
                              onPressed:
                                  _completing ? null : () => unawaited(_next()),
                              iconAlignment: IconAlignment.end,
                              icon: _completing
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _page == _pageCount - 1
                                          ? Icons.check
                                          : Icons.arrow_forward,
                                    ),
                              label: Text(
                                _page == _pageCount - 1 ? '开始使用' : '下一步',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '欢迎使用 Wristload',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              Text(
                '面向设计师与开发者的小米手环安装工具\n'
                '拖入文件，即可把表盘与快应用装入手环',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreferencePage extends StatelessWidget {
  const _PreferencePage({required this.value, required this.onChanged});

  final InstallPreference value;
  final ValueChanged<InstallPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '你的开发偏好',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                '主页安装按钮将按你的偏好排布，之后可随时在设置中修改',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text('主页按钮预览', style: theme.textTheme.titleSmall),
              const SizedBox(height: 10),
              OobeInstallPreview(preference: value),
              const SizedBox(height: 26),
              InstallPreferenceSelector(
                value: value,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadyPage extends StatelessWidget {
  const _ReadyPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '一切就绪',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              Text(
                '安装偏好已保存，你可以随时在设置中修改。\n'
                '接下来连接设备并开始安装。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.page, required this.count});

  final int page;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < count; index++) ...[
          AnimatedContainer(
            key: ValueKey('oobe-dot-$index'),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            width: index == page ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: index == page
                  ? colors.primary
                  : colors.onSurfaceVariant.withValues(alpha: .34),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          if (index != count - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}
