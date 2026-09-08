import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The minimum a signed-in session needs to survive a cold start with no
/// network: enough to identify the user and to authenticate proxy calls.
///
/// No Google id token is stored: it expires within an hour and is only useful
/// for a fresh `/auth/google` exchange, which needs the network anyway.
@immutable
class CachedSession {
  const CachedSession({
    required this.userId,
    required this.email,
    required this.sessionToken,
    this.displayName,
    this.photoUrl,
  });

  final String userId;
  final String email;
  final String sessionToken;
  final String? displayName;
  final String? photoUrl;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'email': email,
    'sessionToken': sessionToken,
    'displayName': displayName,
    'photoUrl': photoUrl,
  };

  /// Returns null instead of throwing when the stored shape is unusable: a
  /// half-written cache must not block startup.
  static CachedSession? fromJson(Map<String, dynamic> json) {
    final userId = '${json['userId'] ?? ''}';
    final sessionToken = '${json['sessionToken'] ?? ''}';
    if (userId.isEmpty || sessionToken.isEmpty) {
      return null;
    }
    return CachedSession(
      userId: userId,
      email: '${json['email'] ?? ''}',
      sessionToken: sessionToken,
      displayName: json['displayName'] as String?,
      photoUrl: json['photoUrl'] as String?,
    );
  }
}

/// Persists the last successful sign-in so the app can open straight into the
/// home screen while offline, instead of stranding the user on the sign-in
/// screen with a network error.
class SessionCacheService {
  static const _sessionKey = 'auth_session';

  Future<SharedPreferences>? _prefsFuture;

  Future<SharedPreferences> _prefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  Future<CachedSession?> load() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return CachedSession.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(CachedSession session) async {
    final prefs = await _prefs();
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
  }

  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_sessionKey);
  }
}
