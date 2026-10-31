import 'package:shared_preferences/shared_preferences.dart';

class Setting<T> {
  final void Function()? notifyCallback;
  final String valueKey;

  late T _value;

  Setting({required this.valueKey, required defaultValue, this.notifyCallback}) {
    _value = defaultValue;
  }

  T get value => _value;

  Future<void> prepare() async {
    final prefs = await SharedPreferences.getInstance();
    Object? stored = prefs.get(valueKey);

    if (stored == null) {
      await set(_value);
      return;
    }

    // Ensure type safety before casting
    if (stored is T) {
      final changed = stored != _value;
      _value = stored as T;
      // a restored non-default value must notify: MaterialApp renders its
      // FIRST frame with the default, and without this the persisted
      // theme/language arrived silently without any rebuild
      if (changed) notifyCallback?.call();
    } else {
      await set(_value); // fallback to default if type mismatch
    }
  }

  Future<void> set(T newValue) async {
    final prefs = await SharedPreferences.getInstance();
    _value = newValue;

    if (newValue is bool) {
      await prefs.setBool(valueKey, newValue);
    } else if (newValue is int) {
      await prefs.setInt(valueKey, newValue);
    } else if (newValue is double) {
      await prefs.setDouble(valueKey, newValue);
    } else if (newValue is String) {
      await prefs.setString(valueKey, newValue);
    } else if (newValue is List<String>) {
      await prefs.setStringList(valueKey, newValue);
    } else {
      throw UnsupportedError('Unsupported type: ${value.runtimeType}');
    }

    if (notifyCallback != null) {
      notifyCallback!();
    }
  }

}