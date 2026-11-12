// ignore_for_file: constant_identifier_names

/// Library seat-reservation strings (KIT-Bibliothek via Anny). de is source
/// of truth; en mirrors every key (l10n_parity_test enforces it).
/// Interpolation is positional `{0}`, `{1}` via `L10n.t(key, [args])`.
///
/// Argument lists per key (keys not listed take no args):
///   library.freeNow      {0} = free seat count
///   library.nextFree     {0} = localized time/date of next free slot
///   library.openUntil    {0} = closing time
///   library.closedOpens  {0} = next opening time/date
///   library.roomBook     {0} = room name
///   library.expires15    {0} = remaining minutes until check-in lapses
///   library.cancelConfirm {0} = room name of the booking to cancel
///   library.advanceDays  {0} = booking horizon in days
///   library.capacity     {0} = total seat/room count
///   library.signedInAs   {0} = KIT user id / first name
///   library.checkinBanner {0} = room name, {1} = check-in deadline time
///   library.updatedAt    {0} = localized "HH:mm" of the last refresh
///   library.cancelUntil  {0} = localized cancel deadline
///   library.durMin       {0} = duration in minutes
///   library.durH         {0} = duration in whole hours
///   library.bookedOk     {0} = booking number (BB…)
const Map<String, String> de_library = {
  "library.title": "Bibliothek",
  "library.freeNow": "{0} Plätze frei",
  "library.nextFree": "Als Nächstes frei: {0}",
  "library.openUntil": "Geöffnet bis {0}",
  "library.closedOpens": "Geschlossen · öffnet {0}",
  "library.book": "Buchen",
  "library.roomBook": "Platz in {0} buchen",
  "library.duration": "Dauer",
  "library.confirm": "Bestätigen",
  "library.checkinHint":
      "Nach der Buchung innerhalb von 15 Minuten vor Ort einchecken, sonst verfällt der Platz.",
  "library.checkinBody":
      "Bitte jetzt am Check-in-Schalter einchecken – danach verfällt der Platz.",
  "library.expires15": "Check-in verfällt in {0} Min.",
  "library.cancel": "Stornieren",
  "library.cancelConfirm": "Buchung für {0} wirklich stornieren?",
  "library.justTaken": "Soeben vergeben – bitte eine andere Zeit wählen.",
  "library.identityMissing": "Bitte Vor- und Nachname für die Buchung angeben.",
  "library.noBookableDays": "Momentan keine buqbaren Tage.",
  "library.canceledFailed": "Stornierung fehlgeschlagen – bitte erneut versuchen.",
  "library.fav": "Favoritenraum",
  "library.refresh": "Aktualisieren",
  "library.loginKit": "Mit KIT-Account anmelden",
  "library.signInTitle": "KIT-Anmeldung",
  "library.myBookings": "Meine Buchungen",
  "library.noBookings": "Keine anstehenden Buchungen.",
  "library.advanceDays": "Buchbar bis {0} Tage im Voraus",
  "library.capacity": "Kapazität: {0}",
  "library.signedInAs": "Angemeldet als {0}",
  "library.signOut": "Abmelden",
  "library.loadFailed": "Bibliothek-Daten konnten nicht geladen werden.",
  "library.bookingFailed": "Buchung fehlgeschlagen – bitte erneut versuchen.",
  "library.canceledOk": "Buchung storniert.",
  "library.checkinBanner": "Jetzt einchecken: {0} bis {1}",
  "library.roomsIndividual": "Einzelplätze",
  "library.roomsGroups": "Gruppenräume",
  "library.settingsToggle": "Bibliothek-Bereich",
  "library.confirmBooking": "Buchung bestätigen",
  "library.cancelled": "Storniert",
  "library.neverBooked": "Noch keine Buchung.",
  "library.openingHours": "Öffnungszeiten",
  "library.seats": "Plätze",
  "library.updatedAt": "Stand: {0} Uhr",
  "library.stale": "evtl. veraltet",
  "library.firstName": "Vorname",
  "library.lastName": "Nachname",
  "library.email": "E-Mail",
  "library.signInFailed": "Anmeldung fehlgeschlagen – KIT-Zugangsdaten prüfen.",
  "library.cancelUntil": "Stornierbar bis {0}",
  "library.durMin": "{0} Min.",
  "library.durH": "{0} h",
  "library.bookedOk": "Gebucht: {0}",
  "library.setFav": "Als Favorit festlegen",
  "library.retry": "Erneut versuchen",
};

const Map<String, String> en_library = {
  "library.title": "Library",
  "library.freeNow": "{0} seats free",
  "library.nextFree": "Next free: {0}",
  "library.openUntil": "Open until {0}",
  "library.closedOpens": "Closed · opens {0}",
  "library.book": "Book",
  "library.roomBook": "Book a seat in {0}",
  "library.duration": "Duration",
  "library.confirm": "Confirm",
  "library.checkinHint":
      "After booking, check in on site within 15 minutes or the seat is released.",
  "library.checkinBody":
      "Please check in at the desk now – afterwards the seat expires.",
  "library.expires15": "Check-in expires in {0} min",
  "library.cancel": "Cancel",
  "library.cancelConfirm": "Really cancel your booking for {0}?",
  "library.justTaken": "Just taken – please pick another time.",
  "library.identityMissing": "Please enter first and last name to book.",
  "library.noBookableDays": "No bookable days right now.",
  "library.canceledFailed": "Cancellation failed – please try again.",
  "library.fav": "Favorite room",
  "library.refresh": "Refresh",
  "library.loginKit": "Sign in with KIT account",
  "library.signInTitle": "KIT sign-in",
  "library.myBookings": "My bookings",
  "library.noBookings": "No upcoming bookings.",
  "library.advanceDays": "Bookable up to {0} days ahead",
  "library.capacity": "Capacity: {0}",
  "library.signedInAs": "Signed in as {0}",
  "library.signOut": "Sign out",
  "library.loadFailed": "Could not load library data.",
  "library.bookingFailed": "Booking failed – please try again.",
  "library.canceledOk": "Booking canceled.",
  "library.checkinBanner": "Check in now: {0} until {1}",
  "library.roomsIndividual": "Individual seats",
  "library.roomsGroups": "Group rooms",
  "library.settingsToggle": "Library section",
  "library.confirmBooking": "Confirm booking",
  "library.cancelled": "Cancelled",
  "library.neverBooked": "No bookings yet.",
  "library.openingHours": "Opening hours",
  "library.seats": "Seats",
  "library.updatedAt": "As of {0}",
  "library.stale": "possibly outdated",
  "library.firstName": "First name",
  "library.lastName": "Last name",
  "library.email": "Email",
  "library.signInFailed": "Sign-in failed – check your KIT credentials.",
  "library.cancelUntil": "Cancelable until {0}",
  "library.durMin": "{0} min",
  "library.durH": "{0} h",
  "library.bookedOk": "Booked: {0}",
  "library.setFav": "Set as favorite",
  "library.retry": "Try again",
};
