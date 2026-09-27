import '../models/base_location.dart';
import '../models/place.dart';
import '../utils/distance_calculator.dart';
import 'place_search_service.dart';

/// Provider id of places the user typed in themselves.
const String manualPlaceProvider = 'manual';

/// True for a place the user added by hand rather than picked from Yahoo.
///
/// Building-candidate records also carry a `manual-` id prefix, so the check
/// accepts either signal: both were created without a provider listing and
/// would otherwise be impossible to find again.
bool isUserAddedPlace(Place place) =>
    place.provider == manualPlaceProvider || place.id.startsWith('manual-');

/// Label shown on a candidate tile in place of the raw provider name.
String providerTagLabel(Place place) =>
    isUserAddedPlace(place) ? '自分で追加' : place.provider.toUpperCase();

/// User-added places that match [query], nearest first.
///
/// Every whitespace-separated token must appear (case-insensitively) in the
/// name, address, building name or category. With [nearbyOnly] the same
/// walking radius as the Yahoo search applies from [origin]; without an
/// origin the radius cannot be applied, so it is skipped rather than hiding
/// everything.
List<Place> matchUserAddedPlaces({
  required List<Place> places,
  required String query,
  required BaseLocation? origin,
  required bool nearbyOnly,
}) {
  final tokens = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.isEmpty) {
    return const [];
  }
  final matches = <(Place, double?)>[];
  for (final place in places) {
    if (!isUserAddedPlace(place)) continue;
    final haystack = [
      place.name,
      place.address,
      place.buildingName,
      place.category,
    ].join(' ').toLowerCase();
    if (!tokens.every(haystack.contains)) continue;
    double? distance;
    if (origin != null) {
      distance = calculateDistanceMeters(
        startLat: origin.lat,
        startLng: origin.lng,
        endLat: place.lat,
        endLng: place.lng,
      );
      if (nearbyOnly && distance > walkingSearchRadiusMeters) continue;
    }
    matches.add((place, distance));
  }
  matches.sort((a, b) {
    final da = a.$2, db = b.$2;
    if (da == null && db == null) return a.$1.name.compareTo(b.$1.name);
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  });
  return [for (final m in matches) m.$1];
}

/// User-added matches first, then the provider's results minus anything that
/// is already in the local list.
List<Place> mergeSearchResults({
  required List<Place> userAdded,
  required List<Place> remote,
}) {
  if (userAdded.isEmpty) return remote;
  final localIds = userAdded.map((p) => p.id).toSet();
  return [...userAdded, ...remote.where((p) => !localIds.contains(p.id))];
}
