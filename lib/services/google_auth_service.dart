import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'local_config_service.dart';
import 'session_cache_service.dart';

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

  AuthenticatedUser copyWith({
    String? email,
    String? idToken,
    String? sessionToken,
    String? displayName,
    String? photoUrl,
  }) {
    return AuthenticatedUser(
      id: id,
      email: email ?? this.email,
      idToken: idToken ?? this.idToken,
      sessionToken: sessionToken ?? this.sessionToken,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
    );
  }
}

/// Shown while the app runs on a restored session that could not be refreshed.
const String offlineSearchUnavailableMessage =
    'オフラインのため店舗検索は利用できません。記録の閲覧と作成はそのまま行えます。';

class GoogleAuthService extends ChangeNotifier {
  GoogleAuthService({
    required LocalConfigService configService,
    SessionCacheService? sessionCache,
    http.Client? httpClient,
  }) : _configService = configService,
       _sessionCache = sessionCache ?? SessionCacheService(),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  /// How long a `/me` check stays good for, so returning to the foreground
  /// repeatedly does not hammer the API.
  static const Duration sessionCheckInterval = Duration(seconds: 60);

  final LocalConfigService _configService;
  final SessionCacheService _sessionCache;
  final GoogleSignIn _signIn = GoogleSignIn.instance;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
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

  /// True while the app runs on a cached session that could not be refreshed.
  bool isOffline = false;

  /// Non-null when place search cannot run; the Register tab shows it as a
  /// neutral banner rather than an error.
  String? searchUnavailableReason;

  /// True after the API rejected the session token, so the UI can offer a
  /// re-sign-in instead of a dead end.
  bool sessionExpired = false;

  /// True while [currentUser] comes from the local cache and has not yet been
  /// confirmed by a fresh `/auth/google` exchange.
  bool _isRestoredSession = false;

  /// True once the API has confirmed the restored session, so a later failure
  /// of an unrelated plugin call must not be reported as being offline.
  bool _sessionConfirmed = false;

  /// When the session was last checked against `/me`; used to throttle the
  /// check that runs every time the app returns to the foreground.
  DateTime? _lastSessionCheckAt;

  bool _usedLightweightAuthentication = false;

  /// Whether this startup asked Google for a silent sign-in.
  ///
  /// On Android that call opens a system "Signing you in" sheet over the app,
  /// so it may only happen on a first launch, never with a cached session.
  @visibleForTesting
  bool get usedLightweightAuthentication => _usedLightweightAuthentication;

  bool get isSignedIn => currentUser != null;

