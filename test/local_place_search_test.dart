import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/local_place_search.dart';

Place _place({
  required String id,
  required String name,
  String provider = 'manual',
  double lat = 35.6812,
  double lng = 139.7671,
  String address = '',
  String category = '',
}) => Place(
  id: id,
  provider: provider,
  providerPlaceId: id,
  name: name,
  lat: lat,
  lng: lng,
  address: address,
  category: category,
);

final _base = BaseLocation(id: 'base', name: '拠点', lat: 35.6812, lng: 139.7671);

void main() {
  group('isUserAddedPlace / providerTagLabel', () {
    test('manual provider and manual- ids count as user added', () {
      expect(isUserAddedPlace(_place(id: 'manual-1', name: 'a')), isTrue);
      expect(
        isUserAddedPlace(
          _place(id: 'manual-building-9', name: 'a', provider: 'yahoo'),
        ),
        isTrue,
      );
      expect(
        isUserAddedPlace(_place(id: 'yahoo-1', name: 'a', provider: 'yahoo')),
        isFalse,
      );
      expect(providerTagLabel(_place(id: 'manual-1', name: 'a')), '自分で追加');
      expect(
        providerTagLabel(_place(id: 'yahoo-1', name: 'a', provider: 'yahoo')),
        'YAHOO',
      );
    });
  });

  group('matchUserAddedPlaces', () {
    final places = [
      _place(id: 'yahoo-1', name: '角の定食屋', provider: 'yahoo'),
      _place(id: 'manual-1', name: '角の定食屋 本店', address: '千代田区丸の内'),
      _place(id: 'manual-2', name: 'カレーの店', category: 'カレー'),
      // ~4.5 km north: outside the 45-minute walking radius.
      _place(id: 'manual-3', name: '角の定食屋 北口', lat: 35.7220),
    ];

    test('matches user-added places by name, address or category', () {
      final byName = matchUserAddedPlaces(
        places: places,
        query: '定食屋',
        origin: _base,
        nearbyOnly: false,
      );
      expect(byName.map((p) => p.id), ['manual-1', 'manual-3']);

      final byCategory = matchUserAddedPlaces(
        places: places,
        query: 'カレー',
        origin: _base,
        nearbyOnly: false,
      );
      expect(byCategory.map((p) => p.id), ['manual-2']);

      final byAddress = matchUserAddedPlaces(
        places: places,
        query: '丸の内 定食',
        origin: _base,
        nearbyOnly: false,
      );
      expect(byAddress.map((p) => p.id), ['manual-1']);
    });

    test('never returns provider places, even when the name matches', () {
      final result = matchUserAddedPlaces(
        places: places,
        query: '角の定食屋',
        origin: _base,
        nearbyOnly: false,
      );
      expect(result.any((p) => p.id == 'yahoo-1'), isFalse);
    });

    test('applies the walking radius only when asked and an origin exists', () {
      final near = matchUserAddedPlaces(
        places: places,
        query: '定食屋',
        origin: _base,
        nearbyOnly: true,
      );
      expect(near.map((p) => p.id), ['manual-1']);

      final noOrigin = matchUserAddedPlaces(
        places: places,
        query: '定食屋',
        origin: null,
        nearbyOnly: true,
      );
      expect(noOrigin.length, 2);
    });

    test('is case-insensitive and ignores blank queries', () {
      final all = [_place(id: 'manual-9', name: 'Hungry Curry')];
      expect(
        matchUserAddedPlaces(
          places: all,
          query: 'hungry',
          origin: null,
          nearbyOnly: false,
        ).length,
        1,
      );
      expect(
        matchUserAddedPlaces(
          places: all,
          query: '   ',
          origin: null,
          nearbyOnly: false,
        ),
        isEmpty,
      );
    });
  });

  test('mergeSearchResults puts user-added first without duplicates', () {
    final mine = _place(id: 'manual-1', name: 'a');
    final remote = [
      _place(id: 'yahoo-1', name: 'b', provider: 'yahoo'),
      _place(id: 'manual-1', name: 'a'),
    ];
    final merged = mergeSearchResults(userAdded: [mine], remote: remote);
    expect(merged.map((p) => p.id), ['manual-1', 'yahoo-1']);
    expect(mergeSearchResults(userAdded: const [], remote: remote), remote);
  });
}
