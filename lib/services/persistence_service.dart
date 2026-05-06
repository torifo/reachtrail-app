import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/base_location.dart';
import '../models/lunch_challenge_record.dart';
import '../models/place.dart';

class PersistenceService {
  static const _baseLocationKey = 'base_location';
  static const _placesKey = 'places';
  static const _recordsKey = 'records';

  Future<BaseLocation?> loadBaseLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_baseLocationKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return BaseLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveBaseLocation(BaseLocation location) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseLocationKey, jsonEncode(location.toJson()));
  }

  Future<void> deleteBaseLocation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baseLocationKey);
  }

  Future<List<Place>> loadPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_placesKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => Place.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<void> savePlaces(List<Place> places) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _placesKey,
      jsonEncode(places.map((item) => item.toJson()).toList()),
    );
  }

  Future<List<LunchChallengeRecord>> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordsKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map(
          (item) => LunchChallengeRecord.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  Future<void> saveRecords(List<LunchChallengeRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recordsKey,
      jsonEncode(records.map((item) => item.toJson()).toList()),
    );
  }
}
