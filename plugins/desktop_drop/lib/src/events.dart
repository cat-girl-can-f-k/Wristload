import 'package:desktop_drop/src/drop_item.dart';
import 'package:flutter/painting.dart';

abstract class DropEvent {
  Offset location;

  DropEvent(this.location);

  @override
  String toString() {
    return '$runtimeType($location)';
  }
}

class DropEnterEvent extends DropEvent {
  DropEnterEvent({required Offset location, this.fileCount}) : super(location);

  final int? fileCount;
}

class DropExitEvent extends DropEvent {
  DropExitEvent({required Offset location}) : super(location);
}

class DropUpdateEvent extends DropEvent {
  DropUpdateEvent({required Offset location, this.fileCount}) : super(location);

  final int? fileCount;
}

class DropDoneEvent extends DropEvent {
  final List<DropItem> files;
  final List<DropError> errors;

  DropDoneEvent({
    required Offset location,
    required this.files,
    this.errors = const [],
  }) : super(location);

  @override
  String toString() {
    return '$runtimeType($location, $files)';
  }
}

class DropError {
  const DropError({
    required this.code,
    required this.message,
    this.path,
  });

  final String code;
  final String message;
  final String? path;
}
