import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/base_location.dart';
import '../models/place.dart';
import '../utils/distance_calculator.dart';
import '../utils/floor_parser.dart';

const double walkingMinutesLimit = 45;
const double walkingSpeedKmh = 5.0;
const double walkingSearchRadiusKm =
    walkingSpeedKmh * (walkingMinutesLimit / 60);
const double walkingSearchRadiusMeters = walkingSearchRadiusKm * 1000;
const double rankingDistanceTieThresholdMeters = 120;
const double dedupCoordinateThresholdMeters = 35;

class SearchConfig {
  const SearchConfig({
    required this.provider,
    required this.yahooApiKey,
    this.yahooProxyBaseUrl = '',
  });

  final String provider;
  final String yahooApiKey;
  final String yahooProxyBaseUrl;
}

enum SearchPurpose { lunchPlace, baseLocation }

abstract class PlaceSearchService {
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
    SearchPurpose purpose = SearchPurpose.lunchPlace,
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
    SearchPurpose purpose = SearchPurpose.lunchPlace,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return [];
    }

    final provider = _config.provider.toLowerCase();
    if (provider == 'yahoo' &&
        (_config.yahooApiKey.isNotEmpty ||
            _config.yahooProxyBaseUrl.isNotEmpty)) {
      return YahooLocalSearchService(
        _config.yahooApiKey,
        proxyBaseUrl: _config.yahooProxyBaseUrl,
      ).search(
        query: normalized,
        baseLocation: baseLocation,
        nearbyOnly: nearbyOnly,
        purpose: purpose,
      );
    }

    return MockPlaceSearchService().search(
      query: normalized,
      baseLocation: baseLocation,
      nearbyOnly: nearbyOnly,
      purpose: purpose,
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
    SearchPurpose purpose = SearchPurpose.lunchPlace,
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
      purpose: purpose,
      query: query,
    );
  }
}

