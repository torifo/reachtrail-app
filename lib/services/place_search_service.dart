import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/base_location.dart';
import '../models/place.dart';
import '../utils/distance_calculator.dart';
import '../utils/floor_parser.dart';

const double walkingMinutesLimit = 60;
const double walkingSpeedKmh = 5.0;
const double walkingSearchRadiusKm =
    walkingSpeedKmh * (walkingMinutesLimit / 60);
const double walkingSearchRadiusMeters = walkingSearchRadiusKm * 1000;
const double rankingDistanceTieThresholdMeters = 120;

class SearchConfig {
  const SearchConfig({required this.provider, required this.yahooApiKey});

  final String provider;
  final String yahooApiKey;
}

abstract class PlaceSearchService {
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
  });
}

class CompositePlaceSearchService implements PlaceSearchService {
  CompositePlaceSearchService(this._config);

  final SearchConfig _config;

  @override
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return [];
    }

    final provider = _config.provider.toLowerCase();
    if (provider == 'yahoo' && _config.yahooApiKey.isNotEmpty) {
      try {
        final remote = await YahooLocalSearchService(_config.yahooApiKey)
            .search(
              query: normalized,
              baseLocation: baseLocation,
              nearbyOnly: nearbyOnly,
            );
        if (remote.isNotEmpty) {
          return remote;
        }
      } catch (_) {
        // Fall back to local sample data so registration can continue.
      }
    }

    return MockPlaceSearchService().search(
      query: normalized,
      baseLocation: baseLocation,
      nearbyOnly: nearbyOnly,
    );
  }
}

class MockPlaceSearchService implements PlaceSearchService {
  static const _samples = <Place>[
    Place(
      id: 'mock-1',
      provider: 'mock',
      providerPlaceId: 'mock-1',
      name: 'Shinjuku Bento Lab',
      lat: 35.68968,
      lng: 139.69173,
      address: '東京都新宿区西新宿2-8-1',
      buildingName: '都庁前フードホール',
      floorLabel: '32F',
      floorNumber: 32,
      category: 'Lunch',
    ),
    Place(
      id: 'mock-2',
      provider: 'mock',
      providerPlaceId: 'mock-2',
      name: 'Trail Pasta Stand',
      lat: 35.69011,
      lng: 139.69290,
      address: '東京都新宿区西新宿1-18-2',
      buildingName: '新宿南口ビル',
      floorLabel: 'B1',
      floorNumber: -1,
      category: 'Italian',
    ),
    Place(
      id: 'mock-3',
      provider: 'mock',
      providerPlaceId: 'mock-3',
      name: 'Reach Curry Express',
      lat: 35.68880,
      lng: 139.69050,
      address: '東京都新宿区西新宿3-1-5',
      buildingName: '',
      floorLabel: '1F',
      floorNumber: 1,
      category: 'Curry',
    ),
    Place(
      id: 'mock-4',
      provider: 'mock',
      providerPlaceId: 'mock-4',
      name: 'Skyline Soba',
      lat: 35.69140,
      lng: 139.69410,
      address: '東京都新宿区西新宿2-4-3',
      buildingName: '新宿タワー',
      floorLabel: '18F',
      floorNumber: 18,
      category: 'Japanese',
    ),
  ];

  @override
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
  }) async {
    final lowered = query.toLowerCase();
    final filtered = _samples.where((place) {
      final hit =
          place.name.toLowerCase().contains(lowered) ||
          place.address.toLowerCase().contains(lowered) ||
          place.category.toLowerCase().contains(lowered);
      if (!hit) {
        return false;
      }
      if (!nearbyOnly || baseLocation == null) {
        return true;
      }
      return calculateDistanceMeters(
            startLat: baseLocation.lat,
            startLng: baseLocation.lng,
            endLat: place.lat,
            endLng: place.lng,
          ) <=
          walkingSearchRadiusMeters;
    }).toList();

    return rankPlaces(
      places: filtered,
      baseLocation: baseLocation,
      deduplicate: false,
    );
  }
}

class YahooLocalSearchService implements PlaceSearchService {
  YahooLocalSearchService(this._apiKey);

  final String _apiKey;

