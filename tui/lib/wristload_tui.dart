/// Stable public API for the macOS-only Wristload terminal frontend.
///
/// Application code should depend on [TuiFrontendPort] and immutable frontend
/// view models. It must not import backend, transport, protocol, checkpoint,
/// or file-import implementation details from this package.
library;

export 'src/facade/tui_facade.dart' show TuiFacade;
export 'src/frontend/port/tui_action_result.dart';
export 'src/frontend/port/tui_frontend_port.dart';
export 'src/frontend/port/tui_snapshot.dart';
