import 'dart:io';

import 'package:reachtrail_api/src/server.dart';
import 'package:test/test.dart';

ReachTrailUser _user(String id) {
  final now = DateTime.now().toUtc();
  return ReachTrailUser(
    id: id,
    googleSub: 'sub-$id',
    email: '$id@example.com',
    createdAt: now,
    lastLoginAt: now,
  );
}

void main() {
  group('SessionTokenVerifier', () {
    test('accepts a token issued with the same secret', () async {
      final token = SessionTokenIssuer('top-secret').issue(_user('user-1'));
      final claims = await SessionTokenVerifier('top-secret').verify(token);

      expect(claims['sub'], 'user-1');
      expect(claims['email'], 'user-1@example.com');
    });

    test('rejects a token signed with a different secret', () async {
      final token = SessionTokenIssuer('top-secret').issue(_user('user-1'));

      expect(
        () => SessionTokenVerifier('other-secret').verify(token),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects a malformed token', () async {
      expect(
        () => SessionTokenVerifier('top-secret').verify('not-a-jwt'),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects an empty token', () async {
      expect(
        () => SessionTokenVerifier('top-secret').verify('   '),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects a token whose signature was tampered with', () async {
      final token = SessionTokenIssuer('top-secret').issue(_user('user-1'));
      final parts = token.split('.');
      final tampered = '${parts[0]}.${parts[1]}.${parts[2]}AAAA';

      expect(
        () => SessionTokenVerifier('top-secret').verify(tampered),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('ReachTrailUserStore.deleteById', () {
    test('removes only the requested user', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reachtrail-delete-test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final store = ReachTrailUserStore('${tempDir.path}/users.json');

      final first = await store.upsertGoogleUser(
        googleSub: 'google-sub-1',
        email: 'first@example.com',
      );
      await store.upsertGoogleUser(
        googleSub: 'google-sub-2',
        email: 'second@example.com',
      );

      expect(await store.deleteById(first.id), isTrue);

      final remaining = await store.loadAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.email, 'second@example.com');
    });

    test('returns false for an unknown id', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reachtrail-delete-test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final store = ReachTrailUserStore('${tempDir.path}/users.json');

      await store.upsertGoogleUser(
        googleSub: 'google-sub-1',
        email: 'first@example.com',
      );

      expect(await store.deleteById('nope'), isFalse);
      expect(await store.loadAll(), hasLength(1));
    });

    test('a session token identifies the user row to delete', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reachtrail-delete-test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final store = ReachTrailUserStore('${tempDir.path}/users.json');

      final user = await store.upsertGoogleUser(
        googleSub: 'google-sub-1',
        email: 'first@example.com',
      );
      final token = SessionTokenIssuer('top-secret').issue(user);
      final claims = await SessionTokenVerifier('top-secret').verify(token);

      expect(await store.deleteById('${claims['sub']}'), isTrue);
      expect(await store.loadAll(), isEmpty);
    });
  });

  group('RateLimiter', () {
    test('allows up to the limit then rejects within the window', () {
      final limiter = RateLimiter(
        maxRequests: 3,
        window: const Duration(minutes: 1),
      );
      final start = DateTime.utc(2026, 1, 1, 12);

      expect(limiter.allow('user-1', now: start), isTrue);
      expect(limiter.allow('user-1', now: start), isTrue);
      expect(limiter.allow('user-1', now: start), isTrue);
      expect(limiter.allow('user-1', now: start), isFalse);
    });

    test('counts each user separately', () {
      final limiter = RateLimiter(maxRequests: 1);
      final start = DateTime.utc(2026, 1, 1, 12);

      expect(limiter.allow('user-1', now: start), isTrue);
      expect(limiter.allow('user-2', now: start), isTrue);
      expect(limiter.allow('user-1', now: start), isFalse);
    });

    test('resets once the window has elapsed', () {
      final limiter = RateLimiter(
        maxRequests: 1,
        window: const Duration(minutes: 1),
      );
      final start = DateTime.utc(2026, 1, 1, 12);

      expect(limiter.allow('user-1', now: start), isTrue);
      expect(limiter.allow('user-1', now: start), isFalse);
      expect(
        limiter.allow('user-1', now: start.add(const Duration(minutes: 2))),
        isTrue,
      );
    });
  });
}
