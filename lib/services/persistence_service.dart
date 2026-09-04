import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/base_location.dart';
import '../models/dine_challenge_record.dart';
import '../models/place.dart';

class PersistenceService {
  static const _baseLocationKey = 'base_location';
  static const _placesKey = 'places';
  static const _recordsKey = 'records';

  /// Cached instance so each read/write does not re-enter the platform channel.
  Future<SharedPreferences>? _prefsFuture;

  Future<SharedPreferences> _prefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  Future<BaseLocation?> loadBaseLocation() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_baseLocationKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return BaseLocation.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error, stackTrace) {
      // A corrupt base location must not block startup; drop it instead.
      _reportDecodeFailure('base location', error, stackTrace);
      return null;
    }
  }

  Future<void> saveBaseLocation(BaseLocation location) async {
    final prefs = await _prefs();
    await prefs.setString(_baseLocationKey, jsonEncode(location.toJson()));
  }

  Future<void> deleteBaseLocation() async {
    final prefs = await _prefs();
    await prefs.remove(_baseLocationKey);
  }

  Future<List<Place>> loadPlaces() async {
    return _loadList(key: _placesKey, label: 'place', decode: Place.fromJson);
  }

  Future<void> savePlaces(List<Place> places) async {
    final prefs = await _prefs();
    await prefs.setString(
      _placesKey,
      jsonEncode(places.map((item) => item.toJson()).toList()),
    );
  }

  Future<List<DineChallengeRecord>> loadRecords() async {
    return _loadList(
      key: _recordsKey,
      label: 'record',
      decode: DineChallengeRecord.fromJson,
    );
  }

  Future<void> saveRecords(List<DineChallengeRecord> records) async {
    final prefs = await _prefs();
    await prefs.setString(
      _recordsKey,
      jsonEncode(records.map((item) => item.toJson()).toList()),
    );
  }

  /// Removes every locally stored ReachTrail value.
  ///
  /// Used by in-app account deletion, where the user is told that records kept
  /// on this device are erased along with the server-side account.
  Future<void> clearAll() async {
    final prefs = await _prefs();
    await prefs.remove(_baseLocationKey);
    await prefs.remove(_placesKey);
    await prefs.remove(_recordsKey);
  }

  /// Decodes a stored JSON list, skipping any single entry that fails to parse
  /// rather than letting one bad record take down the whole load.
  Future<List<T>> _loadList<T>({
    required String key,
    required String label,
    required T Function(Map<String, dynamic>) decode,
  }) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return <T>[];
    }

    final List<dynamic> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) {
        return <T>[];
      }
      decoded = parsed;
    } catch (error, stackTrace) {
      _reportDecodeFailure('$label list', error, stackTrace);
      return <T>[];
    }

    final results = <T>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      try {
        results.add(decode(Map<String, dynamic>.from(item)));
      } catch (error, stackTrace) {
        _reportDecodeFailure(label, error, stackTrace);
      }
    }
    return results;
  }

  void _reportDecodeFailure(String label, Object error, StackTrace stackTrace) {
    if (kDebugMode) {
      debugPrint('ReachTrail: skipped unreadable $label ($error)');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}
