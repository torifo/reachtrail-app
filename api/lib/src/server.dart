import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

class ReachTrailApiConfig {
  const ReachTrailApiConfig({
    required this.port,
    required this.googleClientIds,
    required this.sessionSecret,
    required this.userStorePath,
    required this.allowedOrigins,
    required this.yahooApiKey,
  });

  factory ReachTrailApiConfig.fromEnvironment() {
    final allowedOrigins =
        (Platform.environment['ALLOWED_ORIGINS'] ??
                'https://app.reachtrail.riumu.net,http://localhost:3000,http://localhost:8080')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();
    final clientIds =
        (Platform.environment['GOOGLE_ALLOWED_CLIENT_IDS'] ??
                '823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com,823224608668-9blagvtvvuoa728q195ma5jlpeq1308a.apps.googleusercontent.com')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();

    return ReachTrailApiConfig(
      port: int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080,
      googleClientIds: clientIds,
      sessionSecret: Platform.environment['SESSION_SECRET'] ?? 'change-me',
      userStorePath:
          Platform.environment['USER_STORE_PATH'] ??
          './data/reachtrail-users.json',
      allowedOrigins: allowedOrigins,
      yahooApiKey: Platform.environment['YAHOO_API_KEY'] ?? '',
    );
  }

  final int port;
  final Set<String> googleClientIds;
  final String sessionSecret;
  final String userStorePath;
  final Set<String> allowedOrigins;
  final String yahooApiKey;
}

class ReachTrailUser {
  const ReachTrailUser({
    required this.id,
    required this.googleSub,
    required this.email,
    this.displayName,
    this.avatarUrl,
    required this.createdAt,
    required this.lastLoginAt,
  });

  final String id;
  final String googleSub;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final DateTime createdAt;
  final DateTime lastLoginAt;

  ReachTrailUser copyWith({
    String? email,
    String? displayName,
    String? avatarUrl,
    DateTime? lastLoginAt,
  }) {
    return ReachTrailUser(
      id: id,
      googleSub: googleSub,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      createdAt: createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'googleSub': googleSub,
      'email': email,
      'displayName': displayName,
      'avatarUrl': avatarUrl,
      'createdAt': createdAt.toIso8601String(),
      'lastLoginAt': lastLoginAt.toIso8601String(),
    };
  }

  factory ReachTrailUser.fromJson(Map<String, dynamic> json) {
    return ReachTrailUser(
      id: '${json['id']}',
      googleSub: '${json['googleSub']}',
      email: '${json['email']}',
      displayName: json['displayName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      createdAt: DateTime.parse('${json['createdAt']}'),
      lastLoginAt: DateTime.parse('${json['lastLoginAt']}'),
    );
  }
}

class ReachTrailUserStore {
  ReachTrailUserStore(this.path);

  final String path;

  Future<List<ReachTrailUser>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) {
      return <ReachTrailUser>[];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return <ReachTrailUser>[];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => ReachTrailUser.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<ReachTrailUser> upsertGoogleUser({
    required String googleSub,
    required String email,
    String? displayName,
    String? avatarUrl,
  }) async {
    final users = await loadAll();
    final now = DateTime.now().toUtc();
    final index = users.indexWhere((user) => user.googleSub == googleSub);
    final updated = index >= 0
        ? users[index].copyWith(
            email: email,
            displayName: displayName,
            avatarUrl: avatarUrl,
            lastLoginAt: now,
          )
        : ReachTrailUser(
            id: _makeUserId(googleSub),
            googleSub: googleSub,
            email: email,
            displayName: displayName,
            avatarUrl: avatarUrl,
            createdAt: now,
            lastLoginAt: now,
          );

    if (index >= 0) {
      users[index] = updated;
    } else {
      users.add(updated);
    }

    await _writeAll(users);
    return updated;
  }

  /// Removes the user with [id]. Returns true when a user was actually deleted.
  Future<bool> deleteById(String id) async {
    final users = await loadAll();
    final remaining = users.where((user) => user.id != id).toList();
    if (remaining.length == users.length) {
      return false;
    }
    await _writeAll(remaining);
    return true;
  }

  Future<void> _writeAll(List<ReachTrailUser> users) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(users.map((user) => user.toJson()).toList()),
    );
  }

  String _makeUserId(String googleSub) {
    final digest = sha256.convert(utf8.encode(googleSub)).toString();
    return digest.substring(0, 24);
  }
}