  @override
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
  }) async {
    final uri = Uri.https('map.yahooapis.jp', '/search/local/V1/localSearch', {
      'appid': _apiKey,
      'query': query,
      'output': 'json',
      'detail': 'full',
      'results': '20',
      if (baseLocation != null) 'sort': 'geo',
      if (baseLocation != null) 'lat': '${baseLocation.lat}',
      if (baseLocation != null) 'lon': '${baseLocation.lng}',
      if (nearbyOnly) 'dist': '$walkingSearchRadiusKm',
    });
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Yahoo API request failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final features = (decoded['Feature'] as List<dynamic>? ?? const []).map(
      (item) => Map<String, dynamic>.from(item as Map),
    );

    final places = features.map((item) {
      final geometry = (item['Geometry'] as Map<String, dynamic>? ?? const {});
      final coordinates = (geometry['Coordinates'] as String? ?? '0,0').split(
        ',',
      );
      final property = (item['Property'] as Map<String, dynamic>? ?? const {});
      final placeInfo =
          (property['PlaceInfo'] as Map<String, dynamic>? ?? const {});
      final building =
          (property['Building'] as Map<String, dynamic>? ?? const {});
      final genres = (property['Genre'] as List<dynamic>? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      );
      final floorLabel =
          placeInfo['FloorName'] as String? ??
          building['Floor']?.toString() ??
          '';
      final buildingName = building['Name'] as String? ?? '';
      final category = genres
          .map((item) => item['Name'] as String?)
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .join(', ');
      final providerPlaceId =
          (item['Gid'] as String?) ?? (item['Id'] as String?) ?? 'unknown';
      return Place(
        id: 'yahoo-$providerPlaceId',
        provider: 'yahoo',
        providerPlaceId: providerPlaceId,
        name: item['Name'] as String? ?? query,
        lat: double.tryParse(coordinates.elementAtOrNull(1) ?? '') ?? 0,
        lng: double.tryParse(coordinates.elementAtOrNull(0) ?? '') ?? 0,
        address: property['Address'] as String? ?? '',
        buildingName: buildingName,
        floorLabel: floorLabel,
        floorNumber: parseFloorNumber(floorLabel),
        category: category,
        rawPayload: jsonEncode(item),
      );
    }).toList();

    return rankPlaces(
      places: places,
      baseLocation: baseLocation,
      deduplicate: true,
    );
  }
}

List<Place> rankPlaces({
  required List<Place> places,
  required BaseLocation? baseLocation,
  required bool deduplicate,
}) {
  final source = deduplicate ? deduplicatePlaces(places) : [...places];
  source.sort((a, b) => comparePlaces(a, b, baseLocation));
  return source;
}

List<Place> deduplicatePlaces(List<Place> places) {
  final winners = <String, Place>{};

  for (final place in places) {
    final key = buildPlaceDedupKey(place);
    final current = winners[key];
    if (current == null ||
        placeMetadataScore(place) > placeMetadataScore(current)) {
      winners[key] = place;
    }
  }

  return winners.values.toList();
}

String buildPlaceDedupKey(Place place) {
  final normalizedName = normalizePlaceText(place.name);
  final normalizedAddress = normalizePlaceText(place.address);
  if (normalizedAddress.isNotEmpty) {
    return '$normalizedName|$normalizedAddress';
  }

  return '$normalizedName|${place.lat.toStringAsFixed(4)}|${place.lng.toStringAsFixed(4)}';
}

String normalizePlaceText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

int comparePlaces(Place a, Place b, BaseLocation? baseLocation) {
  final distanceComparison = compareDistance(a, b, baseLocation);
  if (distanceComparison != 0) {
    return distanceComparison;
  }

  final metadataComparison = placeMetadataScore(
    b,
  ).compareTo(placeMetadataScore(a));
  if (metadataComparison != 0) {
    return metadataComparison;
  }

  return a.name.compareTo(b.name);
}

int compareDistance(Place a, Place b, BaseLocation? baseLocation) {
  if (baseLocation == null) {
    return 0;
  }

  final aDistance = calculateDistanceMeters(
    startLat: baseLocation.lat,
    startLng: baseLocation.lng,
    endLat: a.lat,
    endLng: a.lng,
  );
  final bDistance = calculateDistanceMeters(
    startLat: baseLocation.lat,
    startLng: baseLocation.lng,
    endLat: b.lat,
    endLng: b.lng,
  );

  if ((aDistance - bDistance).abs() <= rankingDistanceTieThresholdMeters) {
    return 0;
  }

  return aDistance.compareTo(bDistance);
}

int placeMetadataScore(Place place) {
  var score = 0;
  if (place.buildingName.trim().isNotEmpty) {
    score += 2;
  }
  if (place.floorLabel.trim().isNotEmpty || place.floorNumber != null) {
    score += 2;
  }
  if (place.category.trim().isNotEmpty) {
    score += 1;
  }
  if (place.address.trim().isNotEmpty) {
    score += 1;
  }
  return score;
}

extension on List<String> {
  String? elementAtOrNull(int index) {
    if (index < 0 || index >= length) {
      return null;
    }
    return this[index];
  }
}
