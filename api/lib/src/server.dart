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
      .addMiddleware(logRequests())
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
            'access-control-allow-methods': 'GET, POST, OPTIONS',
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
          'access-control-allow-methods': 'GET, POST, OPTIONS',
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