  Future<void> initialize() async {
    isInitializing = true;
    errorMessage = null;
    _usedLightweightAuthentication = false;
    notifyListeners();

    // Restore the last session before anything that needs the network, so a
    // cold start with no connectivity still opens on the home screen.
    await _restoreCachedSession();

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

      // A cached session is confirmed over HTTP instead of through Google.
      // `attemptLightweightAuthentication` launches the GMS assisted sign-in
      // sheet on Android: it flashes over the home screen on every cold start
      // and, with no connectivity, never dismisses at all.
      if (_isRestoredSession) {
        await _validateCachedSession();
      } else {
        _usedLightweightAuthentication = true;
      }

      _authSubscription ??= _signIn.authenticationEvents.listen(
        _handleAuthenticationEvent,
        onError: _handleAuthenticationError,
      );

      await _signIn.initialize(
        clientId: signInConfiguration.clientId,
        serverClientId: signInConfiguration.serverClientId,
      );
      if (_usedLightweightAuthentication) {
        // First launch only. Bounded so a sheet that never resolves cannot
        // hold the app on its startup spinner forever.
        await _signIn.attemptLightweightAuthentication()?.timeout(
          const Duration(seconds: 10),
        );
      }
    } on LocalConfigException catch (error) {
      // A release build shipped without its config asset: say so plainly
      // instead of letting sign-in look merely flaky.
      errorMessage = error.message;
    } catch (error) {
      // With a session in hand the app stays usable, so a failure here is a
      // connectivity notice at worst, never a sign-in error.
      if (currentUser != null) {
        if (!_sessionConfirmed) {
          _markOffline();
        }
      } else {
        errorMessage = 'ログインの初期化に失敗しました。通信状況を確認して再度お試しください。';
      }
    } finally {
      isInitializing = false;
      notifyListeners();
    }
  }

  /// Confirms the cached session token against the API.
  ///
  /// The three outcomes are all "stay in the app": confirmed, expired (with a
  /// re-sign-in prompt) or unreachable (offline, records still work).
  Future<void> _validateCachedSession() async {
    final token = currentUser?.sessionToken ?? '';
    if (token.isEmpty || _apiBaseUrl.isEmpty) {
      return;
    }
    _lastSessionCheckAt = DateTime.now();

    final http.Response response;
    try {
      response = await _httpClient
          .get(
            Uri.parse('$_apiBaseUrl/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      _markOffline();
      notifyListeners();
      return;
    }

    if (response.statusCode == 200) {
      _sessionConfirmed = true;
      sessionExpired = false;
      isOffline = false;
      searchUnavailableReason = null;
      _applyMeResponse(response.body);
      notifyListeners();
      return;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      markSessionExpired();
      return;
    }
    // A 5xx says nothing about the token, so the session survives.
    _markOffline();
    notifyListeners();
  }

  /// Refreshes the user's own fields from a `/me` payload, ignoring anything
  /// it cannot read: the session is already confirmed by the 200.
  void _applyMeResponse(String body) {
    final user = currentUser;
    if (user == null) {
      return;
    }
    try {
      final decoded = jsonDecode(body);
      final Map<String, dynamic> payload = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const {};
      final fields = payload['user'] is Map
          ? Map<String, dynamic>.from(payload['user'] as Map)
          : payload;
      currentUser = user.copyWith(
        email: fields['email'] is String ? fields['email'] as String : null,
        displayName: fields['displayName'] is String
            ? fields['displayName'] as String
            : null,
        photoUrl: fields['photoUrl'] is String
            ? fields['photoUrl'] as String
            : null,
      );
    } catch (_) {
      // Nothing to update; the session is what mattered.
    }
  }

  /// Drops a session token the API has rejected while keeping the user's
  /// identity, so the re-sign-in prompt can still name the account.
  void markSessionExpired() {
    sessionExpired = true;
    _sessionConfirmed = false;
    final user = currentUser;
    if (user != null && user.sessionToken.isNotEmpty) {
      currentUser = user.copyWith(sessionToken: '');
    }
    unawaited(_clearCachedSession());
    notifyListeners();
  }

  void clearSessionExpired() {
    if (!sessionExpired) {
      return;
    }
    sessionExpired = false;
    notifyListeners();
  }

  @visibleForTesting
  void debugResetSessionCheckThrottle() {
    _lastSessionCheckAt = null;
  }

  Future<void> _restoreCachedSession() async {
    final cached = await _sessionCache.load();
    if (cached == null || currentUser != null) {
      return;
    }
    currentUser = AuthenticatedUser(
      id: cached.userId,
      email: cached.email,
      displayName: cached.displayName,
      photoUrl: cached.photoUrl,
      idToken: '',
      sessionToken: cached.sessionToken,
    );
    _isRestoredSession = true;
    notifyListeners();
  }

  void _markOffline() {
    isOffline = true;
    searchUnavailableReason = offlineSearchUnavailableMessage;
  }

  /// Re-checks the session when the app returns to the foreground.
  ///
  /// This must never show UI, so it only ever talks to our own API: Google's
  /// silent sign-in would raise a system sheet over the app on every resume.
  /// Without a session there is nothing to check and nothing to ask for.
  Future<void> refreshSilently() async {
    if (currentUser == null) {
      return;
    }
    final lastCheck = _lastSessionCheckAt;
    if (lastCheck != null &&
        DateTime.now().difference(lastCheck) < sessionCheckInterval) {
      return;
    }
    await _validateCachedSession();
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
    _isRestoredSession = false;
    isOffline = false;
    searchUnavailableReason = null;
    notifyListeners();
    await _clearCachedSession();
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
      _isRestoredSession = false;
      isOffline = false;
      searchUnavailableReason = null;
      errorMessage = null;
      unawaited(_clearCachedSession());
      notifyListeners();
    }
  }

  void _handleAuthenticationError(Object error) {
    if (_isRestoredSession) {
      // The user is already inside the app on a cached session; a failed
      // background refresh must not throw an error at them.
      _markOffline();
      notifyListeners();
      return;
    }
    if (error is GoogleSignInException) {
      errorMessage = _mapGoogleError(error);
    } else {
      errorMessage = 'Google ログインに失敗しました。通信状況を確認して再度お試しください。';
    }
    notifyListeners();
  }

  Future<void> _updateSignedInUser(GoogleSignInAccount account) async {
    final authentication = account.authentication;
    final idToken = authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      isSigningIn = true;
      notifyListeners();
      _failSignIn(
        _sessionGeneration,
        'Google の認証情報を取得できませんでした。再度お試しください。',
      );
      isSigningIn = false;
      notifyListeners();
      return;
    }
    await exchangeIdTokenForSession(
      idToken: idToken,
      accountId: account.id,
      accountEmail: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    );
  }

  /// Trades a Google id token for our own session token.
  ///
  /// Split out from the Google account plumbing so the whole failure matrix
  /// (timeout, 5xx, unparseable body, empty token) can be exercised directly.
  @visibleForTesting
  Future<void> exchangeIdTokenForSession({
    required String idToken,
    required String accountId,
    required String accountEmail,
    String? displayName,
    String? photoUrl,
  }) async {
    final generation = _sessionGeneration;
    isSigningIn = true;
    notifyListeners();
    try {
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
        _failSignIn(
          generation,
          'サインインに失敗しました (HTTP ${response.statusCode})。',
          expired: response.statusCode == 401 || response.statusCode == 403,
        );
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

      final authenticatedUser = AuthenticatedUser(
        id: '${user['id'] ?? accountId}',
        email: '${user['email'] ?? accountEmail}',
        displayName: displayName,
        photoUrl: photoUrl,
        idToken: idToken,
        sessionToken: sessionToken,
      );
      currentUser = authenticatedUser;
      _isRestoredSession = false;
      _sessionConfirmed = true;
      sessionExpired = false;
      _lastSessionCheckAt = DateTime.now();
      isOffline = false;
      searchUnavailableReason = null;
      errorMessage = null;
      unawaited(
        _sessionCache.save(
          CachedSession(
            userId: authenticatedUser.id,
            email: authenticatedUser.email,
            sessionToken: authenticatedUser.sessionToken,
            displayName: authenticatedUser.displayName,
            photoUrl: authenticatedUser.photoUrl,
          ),
        ),
      );
    } finally {
      if (!_disposed) {
        isSigningIn = false;
        notifyListeners();
      }
    }
  }

  bool _isStale(int generation) =>
      _disposed || generation != _sessionGeneration;

  void _failSignIn(int generation, String message, {bool expired = false}) {
    if (_isStale(generation)) {
      return;
    }
    if (currentUser != null) {
      // A failed refresh mid-session must never eject the user: the session
      // they already have is still the best thing available. Only an
      // interactive sign-in (no session yet) surfaces the message.
      if (expired) {
        markSessionExpired();
      } else {
        _markOffline();
      }
      return;
    }
    errorMessage = message;
    currentUser = null;
    _isRestoredSession = false;
  }

  Future<void> _clearCachedSession() async {
    try {
      await _sessionCache.clear();
    } catch (_) {
      // Losing the cache is not worth surfacing; the session is gone anyway.
    }
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
      await _clearCachedSession();
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

  /// Returns null when there is nothing worth telling the user about.
  String? _mapGoogleError(GoogleSignInException error) {
    switch (error.code) {
      case GoogleSignInExceptionCode.canceled:
        // Dismissing the Google sheet is a decision, not a failure.
        return null;
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
    if (_ownsHttpClient) {
      _httpClient.close();
    }
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
