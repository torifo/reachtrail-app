import 'dart:convert';
import 'dart:io';

import 'package:reachtrail_api/src/server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

ReachTrailApiConfig _config(String userStorePath) {
  return ReachTrailApiConfig(
    port: 0,
    googleClientIds: const {'client-id'},
    sessionSecret: 'top-secret',
    userStorePath: userStorePath,
    allowedOrigins: const {'http://localhost:3000'},
    yahooApiKey: '',
  );
}

void main() {
  group('GET /me', () {
    late Directory tempDir;
    late ReachTrailUserStore store;
    late Handler handler;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('reachtrail-me-test');
      final config = _config('${tempDir.path}/users.json');
      store = ReachTrailUserStore(config.userStorePath);
      handler = buildHandler(config);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('returns the authenticated user with a valid session token', () async {
      final user = await store.upsertGoogleUser(
        googleSub: 'google-sub-1',
        email: 'first@example.com',
        displayName: 'First Last',
        avatarUrl: 'https://example.com/avatar.png',
      );
      final token = SessionTokenIssuer('top-secret').issue(user);

      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/me'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body, {
        'id': user.id,
        'email': 'first@example.com',
        'displayName': 'First Last',
        'photoUrl': 'https://example.com/avatar.png',
      });
    });

    test('returns 401 when no bearer token is provided', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/me')),
      );

      expect(response.statusCode, 401);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], isNotEmpty);
    });

    test('returns 401 for a malformed bearer token', () async {
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/me'),
          headers: {'authorization': 'Bearer not-a-real-token'},
        ),
      );

      expect(response.statusCode, 401);
    });

    test('returns 401 for a token whose user no longer exists', () async {
      final user = await store.upsertGoogleUser(
        googleSub: 'google-sub-2',
        email: 'second@example.com',
      );
      final token = SessionTokenIssuer('top-secret').issue(user);
      await store.deleteById(user.id);

      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/me'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );

      expect(response.statusCode, 401);
    });
  });
}