class YahooLocalSearchService implements PlaceSearchService {
  YahooLocalSearchService(
    this._apiKey, {
    this.proxyBaseUrl = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String _apiKey;
  final String proxyBaseUrl;
  final http.Client _client;

  @override
  Future<List<Place>> search({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
    SearchPurpose purpose = SearchPurpose.lunchPlace,
  }) async {
    final allPlaces = <Place>[];
    for (final variant in _queryVariants(query, purpose)) {
      final places = await _searchSingleQuery(
        query: variant,
        baseLocation: baseLocation,
        nearbyOnly: nearbyOnly,
      );
      allPlaces.addAll(places);
    }

    var ranked = rankPlaces(
      places: allPlaces,
      baseLocation: baseLocation,
      deduplicate: true,
      purpose: purpose,
      query: query,
    );

    if (_shouldRetryBroaderYahooSearch(
      baseLocation: baseLocation,
      nearbyOnly: nearbyOnly,
      purpose: purpose,
      ranked: ranked,
    )) {
      final broaderPlaces = <Place>[];
      for (final variant in _queryVariants(query, purpose)) {
        final places = await _searchSingleQuery(
          query: variant,
          baseLocation: baseLocation,
          nearbyOnly: false,
        );
        broaderPlaces.addAll(places);
      }

      ranked = rankPlaces(
        places: broaderPlaces,
        baseLocation: baseLocation,
        deduplicate: true,
        purpose: purpose,
        query: query,
      );
    }

    if (purpose == SearchPurpose.baseLocation) {
      ranked = _prependInferredBaseCandidate(query, ranked);
      ranked = collapseBaseLocationCandidates(ranked);
    }

    return ranked;
  }

  Future<List<Place>> _searchSingleQuery({
    required String query,
    required BaseLocation? baseLocation,
    required bool nearbyOnly,
  }) async {
    final params = {
      'query': query,
      'output': 'json',
      'detail': 'full',
      'results': '20',
      if (baseLocation != null) 'sort': 'geo',
      if (baseLocation != null) 'lat': '${baseLocation.lat}',
      if (baseLocation != null) 'lon': '${baseLocation.lng}',
      if (nearbyOnly) 'dist': '$walkingSearchRadiusKm',
    };

    final Uri uri;
    if (proxyBaseUrl.isNotEmpty) {
      uri = Uri.parse(proxyBaseUrl).replace(queryParameters: params);
    } else {
      uri = Uri.https('map.yahooapis.jp', '/search/local/V1/localSearch', {
        'appid': _apiKey,
        ...params,
      });
    }
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Yahoo API request failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final features = (decoded['Feature'] as List<dynamic>? ?? const []).map(
      (item) => Map<String, dynamic>.from(item as Map),
    );

    return features.map((item) {
      final geometry = (item['Geometry'] as Map<String, dynamic>? ?? const {});
      final coordinates = (geometry['Coordinates'] as String? ?? '0,0').split(
        ',',
      );
      final property = (item['Property'] as Map<String, dynamic>? ?? const {});
      final placeInfo =
          (property['PlaceInfo'] as Map<String, dynamic>? ?? const {});
      final building = _firstMap(property['Building']);
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
  }
}

bool _shouldRetryBroaderYahooSearch({
  required BaseLocation? baseLocation,
  required bool nearbyOnly,
  required SearchPurpose purpose,
  required List<Place> ranked,
}) {
  return nearbyOnly &&
      purpose == SearchPurpose.lunchPlace &&
      baseLocation != null &&
      ranked.isEmpty;
}

List<String> _queryVariants(String query, SearchPurpose purpose) {
  final variants = <String>[query.trim()];
  if (purpose != SearchPurpose.baseLocation) {
    return variants;
  }

  final normalized = query
      .replaceFirst(RegExp(r'^住友不動産'), '')
      .replaceFirst(RegExp(r'^住友不動産株式会社'), '')
      .trim();
  if (normalized.isNotEmpty && !variants.contains(normalized)) {
    variants.add(normalized);
  }

  final compact = normalized.replaceAll(RegExp(r'\s+'), '');
  if (compact.isNotEmpty && !variants.contains(compact)) {
    variants.add(compact);
  }

  return variants;
}

List<Place> _prependInferredBaseCandidate(String query, List<Place> ranked) {
  if (ranked.isEmpty) {
    return ranked;
  }

  final normalizedQuery = normalizePlaceText(query);
  final hasDirectBuildingHit = ranked.any((place) {
    final name = normalizePlaceText(place.name);
    final building = normalizePlaceText(place.buildingName);
    return name == normalizedQuery ||
        building == normalizedQuery ||
        name.contains(normalizedQuery) ||
        building.contains(normalizedQuery);
  });
  if (hasDirectBuildingHit) {
    return ranked;
  }

  final first = ranked.first;
  final sameAddressCount = ranked
      .where(
        (place) =>
            normalizePlaceText(place.address) ==
            normalizePlaceText(first.address),
      )
      .length;
  if (sameAddressCount < 2) {
    return ranked;
  }

  final inferred = Place(
    id: 'yahoo-inferred-$normalizedQuery',
    provider: 'yahoo',
    providerPlaceId: 'inferred-$normalizedQuery',
    name: query,
    lat: first.lat,
    lng: first.lng,
    address: first.address,
    buildingName: query.replaceFirst(RegExp(r'^住友不動産'), '').trim(),
    category: 'BaseLocation',
    rawPayload: jsonEncode({
      'source': 'inferred_base_location',
      'query': query,
      'basedOn': ranked.take(3).map((place) => place.toJson()).toList(),
    }),
  );

  return [inferred, ...ranked];
}

List<Place> collapseBaseLocationCandidates(List<Place> ranked) {
  final grouped = <String, List<Place>>{};

  for (final place in ranked) {
    final key = buildBaseLocationGroupKey(place);
    grouped.putIfAbsent(key, () => []).add(place);
  }

  return grouped.entries.map((entry) {
    final places = entry.value;
    final primary = places.first;
    final buildingName = _resolveBuildingName(primary, places);
    final sampleNames = places
        .map((place) => place.name)
        .where(
          (name) =>
              normalizePlaceText(name) != normalizePlaceText(buildingName),
        )
        .take(3)
        .toList();

    return Place(
      id: 'base-${entry.key}',
      provider: primary.provider,
      providerPlaceId: 'base-${entry.key}',
      name: buildingName,
      lat: primary.lat,
      lng: primary.lng,
      address: primary.address,
      buildingName: buildingName,
      category: 'BaseLocation',
      rawPayload: jsonEncode({
        'source': 'base_location_group',
        'buildingName': buildingName,
        'candidateCount': places.length,
        'sampleNames': sampleNames,
        'members': places.map((place) => place.toJson()).toList(),
      }),
    );
  }).toList();
}

String buildBaseLocationGroupKey(Place place) {
  final normalizedBuilding = normalizePlaceText(place.buildingName);
  if (normalizedBuilding.isNotEmpty) {
    return normalizedBuilding;
  }
  final normalizedAddress = normalizePlaceText(place.address);
  return '${normalizePlaceText(place.name)}|$normalizedAddress';
}

String _resolveBuildingName(Place primary, List<Place> places) {
  if (primary.buildingName.trim().isNotEmpty) {
    return primary.buildingName;
  }

  final buildingCandidate = places
      .map((place) => place.buildingName.trim())
      .firstWhere((name) => name.isNotEmpty, orElse: () => '');
  if (buildingCandidate.isNotEmpty) {
    return buildingCandidate;
  }

  return primary.name;
}

List<Place> rankPlaces({
  required List<Place> places,
  required BaseLocation? baseLocation,
  required bool deduplicate,
  required SearchPurpose purpose,
  required String query,
}) {
  final source = deduplicate ? deduplicatePlaces(places) : [...places];
  source.sort((a, b) => comparePlaces(a, b, baseLocation, purpose, query));
  return source;
}

List<Place> deduplicatePlaces(List<Place> places) {
  final winners = <String, Place>{};

  for (final place in places) {
    final key = findPlaceDedupKey(place, winners) ?? buildPlaceDedupKey(place);
    final current = winners[key];
    if (current == null || shouldReplaceDedupWinner(current, place)) {
      winners[key] = place;
    }
  }

  return winners.values.toList();
}

String? findPlaceDedupKey(Place place, Map<String, Place> winners) {
  for (final entry in winners.entries) {
    if (areLikelyDuplicatePlaces(entry.value, place)) {
      return entry.key;
    }
  }

  return null;
}

String buildPlaceDedupKey(Place place) {
  final normalizedName = normalizePlaceText(place.name);
  final normalizedAddress = normalizePlaceAddress(place.address);
  if (normalizedAddress.isNotEmpty) {
    return '$normalizedName|$normalizedAddress';
  }

  return '$normalizedName|${place.lat.toStringAsFixed(4)}|${place.lng.toStringAsFixed(4)}';
}

String normalizePlaceText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

String normalizePlaceAddress(String value) {
  return normalizePlaceText(
    value
        .replaceAll(RegExp(r'[()（）]'), '')
        .replaceAll(RegExp(r'(?:地下)?\d+\s*階'), '')
        .replaceAll(RegExp(r'B?\d+\s*F', caseSensitive: false), ''),
  );
}

bool areLikelyDuplicatePlaces(Place a, Place b) {
  if (normalizePlaceText(a.name) != normalizePlaceText(b.name)) {
    return false;
  }

  final aAddress = normalizePlaceAddress(a.address);
  final bAddress = normalizePlaceAddress(b.address);
  if (aAddress.isNotEmpty && aAddress == bAddress) {
    return true;
  }

  final distance = calculateDistanceMeters(
    startLat: a.lat,
    startLng: a.lng,
    endLat: b.lat,
    endLng: b.lng,
  );
  return distance <= dedupCoordinateThresholdMeters;
}

bool shouldReplaceDedupWinner(Place current, Place incoming) {
  final currentHasFloor = hasFloorMetadata(current);
  final incomingHasFloor = hasFloorMetadata(incoming);
  if (incomingHasFloor != currentHasFloor) {
    return incomingHasFloor;
  }

  return placeMetadataScore(incoming) > placeMetadataScore(current);
}

int comparePlaces(
  Place a,
  Place b,
  BaseLocation? baseLocation,
  SearchPurpose purpose,
  String query,
) {
  if (purpose == SearchPurpose.baseLocation) {
    final queryComparison = baseLocationQueryScore(
      b,
      query,
    ).compareTo(baseLocationQueryScore(a, query));
    if (queryComparison != 0) {
      return queryComparison;
    }

    final buildingComparison = baseLocationBuildingScore(
      b,
    ).compareTo(baseLocationBuildingScore(a));
    if (buildingComparison != 0) {
      return buildingComparison;
    }

    return a.name.compareTo(b.name);
  }

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
  if (hasFloorMetadata(place)) {
    score += 3;
  }
  if (place.category.trim().isNotEmpty) {
    score += 1;
  }
  if (place.address.trim().isNotEmpty) {
    score += 1;
  }
  return score;
}

bool hasFloorMetadata(Place place) {
  return place.floorLabel.trim().isNotEmpty || place.floorNumber != null;
}

int baseLocationQueryScore(Place place, String query) {
  final normalizedQuery = normalizePlaceText(query);
  var score = 0;
  final name = normalizePlaceText(place.name);
  final building = normalizePlaceText(place.buildingName);
  final address = normalizePlaceText(place.address);

  if (name == normalizedQuery || building == normalizedQuery) {
    score += 6;
  }
  if (name.contains(normalizedQuery) || building.contains(normalizedQuery)) {
    score += 4;
  }
  if (address.contains(normalizedQuery)) {
    score += 2;
  }
  return score;
}

int baseLocationBuildingScore(Place place) {
  var score = 0;
  if (place.buildingName.trim().isNotEmpty) {
    score += 3;
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

Map<String, dynamic> _firstMap(Object? value) {
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}