class GoogleTokenVerifier {
  GoogleTokenVerifier({required this.allowedClientIds, http.Client? client})
    : _client = client ?? http.Client();

  static final Uri _jwksUri = Uri.parse(
    'https://www.googleapis.com/oauth2/v3/certs',
  );

  final Set<String> allowedClientIds;
  final http.Client _client;

  JsonWebKeyStore? _cachedKeyStore;
  DateTime? _cachedUntil;

  Future<Map<String, dynamic>> verifyIdToken(String idToken) async {
    await _refreshKeysIfNeeded();
    final keyStore = _cachedKeyStore;
    if (keyStore == null) {
      throw const AuthException('Google signing keys are unavailable.');
    }

    final jwt = JsonWebToken.unverified(idToken);
    final verified = await jwt.verify(keyStore, allowedArguments: ['RS256']);
    if (!verified) {
      throw const AuthException(
        'Google ID token signature verification failed.',
      );
    }

    final claims = jwt.claims;
    final violations = claims.validate();
    if (violations.isNotEmpty) {
      throw AuthException(violations.first.toString());
    }

    final issuer = claims.issuer?.toString();
    if (issuer != 'https://accounts.google.com' &&
        issuer != 'accounts.google.com') {
      throw const AuthException('Google ID token issuer is invalid.');
    }

    final audience = claims.audience ?? const [];
    if (!audience.any(allowedClientIds.contains)) {
      throw const AuthException('Google ID token audience is invalid.');
    }

    return claims.toJson();
  }

  Future<void> _refreshKeysIfNeeded() async {
    final now = DateTime.now().toUtc();
    if (_cachedKeyStore != null &&
        _cachedUntil != null &&
        now.isBefore(_cachedUntil!)) {
      return;
    }

    final response = await _client.get(_jwksUri);
    if (response.statusCode != 200) {
      throw AuthException(
        'Failed to fetch Google signing keys: ${response.statusCode}',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final keyStore = JsonWebKeyStore()
      ..addKeySet(JsonWebKeySet.fromJson(payload));
    _cachedKeyStore = keyStore;
    _cachedUntil = now.add(_readMaxAge(response.headers['cache-control']));
  }

  Duration _readMaxAge(String? cacheControl) {
    final match = RegExp(r'max-age=(\d+)').firstMatch(cacheControl ?? '');
    final seconds = int.tryParse(match?.group(1) ?? '') ?? 300;
    return Duration(seconds: seconds);
  }
}

class SessionTokenIssuer {
  SessionTokenIssuer(this.secret);

  final String secret;

  String issue(ReachTrailUser user) {
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = {
        'sub': user.id,
        'email': user.email,
        'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        'exp':
            DateTime.now()
                .toUtc()
                .add(const Duration(days: 7))
                .millisecondsSinceEpoch ~/
            1000,
      };

    builder.addRecipient(
      JsonWebKey.fromJson({
        'kty': 'oct',
        'k': base64UrlEncode(utf8.encode(secret)).replaceAll('=', ''),
      }),
      algorithm: 'HS256',
    );
    return builder.build().toCompactSerialization();
  }
}

/// Verifies the HS256 session tokens minted by [SessionTokenIssuer].
class SessionTokenVerifier {
  SessionTokenVerifier(this.secret);

  final String secret;

  /// Returns the token claims, or throws [AuthException] when the signature,
  /// structure, or expiry is not acceptable.
  Future<Map<String, dynamic>> verify(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const AuthException('Session token is required.');
    }

    final JsonWebToken jwt;
    try {
      jwt = JsonWebToken.unverified(trimmed);
    } catch (_) {
      throw const AuthException('Session token is malformed.');
    }

    final keyStore = JsonWebKeyStore()..addKey(_key());
    final bool verified;
    try {
      // Pinning the algorithm keeps an attacker from downgrading to `none`.
      verified = await jwt.verify(keyStore, allowedArguments: ['HS256']);
    } catch (_) {
      throw const AuthException('Session token signature is invalid.');
    }
    if (!verified) {
      throw const AuthException('Session token signature is invalid.');
    }

    final claims = jwt.claims.toJson();

    final expiry = claims['exp'];
    if (expiry is! num) {
      throw const AuthException('Session token has no expiry.');
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiry.toInt() * 1000,
      isUtc: true,
    );
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const AuthException('Session token has expired.');
    }

    final subject = '${claims['sub'] ?? ''}';
    if (subject.isEmpty) {
      throw const AuthException('Session token has no subject.');
    }

    return claims;
  }

