import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reachtrail_app/services/google_auth_service.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
import 'package:reachtrail_app/services/session_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = LocalConfig(
  placeSearchProvider: 'mock',
  yahooApiKey: '',
  yahooProxyBaseUrl: '',
  apiBaseUrl: 'https://api.example.test',
  googleWebClientId: 'web-client-id',
  googleMacosClientId: '',
  googleWindowsClientId: '',
);

class _StubConfigService extends LocalConfigService {
  @override
  Future<LocalConfig> load() async => _config;
}

/// Records every request so a test can prove the `/me` check ran (and that
/// nothing else did).
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final FutureOr<http.Response> Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

Future<void> _cacheSession() => SessionCacheService().save(
  const CachedSession(
    userId: 'user-1',
    email: 'user@example.com',
    sessionToken: 'token-1',
    displayName: 'User One',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('startup with a cached session', () {
    test('a confirmed session keeps the user signed in and online', () async {
      await _cacheSession();
      final client = _RecordingClient(
        (_) => http.Response(
          jsonEncode({
            'user': {'id': 'user-1', 'email': 'new@example.com'},
          }),
          200,
        ),
      );
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: client,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.isSignedIn, isTrue);
      expect(service.isInitializing, isFalse);
      expect(service.isOffline, isFalse);
      expect(service.sessionExpired, isFalse);
      expect(service.currentUser!.email, 'new@example.com');
      expect(service.usedLightweightAuthentication, isFalse);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.method, 'GET');
      expect(
        client.requests.single.url.toString(),
        'https://api.example.test/me',
      );
      expect(
        client.requests.single.headers['Authorization'],
        'Bearer token-1',
      );
    });

    test('a rejected session stays in the app and asks for a re-sign-in', () async {
      await _cacheSession();
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient((_) => http.Response('', 401)),
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.isSignedIn, isTrue);
      expect(service.sessionExpired, isTrue);
      // The dead token is dropped, but the account stays named on screen.
      expect(service.currentUser!.sessionToken, isEmpty);
      expect(service.currentUser!.email, 'user@example.com');
      expect(await SessionCacheService().load(), isNull);
      expect(service.usedLightweightAuthentication, isFalse);
    });

    test('an unreachable server keeps the session and goes offline', () async {
      await _cacheSession();
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient(
          (_) => throw const SocketException('no route to host'),
        ),
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.isSignedIn, isTrue);
      expect(service.isOffline, isTrue);
      expect(service.sessionExpired, isFalse);
      expect(service.searchUnavailableReason, offlineSearchUnavailableMessage);
      expect(service.usedLightweightAuthentication, isFalse);
    });

    test('a server error keeps the session rather than signing out', () async {
      await _cacheSession();
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient((_) => http.Response('boom', 500)),
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.isSignedIn, isTrue);
      expect(service.isOffline, isTrue);
      expect(service.sessionExpired, isFalse);
    });
  });

  group('resume', () {
    test('refreshSilently re-checks the session without any Google UI', () async {
      await _cacheSession();
      final client = _RecordingClient((_) => http.Response('{}', 200));
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: client,
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(client.requests, hasLength(1));

      // Throttled: a resume moments after the startup check does nothing.
      await service.refreshSilently();
      expect(client.requests, hasLength(1));

      service.debugResetSessionCheckThrottle();
      await service.refreshSilently();

      expect(client.requests, hasLength(2));
      expect(service.usedLightweightAuthentication, isFalse);
    });

    test('refreshSilently does nothing without a session', () async {
      final client = _RecordingClient((_) => http.Response('{}', 200));
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: client,
      );
      addTearDown(service.dispose);

      await service.refreshSilently();

      expect(client.requests, isEmpty);
    });
  });

  group('startup without a cached session', () {
    test('falls back to Google lightweight authentication', () async {
      final client = _RecordingClient((_) => http.Response('{}', 200));
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: client,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.isSignedIn, isFalse);
      expect(service.isInitializing, isFalse);
      // No session to validate, so nothing was asked of the API.
      expect(client.requests, isEmpty);
      expect(service.usedLightweightAuthentication, isTrue);
    });
  });

  group('mid-session exchange failures', () {
    test('a 502 keeps the user signed in', () async {
      await _cacheSession();
      var meChecked = false;
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient((request) {
          if (request.url.path == '/me') {
            meChecked = true;
            return http.Response('{}', 200);
          }
          return http.Response('bad gateway', 502);
        }),
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(meChecked, isTrue);

      await service.exchangeIdTokenForSession(
        idToken: 'id-token',
        accountId: 'user-1',
        accountEmail: 'user@example.com',
      );

      expect(service.isSignedIn, isTrue);
      expect(service.errorMessage, isNull);
      expect(service.isOffline, isTrue);
    });

    test('an unparseable response keeps the user signed in', () async {
      await _cacheSession();
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient((request) {
          if (request.url.path == '/me') {
            return http.Response('{}', 200);
          }
          return http.Response('not json', 200);
        }),
      );
      addTearDown(service.dispose);
      await service.initialize();

      await service.exchangeIdTokenForSession(
        idToken: 'id-token',
        accountId: 'user-1',
        accountEmail: 'user@example.com',
      );

      expect(service.isSignedIn, isTrue);
      expect(service.errorMessage, isNull);
    });

    test('an interactive sign-in failure still surfaces', () async {
      final service = GoogleAuthService(
        configService: _StubConfigService(),
        httpClient: _RecordingClient((_) => http.Response('nope', 500)),
      );
      addTearDown(service.dispose);
      await service.initialize();

      await service.exchangeIdTokenForSession(
        idToken: 'id-token',
        accountId: 'user-1',
        accountEmail: 'user@example.com',
      );

      expect(service.isSignedIn, isFalse);
      expect(service.errorMessage, contains('HTTP 500'));
    });
  });
}
