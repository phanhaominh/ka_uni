/// Shared hardening for SYNTHETIC ICS emitters (exam sittings, SignMeUp
/// groups). R23: the guard started life as exam_synth's private
/// `_icsFoldable`; the SignMeUp emitter writes the same class of foreign
/// text (instructor-set procedure/topic names straight off the wire) and
/// lacked it — a CR/LF inside a property value splits the physical ICS
/// line and destroys the document: Google/Apple reject the event or the
/// whole file, and the in-app LineSplitter-based parser then reads the
/// remainder as a property line — a smuggled `END:VEVENT` truncates the
/// event, a forged `X-PERSONAL-ICS-END` makes the sentinel splices cut
/// the user's personal block out of the cache on the next carry-over.
final RegExp _newlineRun = RegExp(r"\s*[\r\n]+\s*");

/// Collapse every whitespace run that contains a line break into a single
/// space, so no foreign text can ever start a new physical ICS line.
String icsFoldable(String v) => v.replaceAll(_newlineRun, " ");