  JsonWebKey _key() {
    return JsonWebKey.fromJson({
      'kty': 'oct',
      'k': base64UrlEncode(utf8.encode(secret)).replaceAll('=', ''),
    });
  }
}

/// Fixed-window, in-memory request limiter keyed by user id.
///
/// The proxy is the only endpoint behind it, so per-process counting is enough
/// to stop a single credential from being used to hammer the upstream API.
class RateLimiter {
  RateLimiter({
    this.maxRequests = 60,
    this.window = const Duration(minutes: 1),
  });

  final int maxRequests;
  final Duration window;
  final Map<String, _RateWindow> _windows = {};

  /// Returns true when the call is allowed, false when the caller is over quota.
  bool allow(String key, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    _windows.removeWhere(
      (_, value) => at.difference(value.startedAt) >= window,
    );

    final current = _windows[key];
    if (current == null || at.difference(current.startedAt) >= window) {
      _windows[key] = _RateWindow(startedAt: at, count: 1);
      return true;
    }
    if (current.count >= maxRequests) {
      return false;
    }
    current.count++;
    return true;
  }
}

class _RateWindow {
  _RateWindow({required this.startedAt, required this.count});

  final DateTime startedAt;
  int count;
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

Handler buildHandler(ReachTrailApiConfig config) {
  final router = Router();
  final userStore = ReachTrailUserStore(config.userStorePath);
  final verifier = GoogleTokenVerifier(
    allowedClientIds: config.googleClientIds,
  );
  final sessionIssuer = SessionTokenIssuer(config.sessionSecret);
  final sessionVerifier = SessionTokenVerifier(config.sessionSecret);
  final rateLimiter = RateLimiter();

  /// Resolves the caller's user id from the bearer token, or null when the
  /// request is not authenticated.
  Future<String?> authenticate(Request request) async {
    final header = request.headers['authorization'] ?? '';
    if (!header.toLowerCase().startsWith('bearer ')) {
      return null;
    }
    try {
      final claims = await sessionVerifier.verify(header.substring(7));
      final subject = '${claims['sub'] ?? ''}';
      return subject.isEmpty ? null : subject;
    } on AuthException {
      return null;
    }
  }

  Future<Response> deleteMe(Request request) async {
    final userId = await authenticate(request);
    if (userId == null) {
      return _jsonResponse(401, {
        'error': 'A valid session token is required.',
      });
    }
    try {
      await userStore.deleteById(userId);
      // 204 whether or not a row existed: the account is gone either way.
      return Response(204);
    } catch (error) {
      stderr.writeln(error);
      return _jsonResponse(500, {'error': 'Internal server error.'});
    }
  }

  router.delete('/me', deleteMe);
  router.post('/me/delete', deleteMe);

  router.get('/health', (Request request) {
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  });

  router.post('/auth/google', (Request request) async {
    try {
      final body = await request.readAsString();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final idToken = '${payload['idToken'] ?? ''}'.trim();
      if (idToken.isEmpty) {
        return _jsonResponse(400, {'error': 'idToken is required.'});
      }

      final claims = await verifier.verifyIdToken(idToken);
      final googleSub = '${claims['sub'] ?? ''}';
      final email = '${claims['email'] ?? ''}';
      if (googleSub.isEmpty || email.isEmpty) {
        return _jsonResponse(401, {
          'error': 'Google token payload is incomplete.',
        });
      }

      final user = await userStore.upsertGoogleUser(
        googleSub: googleSub,
        email: email,
        displayName: claims['name'] as String?,
        avatarUrl: claims['picture'] as String?,
      );
      final sessionToken = sessionIssuer.issue(user);

      return _jsonResponse(200, {
        'sessionToken': sessionToken,
        'user': user.toJson(),
      });
    } on AuthException catch (error) {
      return _jsonResponse(401, {'error': error.message});
    } on FormatException {
      return _jsonResponse(400, {'error': 'Request body must be valid JSON.'});
    } catch (error) {
      stderr.writeln(error);
      return _jsonResponse(500, {'error': 'Internal server error.'});
    }
  });

  router.get('/yahoo/localSearch', (Request request) async {
    // The proxy spends our upstream quota, so it must never be open: require a
    // valid session and cap how fast any one account can use it.
    final userId = await authenticate(request);
    if (userId == null) {
      return _jsonResponse(401, {
        'error': 'A valid session token is required.',
      });
    }
    if (!rateLimiter.allow(userId)) {
      return _jsonResponse(429, {
        'error': 'Too many search requests. Please retry in a minute.',
      });
    }

    if (config.yahooApiKey.isEmpty) {
      return _jsonResponse(500, {'error': 'YAHOO_API_KEY is not configured.'});
    }

    final yahooUri = Uri.https(
      'map.yahooapis.jp',
      '/search/local/V1/localSearch',
      {...request.url.queryParameters, 'appid': config.yahooApiKey},
    );
    final response = await http.get(yahooUri);
    return Response(
      response.statusCode,
      body: response.body,
      headers: {'content-type': 'application/json'},
    );
  });

  final pipeline = const Pipeline()
      .addMiddleware(_logPathOnly())
      .addMiddleware(_cors(config.allowedOrigins));

  return pipeline.addHandler(router.call);
}

Middleware _cors(Set<String> allowedOrigins) {
  return (innerHandler) {
    return (request) async {
      final origin = request.headers['origin'];
      final allowOrigin = origin != null && allowedOrigins.contains(origin)
          ? origin
          : allowedOrigins.first;

      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'access-control-allow-origin': allowOrigin,
            'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
            'access-control-allow-headers': 'content-type, authorization',
            'access-control-allow-credentials': 'true',
          },
        );
      }

      final response = await innerHandler(request);
      return response.change(
        headers: {
          ...response.headers,
          'access-control-allow-origin': allowOrigin,
          'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
          'access-control-allow-headers': 'content-type, authorization',
          'access-control-allow-credentials': 'true',
        },
      );
    };
  };
}

Response _jsonResponse(int statusCode, Map<String, dynamic> body) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

Future<HttpServer> runServer(ReachTrailApiConfig config) {
  return shelf_io.serve(
    buildHandler(config),
    InternetAddress.anyIPv4,
    config.port,
  );
}

/// Access log that records method, path, status and duration only.
///
/// The default [logRequests] middleware prints the full request URL, which for
/// the search proxy contains the user's query and base-location coordinates.
/// The privacy policy promises the proxy does not retain search content, so
/// the query string is deliberately left out.
Middleware _logPathOnly() {
  return (Handler inner) {
    return (Request request) async {
      final started = DateTime.now();
      final response = await inner(request);
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      stdout.writeln(
        '${started.toIso8601String()} ${request.method} '
        '/${request.url.path} ${response.statusCode} ${elapsed}ms',
      );
      return response;
    };
  };
}
