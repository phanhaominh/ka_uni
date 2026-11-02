
class KITCredentials {
  String username;
  String password;

  bool _valid = false;

  set valid(bool newValue) {
    _valid = newValue;
  }

  bool get valid => _valid;

  KITCredentials({this.username = "", this.password = "", valid}) {
    _valid = valid ?? false;
  }

  bool get isFormatValid {
    // anchored: unanchored, "xuabcdd" passes too - allMatches finds one
    // uxxxx group and `input == username` only proves same string, not
    // same extent
    final exp = RegExp(r'^u([a-z]){4}$');
    return exp.hasMatch(username);
  }

  @override
  String toString() {
    return "KITCredentials($username, $password)";
  }
}
