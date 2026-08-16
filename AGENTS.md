# Project Instructions for LLM Agents

This file is part of the repository and MUST be committed to Git. Read it before inspecting or changing project files.

## Non-negotiable architecture

### Modular pages

- Every primary Flutter page must live in its own file under `lib/presentation/pages/`.
- Each page file must declare exactly one `const wristloadPage = WristloadPageModule(...)` module descriptor.
- The application shell in `lib/main.dart` must discover pages through `lib/presentation/generated_page_registry.dart`; do not add page-specific imports, navigation destinations, route branches, or switch cases directly to `main.dart`.
- After adding or removing a page file, run `tool/generate_page_registry.ps1` so the generated registry matches the files present. The Windows build helper scripts already invoke this generator before building.
- Adding a page means adding one self-contained page module file. Removing a page file must remove it from the generated registry and make the app compile without that page; the home/navigation UI must not display a removed page.
- Keep page-specific widgets, callbacks, and layout code in the page file or in narrowly scoped presentation helpers. Do not grow a monolithic `main.dart` page switch.
- Shared state and lifecycle remain in application/domain layers and are passed through `WristloadPageContext`; do not make page modules own global connection lifecycle.
- Keep module metadata (`id`, `route`, labels, icons, ordering) in the page module descriptor. Use stable unique IDs and routes.
- Generated files are not hand-edited. Change page files or the generator, then regenerate the registry.

### Platform connection separation

- macOS and Windows connection logic are two separate modules. Keep macOS-specific behavior in `lib/platform/macos_v2_connection.dart` and Windows-specific behavior in `lib/platform/windows_v2_connection.dart`.
- `lib/platform/desktop_v2_connection.dart` contains only the shared interface/contract and platform-neutral types. It must not contain OS-specific branching or implementation details.
- Do not merge macOS and Windows pairing, identity resolution, GATT, RFCOMM/SPP setup, timeout handling, or native bridge calls into one implementation file.
- Platform selection belongs at the composition boundary (for example, the controller/factory), while each platform adapter owns its own preparation sequence. Shared authentication, SPP protocol, and connection state may remain in common domain/application code.
- A change for one operating system must not silently alter the other platform's connection flow. Preserve explicit platform-specific tests and add/update tests when changing either adapter.

## Change workflow

1. Inspect the existing module, interface, and tests before editing. Preserve unrelated user changes.
2. Keep edits narrowly scoped and use `apply_patch` for manual changes. Do not rewrite UTF-8 source files through shell redirection or encoding-ambiguous commands.
3. When changing pages, regenerate `lib/presentation/generated_page_registry.dart`.
4. Run static checks appropriate to the change, but do not run `flutter build`, `flutter test`, `flutter analyze`, packaging scripts, or launch the application unless the user explicitly requests it. The user normally performs compilation and testing.
5. Report changed files, static checks performed, and any remaining limitation.

## Repository boundaries

- `lib/application/`: application orchestration and lifecycle.
- `lib/domain/`: protocol, persistence, and device business logic.
- `lib/platform/`: OS adapters and native transport integration.
- `lib/presentation/`: Flutter UI, dialogs, shared widgets, and page modules.
- `plugins/`: locally overridden third-party/native plugins; preserve their platform APIs and behavior unless the task explicitly targets them.
- `tui/`: separate terminal UI package; do not couple Flutter page modules to TUI internals.

## Safety

- Never use `git reset --hard`, `git checkout --`, `git clean`, or broad destructive deletion.
- Never discard existing user modifications or stash entries.
- Do not commit secrets, authkeys, logs containing credentials, or generated build artifacts.
