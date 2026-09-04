import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'local_config_service.dart';

class AuthenticatedUser {
  const AuthenticatedUser({
    required this.id,
    required this.email,
    required this.idToken,
    required this.sessionToken,
    this.displayName,
    this.photoUrl,
  });

  final String id;
  final String email;
  final String idToken;
  final String sessionToken;
  final String? displayName;
  final String? photoUrl;
}

class GoogleAuthService extends ChangeNotifier {
  GoogleAuthService({required LocalConfigService configService})
    : _configService = configService;

  final LocalConfigService _configService;
  final GoogleSignIn _signIn = GoogleSignIn.instance;
  final http.Client _httpClient = http.Client();
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authSubscription;
  String _apiBaseUrl = '';

  /// Incremented on every sign-out so a backend exchange that is still in
  /// flight cannot resurrect [currentUser] after the user has signed out.
  int _sessionGeneration = 0;
  bool _disposed = false;

  bool isInitializing = true;
  bool isSigningIn = false;
  String? errorMessage;
  AuthenticatedUser? currentUser;

  bool get isSignedIn => currentUser != null;

  Future<void> initialize() async {
    isInitializing = true;
    errorMessage = null;
    notifyListeners();

    try {
      final config = await _configService.load();
      _apiBaseUrl = config.apiBaseUrl;
      final signInConfiguration = _resolveSignInConfiguration(config);
      if (!signInConfiguration.isConfigured) {
        errorMessage = 'この端末向けの Google ログイン設定が見つかりません。';
        isInitializing = false;
        notifyListeners();
        return;
      }

      _authSubscription ??= _signIn.authenticationEvents.listen(
        _handleAuthenticationEvent,
        onError: _handleAuthenticationError,
      );

      await _signIn.initialize(
        clientId: signInConfiguration.clientId,
        serverClientId: signInConfiguration.serverClientId,
      );
      await _signIn.attemptLightweightAuthentication();
    } on LocalConfigException catch (error) {
      // A release build shipped without its config asset: say so plainly
      // instead of letting sign-in look merely flaky.
      errorMessage = error.message;
    } catch (error) {
      errorMessage = 'ログインの初期化に失敗しました。通信状況を確認して再度お試しください。';
    } finally {
      isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> signIn() async {
    if (!_signIn.supportsAuthenticate()) {
      // Silently doing nothing looks like a dead button, so say why.
      errorMessage = 'この端末では Google ログインを利用できません。';
      notifyListeners();
      return;
    }

    isSigningIn = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _signIn.authenticate();
    } on GoogleSignInException catch (error) {
      errorMessage = _mapGoogleError(error);
    } catch (error) {
      errorMessage = 'Google ログインに失敗しました。通信状況を確認して再度お試しください。';
    } finally {
      isSigningIn = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    errorMessage = null;
    _sessionGeneration++;
    currentUser = null;
    notifyListeners();
    try {
      await _signIn.signOut();
      currentUser = null;
    } on GoogleSignInException catch (error) {
      errorMessage = _mapGoogleError(error);
    } catch (error) {
      errorMessage = 'サインアウトに失敗しました。時間をおいて再度お試しください。';
    } finally {
      notifyListeners();
    }
  }

  void _handleAuthenticationEvent(GoogleSignInAuthenticationEvent event) {
    if (event is GoogleSignInAuthenticationEventSignIn) {
      unawaited(_updateSignedInUser(event.user));
      return;
    }

    if (event is GoogleSignInAuthenticationEventSignOut) {
      _sessionGeneration++;
      currentUser = null;
      errorMessage = null;
      notifyListeners();
    }
  }

  void _handleAuthenticationError(Object error) {
    if (error is GoogleSignInException) {
      errorMessage = _mapGoogleError(error);
    } else {
      errorMessage = 'Google ログインに失敗しました。通信状況を確認して再度お試しください。';
    }
    notifyListeners();
  }

  Future<void> _updateSignedInUser(GoogleSignInAccount account) async {
    final generation = _sessionGeneration;
    isSigningIn = true;
    notifyListeners();
    try {
      final authentication = account.authentication;
      final idToken = authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        _failSignIn(generation, 'Google の認証情報を取得できませんでした。再度お試しください。');
        return;
      }

      if (_apiBaseUrl.isEmpty) {
        _failSignIn(generation, 'APIの接続先が設定されていません。');
        return;
      }

      final http.Response response;
      try {
        response = await _httpClient
            .post(
              Uri.parse('$_apiBaseUrl/auth/google'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'idToken': idToken}),
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        _failSignIn(generation, 'サーバーへの接続がタイムアウトしました。通信環境を確認してください。');
        return;
      } catch (error) {
        _failSignIn(generation, 'サーバーに接続できませんでした。通信環境を確認してください。');
        return;
      }

      if (response.statusCode != 200) {
        _failSignIn(generation, 'サインインに失敗しました (HTTP ${response.statusCode})。');
        return;
      }

      final Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          _failSignIn(generation, 'サインインの応答を解釈できませんでした。時間をおいて再度お試しください。');
          return;
        }
        payload = Map<String, dynamic>.from(decoded);
      } on FormatException {
        _failSignIn(generation, 'サインインの応答を解釈できませんでした。時間をおいて再度お試しください。');
        return;
      }

      // The user may have signed out while this exchange was in flight; in that
      // case the result is stale and must be discarded.
      if (_isStale(generation)) {
        return;
      }

      final user = payload['user'] is Map
          ? Map<String, dynamic>.from(payload['user'] as Map)
          : const <String, dynamic>{};
      // Without a session token every authenticated call (search proxy, account
      // deletion) fails, so an empty one is a failed sign-in, not a success.
      final sessionToken = '${payload['sessionToken'] ?? ''}';
      if (sessionToken.isEmpty) {
        _failSignIn(generation, 'サインインに失敗しました。時間をおいて再度お試しください。');
        return;
      }

      currentUser = AuthenticatedUser(
        id: '${user['id'] ?? account.id}',
        email: '${user['email'] ?? account.email}',
        displayName: account.displayName,
        photoUrl: account.photoUrl,
        idToken: idToken,
        sessionToken: sessionToken,
      );
      errorMessage = null;
    } finally {
      if (!_disposed) {
        isSigningIn = false;
        notifyListeners();
      }
    }
  }

  bool _isStale(int generation) =>
      _disposed || generation != _sessionGeneration;

  void _failSignIn(int generation, String message) {
    if (_isStale(generation)) {
      return;
    }
    errorMessage = message;
    currentUser = null;
  }

  /// Deletes the server-side account for the current session.
  ///
  /// Throws [AccountDeletionException] on any failure so the caller can keep
  /// the user signed in and surface the problem.
  Future<void> deleteAccount() async {
    final sessionToken = currentUser?.sessionToken ?? '';
    if (sessionToken.isEmpty) {
      throw const AccountDeletionException(
        'ログインセッションが無効です。再度サインインしてからお試しください。',
      );
    }
    if (_apiBaseUrl.isEmpty) {
      throw const AccountDeletionException('APIの接続先が設定されていません。');
    }

    final http.Response response;
    try {
      response = await _httpClient
          .delete(
            Uri.parse('$_apiBaseUrl/me'),
            headers: {'Authorization': 'Bearer $sessionToken'},
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const AccountDeletionException(
        'サーバーへの接続がタイムアウトしました。通信環境を確認してください。',
      );
    } catch (error) {
      throw AccountDeletionException('サーバーに接続できませんでした: $error');
    }

    if (response.statusCode == 204 || response.statusCode == 200) {
      return;
    }
    if (response.statusCode == 401) {
      throw const AccountDeletionException(
        'ログインセッションの有効期限が切れました。再度サインインしてからお試しください。',
      );
    }
    throw AccountDeletionException(
      'アカウント削除に失敗しました (HTTP ${response.statusCode})。',
    );
  }

  _GoogleSignInConfiguration _resolveSignInConfiguration(LocalConfig config) {
    if (kIsWeb) {
      return _GoogleSignInConfiguration(clientId: config.googleWebClientId);
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _GoogleSignInConfiguration(
        serverClientId: config.googleWebClientId,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return _GoogleSignInConfiguration(clientId: config.googleMacosClientId);
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _GoogleSignInConfiguration(clientId: config.googleWindowsClientId);
    }
    return const _GoogleSignInConfiguration();
  }

  String _mapGoogleError(GoogleSignInException error) {
    switch (error.code) {
      case GoogleSignInExceptionCode.canceled:
        return 'サインインをキャンセルしました。';
      case GoogleSignInExceptionCode.clientConfigurationError:
        return 'Google ログインの設定に問題があります。アプリの再インストールをお試しください。';
      case GoogleSignInExceptionCode.providerConfigurationError:
        return 'Google ログインの設定に問題があります。時間をおいて再度お試しください。';
      case GoogleSignInExceptionCode.uiUnavailable:
        return 'この端末では Google ログイン画面を表示できません。';
      default:
        return 'Google ログインに失敗しました。通信状況を確認して再度お試しください。';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _authSubscription?.cancel();
    _authSubscription = null;
    _httpClient.close();
    super.dispose();
  }
}

class AccountDeletionException implements Exception {
  const AccountDeletionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _GoogleSignInConfiguration {
  const _GoogleSignInConfiguration({this.clientId, this.serverClientId});

  final String? clientId;
  final String? serverClientId;

  bool get isConfigured =>
      (clientId != null && clientId!.isNotEmpty) ||
      (serverClientId != null && serverClientId!.isNotEmpty);
}
