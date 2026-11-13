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
    // NEVER interpolates the password: the zone/FlutterError hooks persist
    // error.toString() into CrashTail and the SHAREABLE support bundle, and
    // scrubDiag only redacts >=20-char runs - a typical KIT password is
    // shorter and would travel verbatim. (AnnySession.toString is log-safe
    // for the same reason.)
    return "KITCredentials($username, --)";
  }
}
