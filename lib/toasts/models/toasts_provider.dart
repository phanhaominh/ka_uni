import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ToastsProvider extends ChangeNotifier {
  bool isShowing = false;

  static const defaultAnimationDuration = Duration(milliseconds: 500);
  static const _defaultDuration = Duration(seconds: 3);

  static const _defaultForegroundColor = Colors.black;

  /// explicit caller color or null: the overlay then falls back to the
  /// theme's card color (black-on-black was the old dark-mode bug)
  Color? backgroundColor;
  Color? foregroundColor;
  String message = "You are not supposed to see this ;)";

  /// single timer driving hide + post-animation reset; cancelled and
  /// re-armed by every showTextToast, so a pending hide of an older toast
  /// can never wipe a newer one
  Timer? _resetTimer;

  Future<void> showTextToast(String message, {
    Duration duration = _defaultDuration,
    Color? backgroundColor,
    Color? foregroundColor}) async {
    // replace-latest instead of reject-while-showing: dropping the incoming
    // toast hid e.g. "refresh failed" behind the older "reloading..." toast
    // that fired microseconds earlier
    _resetTimer?.cancel();

    this.message = message;
    this.backgroundColor = backgroundColor;
    this.foregroundColor = foregroundColor;

    isShowing = true;
    if (kDebugMode) {
      print("Showing $message");
    }
    notifyListeners();

    _resetTimer = Timer(duration, () {
      isShowing = false;
      notifyListeners();

      // let the fade-out animation finish before clearing the message;
      // a newer toast cancels this timer together with the hide one
      _resetTimer = Timer(defaultAnimationDuration, () {
        _resetTimer = null;
        reset(notify: true);
      });
    });
  }

  @override
  void dispose() {
    // never notify through a disposed ChangeNotifier from a pending timer
    _resetTimer?.cancel();
    super.dispose();
  }

  void reset({bool notify = true}) {
    message = "";
    backgroundColor = null;
    foregroundColor = _defaultForegroundColor;
    isShowing = false;

    if (notify) {
      notifyListeners();
    }
  }
}