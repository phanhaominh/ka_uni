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
      // first run: persist the default WITHOUT notifying - nothing changes
      // from the value widgets already render, and firing every setting's
      // callback on a fresh install was a spurious rebuild burst
      await _persist(_value);
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
      // fallback to default if type mismatch (also non-notifying: the
      // in-memory value never left the default)
      await _persist(_value);
    }
  }

  Future<void> set(T newValue) async {
    _value = newValue;
    await _persist(newValue);

    if (notifyCallback != null) {
      notifyCallback!();
    }
  }

  Future<void> _persist(T newValue) async {
    final prefs = await SharedPreferences.getInstance();

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
      throw UnsupportedError('Unsupported type: ${newValue.runtimeType}');
    }
  }

}