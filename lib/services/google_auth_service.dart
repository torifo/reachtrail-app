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
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authSubscription;
  String _apiBaseUrl = '';

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
        errorMessage = 'Google client ID is not configured for this platform.';
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
    } catch (error) {
      errorMessage = 'Google sign-in initialization failed: $error';
    } finally {
      isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> signIn() async {
    if (!_signIn.supportsAuthenticate()) {
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
      errorMessage = 'Google sign-in failed: $error';
    } finally {
      isSigningIn = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    errorMessage = null;
    notifyListeners();
    try {
      await _signIn.signOut();
      currentUser = null;
    } on GoogleSignInException catch (error) {
      errorMessage = _mapGoogleError(error);
    } catch (error) {
      errorMessage = 'Sign-out failed: $error';
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
      currentUser = null;
      errorMessage = null;
      notifyListeners();
    }
  }

  void _handleAuthenticationError(Object error) {
    if (error is GoogleSignInException) {
      errorMessage = _mapGoogleError(error);
    } else {
      errorMessage = 'Google sign-in error: $error';
    }
    notifyListeners();
  }

  Future<void> _updateSignedInUser(GoogleSignInAccount account) async {
    final authentication = account.authentication;
    final idToken = authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      errorMessage = 'Google ID token could not be obtained.';
      currentUser = null;
      notifyListeners();
      return;
    }

    if (_apiBaseUrl.isEmpty) {
      errorMessage = 'API base URL is not configured.';
      currentUser = null;
      notifyListeners();
      return;
    }

    final response = await http.post(
      Uri.parse('$_apiBaseUrl/auth/google'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken}),
    );
    if (response.statusCode != 200) {
      errorMessage = 'Backend sign-in failed: ${response.statusCode}';
      currentUser = null;
      notifyListeners();
      return;
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final user = payload['user'] as Map<String, dynamic>? ?? const {};
    currentUser = AuthenticatedUser(
      id: '${user['id'] ?? account.id}',
      email: '${user['email'] ?? account.email}',
      displayName: account.displayName,
      photoUrl: account.photoUrl,
      idToken: idToken,
      sessionToken: '${payload['sessionToken'] ?? ''}',
    );
    errorMessage = null;
    notifyListeners();
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
    return const _GoogleSignInConfiguration();
  }

  String _mapGoogleError(GoogleSignInException error) {
    switch (error.code) {
      case GoogleSignInExceptionCode.canceled:
        return 'Google sign-in was canceled.';
      case GoogleSignInExceptionCode.clientConfigurationError:
        return 'Google sign-in client configuration is invalid.';
      case GoogleSignInExceptionCode.providerConfigurationError:
        return 'Google sign-in provider configuration is invalid.';
      case GoogleSignInExceptionCode.uiUnavailable:
        return 'Google sign-in UI is unavailable on this device.';
      default:
        return 'Google sign-in failed: ${error.description ?? error.code.name}';
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}

class _GoogleSignInConfiguration {
  const _GoogleSignInConfiguration({this.clientId, this.serverClientId});

  final String? clientId;
  final String? serverClientId;

  bool get isConfigured =>
      (clientId != null && clientId!.isNotEmpty) ||
      (serverClientId != null && serverClientId!.isNotEmpty);
}
