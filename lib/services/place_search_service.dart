import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/base_location.dart';
import '../models/place.dart';
import '../utils/distance_calculator.dart';
import '../utils/floor_parser.dart';

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
          1200;
    }).toList();

    filtered.sort((a, b) => a.name.compareTo(b.name));
    return filtered;
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
      if (nearbyOnly) 'dist': '1.2',
    });
    final response = await http.get(uri);
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
  }
}

extension on List<String> {
  String? elementAtOrNull(int index) {
    if (index < 0 || index >= length) {
      return null;
    }
    return this[index];
  }
}
