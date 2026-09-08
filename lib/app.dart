import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show Listenable, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, SystemNavigator;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:latlong2/latlong.dart' as latlong;

import 'models/base_location.dart';
import 'models/dine_challenge_record.dart';
import 'models/place.dart';
import 'services/google_auth_service.dart';
import 'services/local_config_service.dart';
import 'services/persistence_service.dart';
import 'services/place_search_service.dart';
import 'utils/distance_calculator.dart';
import 'utils/floor_parser.dart';
import 'utils/score_calculator.dart';
import 'widgets/google_sign_in_web_button_stub.dart'
    if (dart.library.js_interop) 'widgets/google_sign_in_web_button_web.dart';

part 'widgets/sign_in_screen.dart';

/// Shown whenever a write to local storage fails; the underlying error is not
/// actionable for the user.
const String saveFailureMessage = '保存に失敗しました。もう一度お試しください。';
const String deleteFailureMessage = '削除に失敗しました。もう一度お試しください。';

/// Shown when the local store could not be read at startup.
const String bootstrapFailureMessage = '保存データの読み込みに失敗しました。再試行してください。';

/// Shown when a search is requested before the search service could be built.
const String searchUnavailableMessage = '検索を初期化できませんでした。アプリを再起動してください。';

/// The package id used as the OpenStreetMap tile-server user agent.
const String tileUserAgentPackageName = 'net.riumu.reachtrail';

/// Identifies the tap-to-pick map so a widget test can drive its `onTap`
/// without synthesising a gesture against real map tiles.
const Key locationPickerMapKey = Key('location-picker-map');

class ReachTrailApp extends StatefulWidget {
  const ReachTrailApp({super.key});

  @override
  State<ReachTrailApp> createState() => _ReachTrailAppState();
}

/// Remembers which account the local store has already been bound to.
///
/// Signing out (or deleting the account) clears the memory, so signing back in
/// re-registers the id; without that, the next *different* account would find
/// no owner recorded and would inherit the previous user's records.
class SignedInUserTracker {
  String? _handledUserId;

  /// Returns the id whose local data must be adopted, or null when there is
  /// nothing to do.
  String? nextUserToAdopt(String? userId) {
    if (userId == null || userId.isEmpty) {
      _handledUserId = null;
      return null;
    }
    if (userId == _handledUserId) {
      return null;
    }
    _handledUserId = userId;
    return userId;
  }
}

/// What the account menu can do; kept public so tests can name the entries.
enum AccountMenuAction { signOut, switchAccount, deleteAccount }

/// Shows the confirmation that precedes a switch to another Google account.
///
/// Returns true when the user chose to go ahead.
Future<bool?> showSwitchAccountConfirmation(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('アカウントを切り替えますか？'),
      content: const Text(
        '別の Google アカウントでサインインします。'
        '別のアカウントに切り替えた場合、この端末に保存されている基準地点・店舗・記録は'
        '消去されます（同じアカウントを選び直した場合は残ります）。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('切り替える'),
        ),
      ],
    ),
  );
}

/// The single account entry point in the app bar.
///
/// Sign-out, switching accounts and deletion all act on the same thing, so
/// they share one avatar-shaped menu instead of competing for toolbar space.
class AccountMenuButton extends StatelessWidget {
  const AccountMenuButton({
    super.key,
    required this.onSignOut,
    required this.onSwitchAccount,
    required this.onDeleteAccount,
    this.photoUrl,
    this.displayName,
    this.email,
    this.enabled = true,
  });

  final VoidCallback onSignOut;
  final VoidCallback onSwitchAccount;
  final VoidCallback onDeleteAccount;

  /// The signed-in user's Google avatar, when there is one.
  final String? photoUrl;

  /// Who is signed in. Shown as the menu's header rather than in the app bar,
  /// where it crowded out the app's own name.
  final String? displayName;
  final String? email;

  /// False while an account operation is already running.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    final photo = photoUrl;
    return PopupMenuButton<AccountMenuAction>(
      tooltip: 'アカウント',
      enabled: enabled,
      icon: photo != null && photo.isNotEmpty
          ? CircleAvatar(
              radius: 14,
              backgroundImage: NetworkImage(photo),
              // A broken avatar must not take the menu down with it.
              onBackgroundImageError: (_, _) {},
            )
          : const Icon(Icons.account_circle),
      onSelected: (action) {
        switch (action) {
          case AccountMenuAction.signOut:
            onSignOut();
          case AccountMenuAction.switchAccount:
            onSwitchAccount();
          case AccountMenuAction.deleteAccount:
            onDeleteAccount();
        }
      },
      itemBuilder: (context) => [
        // Identity, not an action: it names the account the three verbs below
        // will act on, and is deliberately not selectable.
        if (_hasIdentity)
          PopupMenuItem<AccountMenuAction>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                displayName?.isNotEmpty == true ? displayName! : (email ?? ''),
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: displayName?.isNotEmpty == true && email?.isNotEmpty == true
                  ? Text(email!, overflow: TextOverflow.ellipsis)
                  : null,
            ),
          ),
        if (_hasIdentity) const PopupMenuDivider(),
        const PopupMenuItem(
          value: AccountMenuAction.signOut,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('サインアウト'),
          ),
        ),
        const PopupMenuItem(
          value: AccountMenuAction.switchAccount,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.switch_account),
            title: Text('アカウントを切り替える'),
          ),
        ),
        // Deletion is irreversible, so it is fenced off from the two
        // recoverable actions above it.
        const PopupMenuDivider(),
        PopupMenuItem(
          value: AccountMenuAction.deleteAccount,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_remove_outlined, color: errorColor),
            title: Text('アカウントを削除', style: TextStyle(color: errorColor)),
          ),
        ),
      ],
    );
  }

  bool get _hasIdentity =>
      displayName?.isNotEmpty == true || email?.isNotEmpty == true;
}

class _ReachTrailAppState extends State<ReachTrailApp> {
  late final ReachTrailController _controller;
  late final GoogleAuthService _authService;
  final SignedInUserTracker _userTracker = SignedInUserTracker();

  @override
  void initState() {
    super.initState();
    final configService = LocalConfigService();
    _authService = GoogleAuthService(configService: configService);
    _controller = ReachTrailController(
      persistence: PersistenceService(),
      configService: configService,
      sessionTokenProvider: () => _authService.currentUser?.sessionToken ?? '',
      // A token the proxy has rejected is worthless: drop it so nothing retries
      // with it, while the user's identity stays on screen for the prompt.
      onSessionExpired: () => _authService.markSessionExpired(),
      // A search that came back is proof the network is reachable, so it
      // retires any offline banner a failed check left behind.
      onNetworkSuccess: () => _authService.clearOffline(),
    )..load();
    _authService.addListener(_handleAuthChanged);
    _authService.initialize();
  }

  /// Local data belongs to whoever was signed in when it was written, so a
  /// sign-in by a different Google account must not inherit it.
  void _handleAuthChanged() {
    final userId = _userTracker.nextUserToAdopt(_authService.currentUser?.id);
    if (userId == null) {
      return;
    }
    unawaited(_controller.adoptUser(userId));
  }

  @override
  void dispose() {
    _authService.removeListener(_handleAuthChanged);
    _authService.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _authService]),
      builder: (context, _) {
        return MaterialApp(
          title: 'ReachTrail',
          debugShowCheckedModeBanner: false,
          locale: const Locale('ja'),
          supportedLocales: const [Locale('ja')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          scrollBehavior: const _NoStretchScrollBehavior(),
          theme: ThemeData(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0F766E),
              secondary: Color(0xFFB45309),
              surface: Color(0xFFFFFBF5),
              error: Color(0xFFB42318),
            ),
            scaffoldBackgroundColor: const Color(0xFFF3EEE2),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF3EEE2),
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
            ),
            // Floating, so a notice never sits flush against the navigation
            // bar and swallows the tab it covers.
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              insetPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            cardTheme: CardThemeData(
              color: Colors.white.withValues(alpha: 0.88),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.08),
                ),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.82),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: Color(0xFFD7D1C3)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: Color(0xFFD7D1C3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(
                  color: Color(0xFF0F766E),
                  width: 1.4,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
            ),
          ),
          // A restored session opens straight on the home screen: waiting for
          // initialization to finish would show a spinner over content that is
          // already usable, and offline it would never clear.
          home: _authService.isInitializing && !_authService.isSignedIn
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : !_authService.isSignedIn
              ? ReachTrailSignInScreen(authService: _authService)
              : ReachTrailHome(
                  controller: _controller,
                  authService: _authService,
                ),
        );
      },
    );
  }
}

/// Formats a whole number with thousands separators.
///
/// Distances and scores run into four and five digits, where an unbroken run
/// of digits is genuinely hard to read at a glance.
String formatCount(num value) {
  final rounded = value.round();
  final digits = rounded.abs().toString();
  final buffer = StringBuffer(rounded < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// A distance in metres, grouped and suffixed.
String formatMeters(num meters) => '${formatCount(meters)}m';

/// Shown in place of a name the snapshot never had.
const String placeholderPlaceName = '位置情報のない記録';

/// Decodes a stored place snapshot for display.
///
/// A snapshot written before coordinates were required (or corrupted since)
/// cannot be turned into a real [Place]; showing a clearly labelled placeholder
/// keeps the record list usable instead of taking the whole screen down.
Place placeFromSnapshot(Map<String, dynamic> snapshot) {
  final place = Place.tryFromJson(snapshot);
  if (place != null) {
    return place;
  }
  final storedName = '${snapshot['name'] ?? ''}'.trim();
  return Place(
    id: '${snapshot['id'] ?? ''}',
    provider: '${snapshot['provider'] ?? ''}',
    providerPlaceId: '${snapshot['providerPlaceId'] ?? ''}',
    name: storedName.isEmpty ? placeholderPlaceName : storedName,
    lat: 0,
    lng: 0,
    address: '${snapshot['address'] ?? ''}',
    isPlaceholder: true,
  );
}

final _idRandom = math.Random();

/// Builds a locally unique id.
///
/// A bare timestamp is not enough: on the web `DateTime` is backed by JS `Date`
/// and only has millisecond resolution, so two saves in the same millisecond
/// would collide and one record would silently overwrite the other.
String _newLocalId() {
  final random = _idRandom.nextInt(1 << 32).toRadixString(36);
  return '${DateTime.now().microsecondsSinceEpoch}-$random';
}

class ReachTrailController extends ChangeNotifier {
  ReachTrailController({
    required PersistenceService persistence,
    required LocalConfigService configService,
    String Function()? sessionTokenProvider,
    VoidCallback? onSessionExpired,
    VoidCallback? onNetworkSuccess,
  }) : _persistence = persistence,
       _configService = configService,
       _sessionTokenProvider = sessionTokenProvider,
       _onSessionExpired = onSessionExpired,
       _onNetworkSuccess = onNetworkSuccess;

  final PersistenceService _persistence;
  final LocalConfigService _configService;
  final String Function()? _sessionTokenProvider;
  final VoidCallback? _onSessionExpired;
  final VoidCallback? _onNetworkSuccess;
  PlaceSearchService? _searchService;

  bool isBootstrapping = true;
  String? bootstrapErrorMessage;

  /// True after the search proxy rejected the session token, so the UI can
  /// offer a re-sign-in instead of a dead end.
  bool sessionExpired = false;
  bool isSearching = false;
  bool isBaseSearching = false;
  bool isBuildingSearching = false;
  String? errorMessage;
  String? baseSearchError;
  String? buildingSearchError;
  String placeSearchProvider = 'mock';
  String? configErrorMessage;
  String yahooApiKey = '';
  String yahooProxyBaseUrl = '';

  /// True when live Yahoo search is reachable, either through the API proxy or
  /// (local development only) through a directly supplied key.
  bool get isYahooSearchEnabled =>
      placeSearchProvider.toLowerCase() == 'yahoo' &&
      (yahooProxyBaseUrl.isNotEmpty || yahooApiKey.isNotEmpty);
  BaseLocation? baseLocation;
  List<Place> places = const [];
  List<DineChallengeRecord> records = const [];
  List<Place> searchResults = const [];
  List<Place> baseSearchResults = const [];
  List<Place> buildingSearchResults = const [];
  RecordSort recordSort = RecordSort.latest;

  /// The most recent [load], so [adoptUser] can wait for a read that is still
  /// in flight instead of racing it.
  Future<void>? _loadFuture;

  Future<void> load() {
    final future = _load();
    _loadFuture = future;
    return future;
  }

  Future<void> _load() async {
    isBootstrapping = true;
    bootstrapErrorMessage = null;
    notifyListeners();
    try {
      try {
        _applyConfig(await _configService.load());
      } on LocalConfigException catch (error) {
        // A misbuilt release: keep the app usable but say so rather than
        // pretending mock search is the intended configuration.
        _applyConfig(_fallbackConfig);
        configErrorMessage = error.message;
      } catch (_) {
        _applyConfig(_fallbackConfig);
        configErrorMessage = '設定の読み込みに失敗しました。店舗検索は利用できません。';
      }
      baseLocation = await _persistence.loadBaseLocation();
      places = await _persistence.loadPlaces();
      records = await _persistence.loadRecords();
    } catch (_) {
      // Without this the app would hang forever on the startup spinner with no
      // way for the user to retry.
      bootstrapErrorMessage = bootstrapFailureMessage;
    } finally {
      isBootstrapping = false;
      notifyListeners();
    }
  }

  /// Binds the local store to [userId], wiping it first when it belongs to a
  /// different account.
  ///
  /// Signing out deliberately keeps the data, so the same person keeps their
  /// records after a re-login; the wipe happens only when a *different* user
  /// signs in on the same device.
  Future<void> adoptUser(String userId) async {
    if (userId.isEmpty) {
      return;
    }
    // A sign-in can land while the startup read is still in flight; without
    // this the read would finish after the wipe and hand the new user the
    // previous account's records.
    try {
      await _loadFuture;
    } catch (_) {
      // A failed load is already reported through `bootstrapErrorMessage`.
    }
    try {
      final previousUserId = await _persistence.loadLastUserId();
      final isDifferentUser = previousUserId != null && previousUserId != userId;
      if (isDifferentUser) {
        await clearLocalData();
      }
      await _persistence.saveLastUserId(userId);
      if (isDifferentUser) {
        await load();
      }
    } catch (_) {
      // Never block sign-in on a bookkeeping write.
    }
  }

  /// Wipes every locally stored record, place and base location.
  ///
  /// Called from in-app account deletion, after the server-side account has
  /// been removed.
  Future<void> clearLocalData() async {
    await _persistence.clearAll();
    baseLocation = null;
    places = const [];
    records = const [];
    searchResults = const [];
    baseSearchResults = const [];
    buildingSearchResults = const [];
    errorMessage = null;
    baseSearchError = null;
    buildingSearchError = null;
    notifyListeners();
  }

  Future<void> reloadConfig() async {
    final config = await _configService.load();
    _applyConfig(config);
    notifyListeners();
  }

  static const _fallbackConfig = LocalConfig(
    placeSearchProvider: 'mock',
    yahooApiKey: '',
    yahooProxyBaseUrl: '',
    apiBaseUrl: '',
    googleWebClientId: '',
    googleMacosClientId: '',
    googleWindowsClientId: '',
  );

  void _applyConfig(LocalConfig config) {
    placeSearchProvider = config.placeSearchProvider;
    yahooApiKey = config.yahooApiKey;
    yahooProxyBaseUrl = config.yahooProxyBaseUrl.isNotEmpty
        ? config.yahooProxyBaseUrl
        : (kIsWeb ? 'http://localhost:3000' : '');
    _searchService = CompositePlaceSearchService(
      SearchConfig(
        provider: placeSearchProvider,
        yahooApiKey: yahooApiKey,
        yahooProxyBaseUrl: yahooProxyBaseUrl,
        sessionTokenProvider: _sessionTokenProvider,
      ),
    );
  }

  Future<void> saveBaseLocation({
    required String name,
    required double lat,
    required double lng,
    required String floorLabel,
    required int? floorNumber,
    required String entryFloorLabel,
    required int? entryFloorNumber,
    required bool hasElevator,
    required int? elevatorRideCount,
    required String memo,
  }) async {
    final location = BaseLocation(
      id: baseLocation?.id ?? _newLocalId(),
      name: name,
      lat: lat,
      lng: lng,
      floorLabel: floorLabel,
      floorNumber: floorNumber,
      entryFloorLabel: entryFloorLabel,
      entryFloorNumber: entryFloorNumber,
      hasElevator: hasElevator,
      elevatorRideCount: elevatorRideCount,
      memo: memo,
    );
    await _persistence.saveBaseLocation(location);
    baseLocation = location;
    if (records.any((record) => record.baseLocationId == location.id)) {
      records = records
          .map(
            (record) => record.baseLocationId == location.id
                ? _recalculateRecord(record, location)
                : record,
          )
          .toList();
      await _persistence.saveRecords(records);
    }
    notifyListeners();
  }

  Future<int> deleteBaseLocation() async {
    final currentBase = baseLocation;
    if (currentBase == null) {
      return 0;
    }
    final relatedRecordCount = records
        .where((record) => record.baseLocationId == currentBase.id)
        .length;
    if (relatedRecordCount > 0) {
      records = records
          .where((record) => record.baseLocationId != currentBase.id)
          .toList();
      await _persistence.saveRecords(records);
    }
    places = _removeUnusedPlaces(places, records);
    await _persistence.savePlaces(places);
    await _persistence.deleteBaseLocation();
    baseLocation = null;
    baseSearchResults = const [];
    searchResults = const [];
    notifyListeners();
    return relatedRecordCount;
  }

  List<Place> _removeUnusedPlaces(
    List<Place> sourcePlaces,
    List<DineChallengeRecord> sourceRecords,
  ) {
    final usedPlaceIds = sourceRecords.map((record) => record.placeId).toSet();
    return sourcePlaces
        .where((place) => usedPlaceIds.contains(place.id))
        .toList();
  }

  Future<void> _deleteUnusedPlace(String placeId) async {
    final stillUsed = records.any((record) => record.placeId == placeId);
    if (stillUsed) {
      return;
    }
    final nextPlaces = places.where((place) => place.id != placeId).toList();
    if (nextPlaces.length == places.length) {
      return;
    }
    places = nextPlaces;
    await _persistence.savePlaces(places);
  }

  Future<void> searchPlaces(String query, {required bool nearbyOnly}) async {
    isSearching = true;
    errorMessage = null;
    buildingSearchError = null;
    buildingSearchResults = const [];
    notifyListeners();
    try {
      // The empty-result case is covered by the candidate panel's own guidance,
      // so it is not repeated here as a red error.
      searchResults = await _requireSearchService().search(
        query: query,
        baseLocation: baseLocation,
        nearbyOnly: nearbyOnly,
      );
      _onNetworkSuccess?.call();
    } catch (error) {
      errorMessage = describeSearchFailure(error);
      _noteSearchFailure(error);
      searchResults = const [];
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  Future<void> searchBuildingCandidates(String query) async {
    isBuildingSearching = true;
    buildingSearchError = null;
    notifyListeners();
    try {
      buildingSearchResults = await _requireSearchService().search(
        query: query,
        baseLocation: null,
        nearbyOnly: false,
        purpose: SearchPurpose.baseLocation,
      );
      _onNetworkSuccess?.call();
      if (buildingSearchResults.isEmpty) {
        buildingSearchError = '建物候補が見つかりません。建物名や住所の一部で試してください。';
      }
    } catch (error) {
      buildingSearchError = describeSearchFailure(error);
      _noteSearchFailure(error);
      buildingSearchResults = const [];
    } finally {
      isBuildingSearching = false;
      notifyListeners();
    }
  }

  Future<void> searchBaseLocations(String query) async {
    isBaseSearching = true;
    baseSearchError = null;
    notifyListeners();
    try {
      baseSearchResults = await _requireSearchService().search(
        query: query,
        baseLocation: null,
        nearbyOnly: false,
        purpose: SearchPurpose.baseLocation,
      );
      _onNetworkSuccess?.call();
      if (baseSearchResults.isEmpty) {
        baseSearchError = '基準地点候補が見つかりません。別の建物名や住所で試してください。';
      }
    } catch (error) {
      baseSearchError = describeSearchFailure(error);
      _noteSearchFailure(error);
      baseSearchResults = const [];
    } finally {
      isBaseSearching = false;
      notifyListeners();
    }
  }

  /// Drops the base-location candidate list once it has served its purpose,
  /// so a finished search does not linger as a set of tappable stale options.
  void clearBaseSearchResults() {
    if (baseSearchResults.isEmpty && baseSearchError == null) {
      return;
    }
    baseSearchResults = const [];
    baseSearchError = null;
    notifyListeners();
  }

  /// A null search service means config never loaded; a friendly message beats
  /// a null-dereference crash.
  PlaceSearchService _requireSearchService() {
    final service = _searchService;
    if (service == null) {
      throw const PlaceSearchConfigurationException(searchUnavailableMessage);
    }
    return service;
  }

  void _noteSearchFailure(Object error) {
    if (error is! SessionExpiredException || sessionExpired) {
      return;
    }
    sessionExpired = true;
    _onSessionExpired?.call();
  }

  void clearSessionExpired() {
    if (!sessionExpired) {
      return;
    }
    sessionExpired = false;
    notifyListeners();
  }

  /// How many stored records would have their distance and score recomputed if
  /// the current base location moved.
  int get recordsBoundToBaseLocation {
    final currentBase = baseLocation;
    if (currentBase == null) {
      return 0;
    }
    return records
        .where((record) => record.baseLocationId == currentBase.id)
        .length;
  }

  Future<void> saveRecord({
    String? recordId,
    required Place place,
    required double? routeDistanceMeters,
    required DateTime visitedAt,
    required int timeLimitMinutes,
    required DineType dineType,
    required String menu,
    required int? price,
    required String paymentMethod,
    required String memo,
  }) async {
    final currentBase = baseLocation;
    if (currentBase == null) {
      throw StateError('Base location is not set.');
    }

    final straightLineDistance = calculateDistanceMeters(
      startLat: currentBase.lat,
      startLng: currentBase.lng,
      endLat: place.lat,
      endLng: place.lng,
    );
    final effectiveRouteDistance = routeDistanceMeters ?? straightLineDistance;
    final baseVerticalFloors = calculateVerticalFloorTravel(
      startFloorNumber: currentBase.floorNumber,
      entryFloorNumber: currentBase.entryFloorNumber,
      destinationFloorNumber: null,
    );
    final placeVerticalFloors = calculateVerticalFloorTravel(
      startFloorNumber: null,
      entryFloorNumber: place.entranceFloorNumber,
      destinationFloorNumber: place.floorNumber,
    );
    final score = calculateDifficultyScore(
      routeDistanceMeters: effectiveRouteDistance,
      baseVerticalFloors: baseVerticalFloors,
      placeVerticalFloors: placeVerticalFloors,
      baseHasElevator: currentBase.hasElevator,
      placeHasElevator: place.hasElevator,
      dineType: dineType,
    );
    final savedPlace = _upsertPlace(place);
    final record = DineChallengeRecord(
      id: recordId ?? _newLocalId(),
      baseLocationId: currentBase.id,
      placeId: savedPlace.id,
      placeSnapshot: savedPlace.toJson(),
      visitedAt: visitedAt,
      timeLimitMinutes: timeLimitMinutes,
      dineType: dineType,
      menu: menu,
      price: price,
      paymentMethod: paymentMethod,
      memo: memo,
      straightLineDistanceMeters: straightLineDistance,
      routeDistanceMeters: effectiveRouteDistance,
      baseVerticalFloors: baseVerticalFloors,
      placeVerticalFloors: placeVerticalFloors,
      difficultyScore: score,
      scoreVersion: currentScoreVersion,
    );
    if (recordId == null) {
      records = [record, ...records];
    } else {
      records = records
          .map((item) => item.id == recordId ? record : item)
          .toList();
    }
    await _persistence.savePlaces(places);
    await _persistence.saveRecords(records);
    notifyListeners();
  }

  Future<void> deleteRecord(String recordId) async {
    final deleted = records
        .where((record) => record.id == recordId)
        .firstOrNull;
    if (deleted == null) {
      return;
    }
    final nextRecords = records
        .where((record) => record.id != recordId)
        .toList();
    records = nextRecords;
    await _persistence.saveRecords(records);
    await _deleteUnusedPlace(deleted.placeId);
    notifyListeners();
  }

  /// Puts a deleted record back, along with the place it referenced.
  ///
  /// `deleteRecord` also drops a place no other record uses, so restoring the
  /// record alone would leave it pointing at nothing; the snapshot it carries
  /// is enough to rebuild that place.
  Future<void> restoreRecord(DineChallengeRecord record) async {
    if (records.any((existing) => existing.id == record.id)) {
      return;
    }
    final place = Place.tryFromJson(record.placeSnapshot);
    if (place != null && !places.any((item) => item.id == place.id)) {
      places = [...places, place];
      await _persistence.savePlaces(places);
    }
    records = [record, ...records];
    await _persistence.saveRecords(records);
    notifyListeners();
  }

  Future<int> deleteRecordsForPlace(
    String placeId, {
    String? baseLocationId,
  }) async {
    final before = records.length;
    records = records.where((record) {
      if (record.placeId != placeId) {
        return true;
      }
      if (baseLocationId != null && record.baseLocationId != baseLocationId) {
        return true;
      }
      return false;
    }).toList();
    final deletedCount = before - records.length;
    if (deletedCount == 0) {
      return 0;
    }
    await _persistence.saveRecords(records);
    await _deleteUnusedPlace(placeId);
    notifyListeners();
    return deletedCount;
  }

  int get outdatedScoreCount =>
      records.where((item) => item.scoreVersion != currentScoreVersion).length;

  Future<int> recalculateScores() async {
    final currentBase = baseLocation;
    if (currentBase == null || records.isEmpty) {
      return 0;
    }

    var updatedCount = 0;
    final recalculated = records.map((record) {
      final updated = _recalculateRecord(record, currentBase);

      final changed =
          record.straightLineDistanceMeters !=
              updated.straightLineDistanceMeters ||
          record.routeDistanceMeters != updated.routeDistanceMeters ||
          record.baseVerticalFloors != updated.baseVerticalFloors ||
          record.placeVerticalFloors != updated.placeVerticalFloors ||
          record.difficultyScore != updated.difficultyScore ||
          record.scoreVersion != updated.scoreVersion;
      if (changed) {
        updatedCount += 1;
      }

      return updated;
    }).toList();

    records = recalculated;
    await _persistence.saveRecords(records);
    notifyListeners();
    return updatedCount;
  }

  DineChallengeRecord _recalculateRecord(
    DineChallengeRecord record,
    BaseLocation currentBase,
  ) {
    final place = Place.tryFromJson(record.placeSnapshot);
    if (place == null) {
      // No usable coordinates: leave the stored numbers as they are rather
      // than recomputing from a bogus point.
      return record;
    }
    final straightLineDistance = calculateDistanceMeters(
      startLat: currentBase.lat,
      startLng: currentBase.lng,
      endLat: place.lat,
      endLng: place.lng,
    );
    final baseVerticalFloors = calculateVerticalFloorTravel(
      startFloorNumber: currentBase.floorNumber,
      entryFloorNumber: currentBase.entryFloorNumber,
      destinationFloorNumber: null,
    );
    final placeVerticalFloors = calculateVerticalFloorTravel(
      startFloorNumber: null,
      entryFloorNumber: place.entranceFloorNumber,
      destinationFloorNumber: place.floorNumber,
    );
    final routeDistance = record.routeDistanceMeters == 0
        ? straightLineDistance
        : record.routeDistanceMeters;
    final score = calculateDifficultyScore(
      routeDistanceMeters: routeDistance,
      baseVerticalFloors: baseVerticalFloors,
      placeVerticalFloors: placeVerticalFloors,
      baseHasElevator: currentBase.hasElevator,
      placeHasElevator: place.hasElevator,
      dineType: record.dineType,
    );

    return record.copyWith(
      straightLineDistanceMeters: straightLineDistance,
      routeDistanceMeters: routeDistance,
      baseVerticalFloors: baseVerticalFloors,
      placeVerticalFloors: placeVerticalFloors,
      difficultyScore: score,
      scoreVersion: currentScoreVersion,
    );
  }

  /// How many records already exist for a place, so a candidate can say it
  /// has been visited before instead of letting the user register a duplicate
  /// without noticing.
  int recordCountForPlace(String placeId) =>
      records.where((record) => record.placeId == placeId).length;

  /// Whether a place already has a record on the same calendar day.
  bool hasRecordForPlaceOn(String placeId, DateTime day) => records.any(
    (record) =>
        record.placeId == placeId &&
        record.visitedAt.year == day.year &&
        record.visitedAt.month == day.month &&
        record.visitedAt.day == day.day,
  );

  Place _upsertPlace(Place place) {
    final index = places.indexWhere((item) => item.id == place.id);
    if (index >= 0) {
      final updated = [...places];
      updated[index] = place;
      places = updated;
      return place;
    }

    final similarIndex = places.indexWhere(
      (item) =>
          item.provider == place.provider &&
          item.providerPlaceId == place.providerPlaceId,
    );
    if (similarIndex >= 0) {
      final existing = places[similarIndex];
      final merged = place.copyWith(id: existing.id);
      final updated = [...places];
      updated[similarIndex] = merged;
      places = updated;
      return merged;
    }

    places = [place, ...places];
    return place;
  }

  List<DineChallengeRecord> get sortedRecords {
    final copy = [...records];
    switch (recordSort) {
      case RecordSort.latest:
        copy.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
      case RecordSort.distance:
        copy.sort(
          (a, b) => b.routeDistanceMeters.compareTo(a.routeDistanceMeters),
        );
      case RecordSort.difficulty:
        copy.sort((a, b) => b.difficultyScore.compareTo(a.difficultyScore));
    }
    return copy;
  }

  DineChallengeRecord? get bestDistanceRecord {
    if (records.isEmpty) {
      return null;
    }
    return sortedRecordsFor(RecordSort.distance).first;
  }

  DineChallengeRecord? get bestDifficultyRecord {
    if (records.isEmpty) {
      return null;
    }
    return sortedRecordsFor(RecordSort.difficulty).first;
  }

  ({String placeName, int count})? get mostVisitedPlace {
    if (records.isEmpty) {
      return null;
    }
    final counts = <String, int>{};
    final names = <String, String>{};
    for (final record in records) {
      counts[record.placeId] = (counts[record.placeId] ?? 0) + 1;
      names[record.placeId] ??= placeFromSnapshot(record.placeSnapshot).name;
    }
    final topId = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    return (placeName: names[topId]!, count: counts[topId]!);
  }

  List<DineChallengeRecord> sortedRecordsFor(RecordSort sort) {
    final previous = recordSort;
    recordSort = sort;
    final result = sortedRecords;
    recordSort = previous;
    return result;
  }

  void updateSort(RecordSort value) {
    recordSort = value;
    notifyListeners();
  }
}

class ReachTrailHome extends StatefulWidget {
  const ReachTrailHome({
    super.key,
    required this.controller,
    required this.authService,
  });

  final ReachTrailController controller;
  final GoogleAuthService authService;

  @override
  State<ReachTrailHome> createState() => _ReachTrailHomeState();
}

class _ReachTrailHomeState extends State<ReachTrailHome>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _isDeletingAccount = false;

  /// When the last back gesture on the first tab was seen, so the second one
  /// within [_exitConfirmationWindow] is the one that actually leaves.
  DateTime? _lastExitRequestAt;
  static const _exitConfirmationWindow = Duration(seconds: 2);

  static const _desktopBreakpoint = 1080.0;
  static const _contentMaxWidth = 1280.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    // A session token can expire while the app sits in the background; refresh
    // it quietly so the next search does not fail. Failure stays invisible.
    unawaited(widget.authService.refreshSilently());
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('サインアウトしますか？'),
        content: const Text(
          'この端末に保存された基準地点・登録した店舗・記録はそのまま残ります。'
          '同じ Google アカウントで再度サインインすると、続きから利用できます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('サインアウト'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.authService.signOut();
  }

  /// Signs out and immediately reopens Google's account chooser.
  ///
  /// Nothing local is wiped here: [SignedInUserTracker] and
  /// [ReachTrailController.adoptUser] already clear the store when the id that
  /// signs back in differs, and keep it when the same account returns.
  Future<void> _confirmSwitchAccount() async {
    final confirmed = await showSwitchAccountConfirmation(context);
    if (confirmed != true || !mounted) {
      return;
    }
    // Revoking the grant is what makes the chooser appear; without it Google
    // hands back the account the user is trying to leave.
    await widget.authService.signOut(forgetAccount: true);
    if (!mounted) {
      return;
    }
    // A cancelled sign-in simply leaves the app on the sign-in screen.
    await widget.authService.signIn();
  }

  bool get _needsReauthentication =>
      widget.controller.sessionExpired || widget.authService.sessionExpired;

  /// Re-runs the sign-in flow after the proxy rejected the session token.
  Future<void> _reauthenticate() async {
    widget.controller.clearSessionExpired();
    widget.authService.clearSessionExpired();
    await widget.authService.signIn();
  }

  /// Google Play requires an in-app route to delete the account, so this
  /// confirms, removes the server-side account, wipes local data, then signs
  /// out. If the server call fails the user stays signed in and nothing local
  /// is touched.
  Future<void> _confirmDeleteAccount(BuildContext context) async {
    // Captured before the first await so no BuildContext crosses an async gap.
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('アカウントを削除しますか？'),
        content: const Text(
          'ReachTrailのサーバーに保存されているアカウント情報（Googleアカウントの識別子・'
          'メールアドレス・表示名・アイコン）を削除します。\n\n'
          'あわせて、この端末に保存されている基準地点・登録した店舗・記録も'
          'すべて消去され、サインアウトします。\n\n'
          'この操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isDeletingAccount = true);
    try {
      await widget.authService.deleteAccount();
      await widget.controller.clearLocalData();
      await widget.authService.signOut();
      messenger.showSnackBar(const SnackBar(content: Text('アカウントを削除しました。')));
    } on AccountDeletionException catch (error) {
      // Leave the user signed in: nothing was deleted.
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('アカウント削除に失敗しました: $error')));
    } finally {
      if (mounted) {
        setState(() => _isDeletingAccount = false);
      }
    }
  }

  /// Back on the first tab: confirm, then leave.
  ///
  /// The gesture is easy to trigger by accident on a phone and the app has no
  /// server-side draft, so an unlucky swipe used to discard whatever the user
  /// was in the middle of.
  void _handleExitRequest() {
    final now = DateTime.now();
    final last = _lastExitRequestAt;
    if (last != null && now.difference(last) <= _exitConfirmationWindow) {
      SystemNavigator.pop();
      return;
    }
    _lastExitRequestAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('もう一度押すと終了します'),
          duration: _exitConfirmationWindow,
        ),
      );
  }

  Widget _buildCurrentTab(ReachTrailController controller) {
    return IndexedStack(
      index: _index,
      children: [
        _BaseLocationTab(controller: controller),
        _RegisterTab(
          controller: controller,
          searchUnavailableReason: widget.authService.searchUnavailableReason,
          sessionExpired: widget.authService.sessionExpired,
          onReauthenticate: _reauthenticate,
        ),
        _MapTab(controller: controller),
        _RecordsTab(controller: controller),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.isBootstrapping) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (controller.bootstrapErrorMessage case final message?) {
      return _BootstrapErrorScreen(message: message, onRetry: controller.load);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= _desktopBreakpoint;
        final content = _buildCurrentTab(controller);

        return PopScope(
          // Back from a secondary tab returns to the first tab. On the first
          // tab it takes two presses to leave, so a stray gesture cannot throw
          // away an in-progress session.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              return;
            }
            if (_index != 0) {
              setState(() => _index = 0);
              return;
            }
            _handleExitRequest();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('ReachTrail'),
              actions: [
                // An expired session is not confined to the Register tab: the
                // way back in has to be reachable from wherever the user is.
                if (_needsReauthentication)
                  IconButton(
                    tooltip: '再サインインが必要です',
                    onPressed: _reauthenticate,
                    icon: Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                // Which search backend is wired up is a developer detail; it only
                // confuses a tester on a release build.
                if (kDebugMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: Text(
                        controller.isYahooSearchEnabled
                            ? 'Yahoo'
                            : 'Mock Search',
                      ),
                    ),
                  ),
                // Everything that acts on the account sits in one place, so
                // the user does not have to guess which icon owns which verb.
                if (_isDeletingAccount)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                AccountMenuButton(
                  photoUrl: widget.authService.currentUser?.photoUrl,
                  displayName: widget.authService.currentUser?.displayName,
                  email: widget.authService.currentUser?.email,
                  enabled: !_isDeletingAccount,
                  onSignOut: _confirmSignOut,
                  onSwitchAccount: _confirmSwitchAccount,
                  onDeleteAccount: () => _confirmDeleteAccount(context),
                ),
              ],
            ),
            body: isDesktop
                ? Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                        child: NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: (value) =>
                              setState(() => _index = value),
                          labelType: NavigationRailLabelType.all,
                          groupAlignment: -0.8,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.place_outlined),
                              selectedIcon: Icon(Icons.place),
                              label: Text('基準'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.add_location_alt_outlined),
                              selectedIcon: Icon(Icons.add_location_alt),
                              label: Text('登録'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.map_outlined),
                              selectedIcon: Icon(Icons.map),
                              label: Text('地図'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.emoji_events_outlined),
                              selectedIcon: Icon(Icons.emoji_events),
                              label: Text('記録'),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _contentMaxWidth,
                            ),
                            child: content,
                          ),
                        ),
                      ),
                    ],
                  )
                : content,
            bottomNavigationBar: isDesktop
                ? null
                : NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: (value) =>
                        setState(() => _index = value),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.place_outlined),
                        selectedIcon: Icon(Icons.place),
                        label: '基準',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.add_location_alt_outlined),
                        selectedIcon: Icon(Icons.add_location_alt),
                        label: '登録',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.map_outlined),
                        selectedIcon: Icon(Icons.map),
                        label: '地図',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.emoji_events_outlined),
                        selectedIcon: Icon(Icons.emoji_events),
                        label: '記録',
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// Startup failed before any data was available; the user needs a way back in
/// that is not "force quit and hope".
class _BootstrapErrorScreen extends StatelessWidget {
  const _BootstrapErrorScreen({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ReachTrail')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BaseLocationTab extends StatefulWidget {
  const _BaseLocationTab({required this.controller});

  final ReachTrailController controller;

  @override
  State<_BaseLocationTab> createState() => _BaseLocationTabState();
}

class _BaseLocationTabState extends State<_BaseLocationTab> {
  late final TextEditingController _searchController;
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _floorController;
  late final TextEditingController _entryFloorController;
  late final TextEditingController _elevatorRideCountController;
  late final TextEditingController _memoController;
  final _formKey = GlobalKey<FormState>();
  final _addressFieldKey = GlobalKey();
  Place? _selectedCandidate;
  double? _selectedLat;
  double? _selectedLng;
  bool _hasElevator = true;

  /// True when the coordinates come from a map tap taken *after* a candidate
  /// had been picked, so the saved point no longer matches the name and
  /// address on screen. The form says so rather than saving a quiet mismatch.
  bool _pointOverridesCandidate = false;

  /// The name a fresh form starts with; also what "手入力で使う" is allowed to
  /// overwrite, since it is nobody's deliberate choice.
  static const String _defaultBaseName = '拠点';

  @override
  void initState() {
    super.initState();
    final base = widget.controller.baseLocation;
    _searchController = TextEditingController();
    _nameController = TextEditingController(text: base?.name ?? _defaultBaseName);
    _addressController = TextEditingController(text: base?.memo ?? '');
    _floorController = TextEditingController(text: base?.floorLabel ?? '');
    _entryFloorController = TextEditingController(
      text: base?.entryFloorLabel ?? '',
    );
    _elevatorRideCountController = TextEditingController(
      text: base?.elevatorRideCount?.toString() ?? '',
    );
    _memoController = TextEditingController();
    _selectedLat = base?.lat;
    _selectedLng = base?.lng;
    _hasElevator = base?.hasElevator ?? true;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _floorController.dispose();
    _entryFloorController.dispose();
    _elevatorRideCountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final base = controller.baseLocation;
    final divergedFromCandidate = _pointOverridesCandidate;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: '基準地点',
          subtitle: base == null
              ? 'Yahoo検索ベースで基準地点候補を探し、選んだ地点を拠点として保存します。'
              : '現在の基準地点を修正して保存できます。削除すると、この基準地点に紐づく登録地と記録も削除されます。',
          child: Form(
            key: _formKey,
            child: Column(
              spacing: 16,
              children: [
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: '建物名 / オフィス名 / 住所',
                    prefixIcon: Icon(Icons.apartment),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _runBaseSearch(),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: controller.isBaseSearching
                          ? null
                          : _runBaseSearch,
                      icon: controller.isBaseSearching
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: const Text('基準地点を検索'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_useTypedAddressAsBase()),
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: const Text('住所を手入力で使う'),
                    ),
                  ],
                ),
                if (controller.baseSearchError != null)
                  Text(
                    controller.baseSearchError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (controller.baseSearchResults.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '候補から基準地点を選択',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ...controller.baseSearchResults.map(
                  (place) => _BaseCandidateTile(
                    place: place,
                    isSelected: _selectedCandidate?.id == place.id,
                    onSelect: () => _selectBaseCandidate(place),
                  ),
                ),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '拠点名'),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty) ? '必須です' : null,
                ),
                TextFormField(
                  key: _addressFieldKey,
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: '住所 / 場所メモ',
                    hintText: '例: 東京都千代田区... / 自宅周辺',
                    prefixIcon: Icon(Icons.home_work_outlined),
                  ),
                ),
                _BaseLocationPickerMap(
                  lat: _selectedLat,
                  lng: _selectedLng,
                  onSelected: _selectBasePoint,
                ),
                TextFormField(
                  controller: _floorController,
                  decoration: const InputDecoration(
                    labelText: '拠点フロア(任意)',
                    hintText: '例: 26F',
                    prefixIcon: Icon(Icons.business_center_outlined),
                  ),
                ),
                TextFormField(
                  controller: _entryFloorController,
                  decoration: const InputDecoration(
                    labelText: '出入口フロア(任意)',
                    hintText: '例: 2F, 1F, B1',
                    prefixIcon: Icon(Icons.exit_to_app),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('拠点側にエレベータあり'),
                  subtitle: const Text('難易度計算で縦移動の負荷を軽減します。'),
                  value: _hasElevator,
                  onChanged: (value) => setState(() => _hasElevator = value),
                ),
                if (_hasElevator)
                  TextFormField(
                    controller: _elevatorRideCountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'エレベータ乗車回数(任意)',
                      hintText: '例: 1, 2',
                    ),
                  ),
                TextFormField(
                  controller: _memoController,
                  decoration: const InputDecoration(labelText: 'メモ'),
                  maxLines: 2,
                ),
                if (_selectedLat != null && _selectedLng != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '選択座標: ${_selectedLat!.toStringAsFixed(6)}, ${_selectedLng!.toStringAsFixed(6)}',
                        ),
                        if (_pointOverridesCandidate)
                          const _Tag(label: '地図で指定した位置（候補とは別）'),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton(
                        onPressed: () async {
                          if (!_formKey.currentState!.validate()) {
                            return;
                          }
                          if (_selectedLat == null || _selectedLng == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('先に基準地点候補を選んでください。'),
                              ),
                            );
                            return;
                          }
                          final messenger = ScaffoldMessenger.of(context);
                          if (!await _confirmRecalculation()) {
                            return;
                          }
                          try {
                            await controller.saveBaseLocation(
                              name: _nameController.text.trim(),
                              lat: _selectedLat!,
                              lng: _selectedLng!,
                              floorLabel: _floorController.text.trim(),
                              floorNumber: parseFloorNumber(
                                _floorController.text.trim(),
                              ),
                              entryFloorLabel: _entryFloorController.text
                                  .trim(),
                              entryFloorNumber: parseFloorNumber(
                                _entryFloorController.text.trim(),
                              ),
                              hasElevator: _hasElevator,
                              elevatorRideCount: int.tryParse(
                                _elevatorRideCountController.text.trim(),
                              ),
                              memo: _mergedBaseMemo,
                            );
                          } catch (_) {
                            messenger.showSnackBar(
                              const SnackBar(content: Text(saveFailureMessage)),
                            );
                            return;
                          }
                          if (!context.mounted) {
                            return;
                          }
                          // The query and its candidate list describe a search
                          // that is over; leaving them up invites a second,
                          // accidental save of a stale candidate.
                          setState(() {
                            _searchController.clear();
                            _pointOverridesCandidate = false;
                          });
                          controller.clearBaseSearchResults();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                divergedFromCandidate
                                    ? '基準地点を保存しました（地図で指定した位置を使用しています）。'
                                    : '基準地点を保存しました。',
                              ),
                            ),
                          );
                        },
                        child: Text(base == null ? '保存' : '修正を保存'),
                      ),
                    ],
                  ),
                ),
                // Irreversible, so it sits alone at the very end of the
                // section rather than beside the button the user came for.
                if (base != null) ...[
                  const Divider(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _deleteBaseLocation,
                      icon: const Icon(Icons.delete_outline),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      label: const Text('基準地点と関連登録地を削除'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '現在の基準地点',
          subtitle: '基準地点の設定内容を確認し、評価に使う出入口フロアや移動条件を見直せます。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              _MetricTile(
                label: '登録記録数',
                value: '${controller.records.length} 件',
              ),
              _MetricTile(
                label: '基準地点',
                value: base == null ? '未設定' : base.name,
              ),
              _MetricTile(
                label: '拠点フロア',
                value: base == null || base.floorLabel.isEmpty
                    ? '未設定'
                    : base.floorLabel,
              ),
              _MetricTile(
                label: '出入口フロア',
                value: base == null || base.entryFloorLabel.isEmpty
                    ? '未設定'
                    : base.entryFloorLabel,
              ),
              _MetricTile(
                label: '縦移動補助',
                value: base == null
                    ? '未設定'
                    : base.hasElevator
                    ? 'エレベータあり'
                    : '階段中心',
              ),
              if (base != null && base.hasElevator)
                _MetricTile(
                  label: '乗車回数',
                  value: base.elevatorRideCount?.toString() ?? '未設定',
                ),
              if (base != null)
                _MetricTile(label: '編集方法', value: '上のフォームを修正して「修正を保存」'),
              if (base != null)
                Text(
                  '座標: ${base.lat.toStringAsFixed(4)}, ${base.lng.toStringAsFixed(4)}',
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Moving the base location silently rewrites every distance and score that
  /// hangs off it, so the user is told how many records that is first.
  Future<bool> _confirmRecalculation() async {
    final affected = widget.controller.recordsBoundToBaseLocation;
    if (affected == 0) {
      return true;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('記録を再計算しますか？'),
        content: Text('この基準地点に紐づく $affected 件の記録の距離とスコアを再計算します。よろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.refresh),
            label: const Text('再計算して保存'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _runBaseSearch() async {
    // A second submit while a search is in flight would race the first.
    if (widget.controller.isBaseSearching ||
        _searchController.text.trim().isEmpty) {
      return;
    }
    await widget.controller.searchBaseLocations(_searchController.text.trim());
    if (!mounted) {
      return;
    }
    final first = widget.controller.baseSearchResults.firstOrNull;
    if (first != null) {
      _selectBaseCandidate(first);
    }
  }

  void _selectBaseCandidate(Place place) {
    setState(() {
      _selectedCandidate = place;
      _pointOverridesCandidate = false;
      _selectedLat = place.lat;
      _selectedLng = place.lng;
      _nameController.text = place.buildingName.isNotEmpty
          ? place.buildingName
          : place.name;
      _floorController.text = place.floorLabel;
      _entryFloorController.text = '';
      _elevatorRideCountController.text = '';
      _addressController.text = place.address;
    });
  }

  /// Copies the typed search text into the base-location form.
  ///
  /// The address field is often off-screen when the button is pressed, so an
  /// address the user had already written used to vanish without a trace.
  /// A non-empty, different address is now confirmed first, and the field is
  /// scrolled into view afterwards so the result is visible.
  ///
  /// The name is only filled when it is still empty or the default.
  /// Coordinates are never guessed from free text, so the user is told to tap
  /// the map unless a point has already been selected.
  Future<void> _useTypedAddressAsBase() async {
    final query = _searchController.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (query.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('先に建物名や住所を入力してください。')),
      );
      return;
    }
    final existing = _addressController.text.trim();
    if (existing.isNotEmpty && existing != query) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('住所欄を置き換えますか？'),
          content: Text('住所欄を「$query」で置き換えますか？\n\n現在の内容:\n$existing'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('置き換える'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    setState(() {
      if (_nameController.text.trim().isEmpty ||
          _nameController.text == _defaultBaseName) {
        _nameController.text = query;
      }
      _addressController.text = query;
    });
    final needsPoint = _selectedLat == null || _selectedLng == null;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          needsPoint
              ? '住所を反映しました。下の地図をタップして位置を指定してください。'
              : '住所を反映しました。',
        ),
      ),
    );
    // After the frame that applied the text, so the field is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _addressFieldKey.currentContext;
      if (fieldContext == null) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          fieldContext,
          duration: const Duration(milliseconds: 250),
          alignment: 0.2,
        ),
      );
    });
  }

  /// A map tap wins over the candidate's coordinates but leaves its name and
  /// address in the form, so the two can disagree. Rather than silently saving
  /// the mismatch the form flags it, here and in the save confirmation.
  void _selectBasePoint(latlong.LatLng point) {
    setState(() {
      _pointOverridesCandidate =
          _selectedCandidate != null || _pointOverridesCandidate;
      _selectedCandidate = null;
      _selectedLat = point.latitude;
      _selectedLng = point.longitude;
    });
  }

  String get _mergedBaseMemo {
    final address = _addressController.text.trim();
    final memo = _memoController.text.trim();
    if (address.isEmpty) {
      return memo;
    }
    if (memo.isEmpty || memo == address) {
      return address;
    }
    return '$address\n$memo';
  }

  Future<void> _deleteBaseLocation() async {
    // Captured before the first await so no BuildContext crosses an async gap.
    final messenger = ScaffoldMessenger.of(context);
    final relatedRecordCount = widget.controller.records
        .where(
          (record) =>
              record.baseLocationId == widget.controller.baseLocation?.id,
        )
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('基準地点を削除しますか？'),
        content: Text(
          relatedRecordCount == 0
              ? '基準地点の設定を削除します。登録地や記録がないため、関連データの削除はありません。'
              : 'この基準地点に紐づく登録地と $relatedRecordCount 件の記録も削除します。基準地点の内容を直したいだけなら、キャンセルして上のフォームから修正保存してください。削除後は元に戻せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // Second gate: the first dialog is easy to dismiss with a stray tap, and
    // this one takes the user's records with it.
    final reconfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本当に削除しますか'),
        content: const Text('基準地点と、それに紐づく登録地・記録を完全に削除します。元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (reconfirmed != true) {
      return;
    }
    final int deletedCount;
    try {
      deletedCount = await widget.controller.deleteBaseLocation();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(deleteFailureMessage)),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCandidate = null;
      _pointOverridesCandidate = false;
      _selectedLat = null;
      _selectedLng = null;
      _nameController.text = _defaultBaseName;
      _addressController.clear();
      _floorController.clear();
      _entryFloorController.clear();
      _elevatorRideCountController.clear();
      _memoController.clear();
      _hasElevator = true;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          deletedCount == 0
              ? '基準地点を削除しました。'
              : '基準地点と $deletedCount 件の記録を削除しました。',
        ),
      ),
    );
  }
}

class _BaseCandidateTile extends StatelessWidget {
  const _BaseCandidateTile({
    required this.place,
    required this.isSelected,
    required this.onSelect,
  });

  final Place place;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE6F6F3) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0D9488)
                : const Color(0xFFDED7CC),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      place.buildingName.isNotEmpty
                          ? place.buildingName
                          : place.name,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (isSelected) const Icon(Icons.check_circle, size: 18),
                ],
              ),
              Text(place.address),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Tag(label: place.provider.toUpperCase()),
                  if (place.floorLabel.isNotEmpty)
                    _Tag(label: place.floorLabel),
                  if (place.category.isNotEmpty &&
                      place.category != baseLocationCategoryMarker)
                    _Tag(label: place.category),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap-to-pick map, shared by the Base tab and the record sheet.
///
/// Dragging is deliberately off: the map lives inside a scrolling form, and a
/// pan gesture that starts on it used to swallow the page's vertical scroll.
/// Pinch and double-tap still zoom, and the tap that picks a point still lands.
class _BaseLocationPickerMap extends StatelessWidget {
  const _BaseLocationPickerMap({
    required this.lat,
    required this.lng,
    required this.onSelected,
    this.title = '地図で基準地点を選択',
    this.description = '住所候補がうまく出ない場合は、地図をタップして緯度経度を設定できます。',
    this.markerLabel = '基準地点',
    this.reloadLabel = '基準地点に戻す',
    this.fallbackCenter,
    this.height = 260,
  });

  final double? lat;
  final double? lng;
  final ValueChanged<latlong.LatLng> onSelected;
  final String title;
  final String description;
  final String markerLabel;
  final String reloadLabel;

  /// Where to open when nothing has been picked yet — the record sheet passes
  /// the base location so the user starts on their own neighbourhood.
  final latlong.LatLng? fallbackCenter;
  final double height;

  @override
  Widget build(BuildContext context) {
    final selectedPoint = lat == null || lng == null
        ? null
        : latlong.LatLng(lat!, lng!);
    final center =
        selectedPoint ??
        fallbackCenter ??
        const latlong.LatLng(35.681236, 139.767125);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        Text(description),
        SizedBox(
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: _MapReloadable(
              reloadLabel: reloadLabel,
              builder: (context) => FlutterMap(
                key: locationPickerMapKey,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: selectedPoint == null
                      ? (fallbackCenter == null ? 12 : 15.5)
                      : 16,
                  onTap: (_, point) => onSelected(point),
                  interactionOptions: const InteractionOptions(
                    flags:
                        InteractiveFlag.pinchZoom |
                        InteractiveFlag.doubleTapZoom,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: tileUserAgentPackageName,
                  ),
                  if (selectedPoint != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: selectedPoint,
                          // Tall enough for the selected marker's larger pin;
                          // 56 clipped it by a few pixels.
                          width: 140,
                          height: 64,
                          child: _MapMarker(
                            label: markerLabel,
                            color: const Color(0xFF1D4ED8),
                            isSelected: true,
                          ),
                        ),
                      ],
                    ),
                  // Last so no layer can be drawn over the attribution.
                  const _OpenStreetMapAttribution(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RegisterTab extends StatefulWidget {
  const _RegisterTab({
    required this.controller,
    required this.searchUnavailableReason,
    required this.sessionExpired,
    required this.onReauthenticate,
  });

  final ReachTrailController controller;

  /// Non-null while the app runs offline on a cached session.
  final String? searchUnavailableReason;
  /// True when the auth service itself has seen the session rejected.
  final bool sessionExpired;
  final Future<void> Function() onReauthenticate;

  @override
  State<_RegisterTab> createState() => _RegisterTabState();
}

class _RegisterTabState extends State<_RegisterTab> {
  final _searchController = TextEditingController();
  final _buildingSearchController = TextEditingController();
  final _mapController = MapController();
  bool _nearbyOnly = true;
  bool _showDebugInfo = false;
  bool _showAllCandidates = false;

  /// How many candidates a fresh search shows before the "もっと見る" button.
  static const int _initialCandidateCount = 5;
  String? _selectedPlaceId;
  String? _lastSearchQuery;

  @override
  void dispose() {
    _searchController.dispose();
    _buildingSearchController.dispose();
    // FlutterMap only auto-disposes a controller it created itself, and this
    // one is passed in, so it must be released here.
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final base = controller.baseLocation;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: '店舗検索',
          subtitle: '候補選択を前提にしつつ、候補が弱い場合は手入力で対応できます。',
          child: Column(
            spacing: 16,
            children: [
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  labelText: '店名 / カテゴリ / 住所',
                  prefixIcon: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _runSearch(),
              ),
              SwitchListTile(
                title: const Text('基準地点から片道徒歩45分圏内で絞り込む'),
                value: _nearbyOnly,
                onChanged: base == null
                    ? null
                    : (value) => setState(() => _nearbyOnly = value),
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      // Searching without a base location cannot rank or filter
                      // anything, so the action is disabled rather than failing.
                      onPressed: controller.isSearching || base == null
                          ? null
                          : _runSearch,
                      child: controller.isSearching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('検索'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _openRecordSheet(context),
                      child: const Text('手入力登録'),
                    ),
                  ),
                ],
              ),
              // Raw provider payloads are a development aid only; they never
              // appear in a release build.
              if (kDebugMode)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('検索デバッグ表示を有効にする'),
                  subtitle: const Text('Yahoo候補の要約とraw JSONを確認します。'),
                  value: _showDebugInfo,
                  onChanged: (value) {
                    setState(() {
                      _showDebugInfo = value ?? false;
                    });
                  },
                ),
              // Not an error: the user simply has not set a base yet.
              if (base == null)
                Text(
                  '「基準」タブで基準地点を登録すると検索できます。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              if (widget.searchUnavailableReason case final reason?)
                _NoticeBanner(message: reason, icon: Icons.cloud_off),
              if (widget.sessionExpired || controller.sessionExpired)
                _NoticeBanner(
                  message: 'ログインセッションの有効期限が切れました。再度サインインすると検索を再開できます。',
                  icon: Icons.lock_clock,
                  action: FilledButton(
                    onPressed: widget.onReauthenticate,
                    child: const Text('再サインイン'),
                  ),
                ),
              if (controller.configErrorMessage != null)
                Text(
                  controller.configErrorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (controller.errorMessage != null)
                Text(
                  controller.errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '候補',
          subtitle: '基準地点から円形半径で候補を絞り込みます。建物名と階数ラベルを確認し、必要なら補正してから記録します。',
          child: controller.searchResults.isEmpty
              ? _EmptyCandidateState(
                  searchedQuery: _lastSearchQuery,
                  baseLocation: base,
                  buildingSearchController: _buildingSearchController,
                  isBuildingSearching: controller.isBuildingSearching,
                  buildingSearchError: controller.buildingSearchError,
                  buildingSearchResults: controller.buildingSearchResults,
                  onSearchBuilding: _runBuildingSearch,
                  onUseBuildingCandidate: (candidate) => _openRecordSheet(
                    context,
                    place: _buildPlaceFromBuildingCandidate(candidate),
                  ),
                )
              : Column(
                  spacing: 12,
                  children: [
                    for (final place in _visibleCandidates)
                      _PlaceResultTile(
                        place: place,
                        baseLocation: controller.baseLocation,
                        showDebugInfo: kDebugMode && _showDebugInfo,
                        isSelected: _selectedPlaceId == place.id,
                        recordedCount: controller.recordCountForPlace(place.id),
                        onSelect: () => _selectPlace(place),
                        onUse: () => _openRecordSheet(context, place: place),
                      ),
                    // A provider can return dozens of near-identical results;
                    // the first few are the ones worth reading, and the rest
                    // are there on request rather than by default.
                    if (controller.searchResults.length >
                        _visibleCandidates.length)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () =>
                              setState(() => _showAllCandidates = true),
                          icon: const Icon(Icons.expand_more),
                          label: Text(
                            'もっと見る（残り '
                            '${controller.searchResults.length - _visibleCandidates.length} 件）',
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        if (controller.searchResults.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'レーダー',
            subtitle: '船のレーダーのように、基準地点から見た方向と距離で候補を拾います。',
            child: SizedBox(
              height: 360,
              child: _CandidateRadar(
                baseLocation: base,
                places: controller.searchResults,
                selectedPlaceId: _selectedPlaceId,
                onSelectPlace: _selectPlace,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '候補地図',
            subtitle:
                'OpenStreetMap ベースの地図で、基準地点と候補位置を直感的に比較できます。地図表示は今後も拡張予定です。',
            child: SizedBox(
              height: 320,
              child: _CandidateMap(
                mapController: _mapController,
                baseLocation: base,
                places: controller.searchResults,
                selectedPlaceId: _selectedPlaceId,
                onSelectPlace: _selectPlace,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// The candidates actually rendered: the first few, or all of them once the
  /// user has asked for the rest.
  List<Place> get _visibleCandidates {
    final results = widget.controller.searchResults;
    if (_showAllCandidates || results.length <= _initialCandidateCount) {
      return results;
    }
    return results.take(_initialCandidateCount).toList();
  }

  Future<void> _runSearch() async {
    final query = _searchController.text.trim();
    if (widget.controller.isSearching || query.isEmpty) {
      return;
    }
    setState(() {
      _lastSearchQuery = query;
      // A new search starts collapsed again.
      _showAllCandidates = false;
    });
    await widget.controller.searchPlaces(query, nearbyOnly: _nearbyOnly);
    if (!mounted) {
      return;
    }
    final results = widget.controller.searchResults;
    if (results.isNotEmpty) {
      _selectPlace(results.first, moveMap: true);
    }
  }

  Future<void> _runBuildingSearch() async {
    final query = _buildingSearchController.text.trim();
    if (widget.controller.isBuildingSearching || query.isEmpty) {
      return;
    }
    await widget.controller.searchBuildingCandidates(query);
  }

  Future<void> _openRecordSheet(BuildContext context, {Place? place}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // The sheet can reach the status bar; without this its header would sit
      // under the clock and the ✕ would be hard to hit.
      useSafeArea: true,
      // Dragging the sheet away would skip the unsaved-changes confirmation,
      // which the close button and the back gesture both honour.
      enableDrag: false,
      builder: (context) =>
          RecordSheet(controller: widget.controller, initialPlace: place),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('外食記録を保存しました。')));
    }
  }

  void _selectPlace(Place place, {bool moveMap = true}) {
    setState(() {
      _selectedPlaceId = place.id;
    });
    if (!moveMap) {
      return;
    }
    // The candidate map is only built once results exist, so right after a
    // search the controller is not attached yet and flutter_map throws. Wait
    // for the frame that builds the map before moving it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final base = widget.controller.baseLocation;
      try {
        if (base == null) {
          _mapController.move(latlong.LatLng(place.lat, place.lng), 16);
          return;
        }
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints([
              latlong.LatLng(base.lat, base.lng),
              latlong.LatLng(place.lat, place.lng),
            ]),
            padding: const EdgeInsets.all(56),
          ),
        );
      } catch (_) {
        // The map may have been disposed or rebuilt in the meantime; the
        // selection itself is already applied, so there is nothing to recover.
      }
    });
  }

  Place _buildPlaceFromBuildingCandidate(Place buildingCandidate) {
    final storeName = (_lastSearchQuery ?? '').trim();
    return Place(
      id: 'manual-building-${buildingCandidate.id}',
      provider: buildingCandidate.provider,
      providerPlaceId: 'manual-building-${buildingCandidate.providerPlaceId}',
      name: storeName.isEmpty ? buildingCandidate.name : storeName,
      lat: buildingCandidate.lat,
      lng: buildingCandidate.lng,
      address: buildingCandidate.address,
      buildingName: buildingCandidate.buildingName.isNotEmpty
          ? buildingCandidate.buildingName
          : buildingCandidate.name,
      floorLabel: buildingCandidate.floorLabel,
      floorNumber: buildingCandidate.floorNumber,
      rawPayload: buildingCandidate.rawPayload,
    );
  }
}

/// A calm, non-red banner for states the user cannot fix by retrying, such as
/// being offline or needing to sign in again.
class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, required this.icon, this.action});

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF7C58A)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: const Color(0xFFB45309)),
                const SizedBox(width: 10),
                Expanded(child: Text(message)),
              ],
            ),
            if (action != null)
              Align(alignment: Alignment.centerRight, child: action!),
          ],
        ),
      ),
    );
  }
}

class _PlaceResultTile extends StatelessWidget {
  const _PlaceResultTile({
    required this.place,
    required this.baseLocation,
    required this.showDebugInfo,
    required this.isSelected,
    required this.onSelect,
    required this.onUse,
    this.recordedCount = 0,
  });

  final Place place;
  final BaseLocation? baseLocation;
  final bool showDebugInfo;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onUse;

  /// How many records this place already has.
  final int recordedCount;

  @override
  Widget build(BuildContext context) {
    final distance = baseLocation == null
        ? null
        : calculateDistanceMeters(
            startLat: baseLocation!.lat,
            startLng: baseLocation!.lng,
            endLat: place.lat,
            endLng: place.lng,
          );
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE6F6F3) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0D9488)
                : const Color(0xFFDED7CC),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      place.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (isSelected) const Icon(Icons.near_me, size: 18),
                ],
              ),
              Text(place.address),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // First, because "have I been here already?" is the question
                  // the user is answering when they scan the list.
                  if (recordedCount > 0)
                    _Tag(label: '登録済み・$recordedCount回'),
                  _Tag(label: place.provider.toUpperCase()),
                  if (place.buildingName.isNotEmpty)
                    _Tag(label: place.buildingName),
                  if (place.floorLabel.isNotEmpty)
                    _Tag(label: place.floorLabel),
                  if (place.category.isNotEmpty &&
                      place.category != baseLocationCategoryMarker)
                    _Tag(label: place.category),
                  if (distance != null)
                    _Tag(label: '基準地点から ${formatMeters(distance)}'),
                ],
              ),
              if (showDebugInfo && place.provider == 'yahoo')
                _YahooDebugSummary(place: place),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showDebugInfo && place.provider == 'yahoo')
                      OutlinedButton.icon(
                        onPressed: () => _openDebugSheet(context),
                        icon: const Icon(Icons.bug_report_outlined),
                        label: const Text('デバッグ'),
                      ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: onUse,
                      child: const Text('この候補で記録'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDebugSheet(BuildContext context) {
    if (!kDebugMode) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // The sheet can reach the status bar; without this its header would sit
      // under the clock and the ✕ would be hard to hit.
      useSafeArea: true,
      builder: (context) => _YahooDebugSheet(place: place),
    );
  }
}

class _EmptyCandidateState extends StatelessWidget {
  const _EmptyCandidateState({
    required this.searchedQuery,
    required this.baseLocation,
    required this.buildingSearchController,
    required this.isBuildingSearching,
    required this.buildingSearchError,
    required this.buildingSearchResults,
    required this.onSearchBuilding,
    required this.onUseBuildingCandidate,
  });

  final String? searchedQuery;
  final BaseLocation? baseLocation;
  final TextEditingController buildingSearchController;
  final bool isBuildingSearching;
  final String? buildingSearchError;
  final List<Place> buildingSearchResults;
  final VoidCallback onSearchBuilding;
  final ValueChanged<Place> onUseBuildingCandidate;

  @override
  Widget build(BuildContext context) {
    final query = searchedQuery?.trim() ?? '';
    if (query.isEmpty) {
      return const Text('検索結果はまだありません。');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Text('「$query」の店舗候補は見つかりませんでした。'),
        const Text('Yahoo に店舗掲載がない場合は、建物名と階数を使って記録できます。建物名か住所で候補を探してください。'),
        if (baseLocation != null)
          Text(
            '基準地点: ${baseLocation!.name}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: buildingSearchController,
                decoration: const InputDecoration(
                  labelText: '建物名 / 住所で再検索',
                  prefixIcon: Icon(Icons.apartment_outlined),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearchBuilding(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
              ),
              onPressed: isBuildingSearching ? null : onSearchBuilding,
              child: isBuildingSearching
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('建物検索'),
            ),
          ],
        ),
        if (buildingSearchError != null)
          Text(
            buildingSearchError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (buildingSearchResults.isNotEmpty)
          ...buildingSearchResults.map(
            (place) => _BuildingCandidateTile(
              place: place,
              searchedQuery: query,
              onUse: () => onUseBuildingCandidate(place),
            ),
          ),
      ],
    );
  }
}

class _BuildingCandidateTile extends StatelessWidget {
  const _BuildingCandidateTile({
    required this.place,
    required this.searchedQuery,
    required this.onUse,
  });

  final Place place;
  final String searchedQuery;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final buildingName = place.buildingName.isNotEmpty
        ? place.buildingName
        : place.name;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDED7CC)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(buildingName, style: Theme.of(context).textTheme.titleSmall),
            Text(place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                const _Tag(label: '建物'),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                if (place.category.isNotEmpty &&
                    place.category != baseLocationCategoryMarker)
                  _Tag(label: place.category),
              ],
            ),
            Text(
              '店舗名は「$searchedQuery」を使い、建物名・座標・階数候補を引き継いで記録します。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0F766E),
                  foregroundColor: Colors.white,
                ),
                onPressed: onUse,
                child: const Text('この建物情報で記録'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateRadar extends StatelessWidget {
  const _CandidateRadar({
    required this.baseLocation,
    required this.places,
    required this.selectedPlaceId,
    required this.onSelectPlace,
  });

  final BaseLocation? baseLocation;
  final List<Place> places;
  final String? selectedPlaceId;
  final ValueChanged<Place> onSelectPlace;

  @override
  Widget build(BuildContext context) {
    if (baseLocation == null || places.isEmpty) {
      return const Center(child: Text('基準地点と候補があるとレーダー形式で表示されます。'));
    }

    final selectedPlace = places
        .where((place) => place.id == selectedPlaceId)
        .firstOrNull;

    // Light, like every other card on the page. The radar used to be a dark
    // slab dropped into a cream layout, which read as a rendering fault rather
    // than a deliberate instrument.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: const Color(0xFFF3F7F5),
        border: Border.all(color: const Color(0xFFCFE0DA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.radar, color: Color(0xFF0F766E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedPlace == null
                        ? '候補をタップして追跡'
                        : '追跡中: ${selectedPlace.name}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF123B33),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '半径 5 km',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: const Color(0xFF4C6F65),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = math.min(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final center = Offset(size / 2, size / 2);
                  final radarRadius = size / 2;
                  final nodes = _buildRadarNodes(
                    baseLocation: baseLocation!,
                    places: places,
                    selectedPlaceId: selectedPlaceId,
                    center: center,
                    radarRadius: radarRadius,
                  );

                  return Center(
                    child: SizedBox(
                      width: size,
                      height: size,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CustomPaint(
                            size: Size.square(size),
                            painter: _RadarPainter(),
                          ),
                          ...nodes.map((node) {
                            return Positioned(
                              left: node.position.dx - 28,
                              top: node.position.dy - 28,
                              child: Semantics(
                                button: true,
                                selected: selectedPlaceId == node.place.id,
                                label: node.place.name,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => onSelectPlace(node.place),
                                  child: _RadarBlip(
                                    place: node.place,
                                    distanceMeters: node.distanceMeters,
                                    isSelected:
                                        selectedPlaceId == node.place.id,
                                    showLabel:
                                        selectedPlaceId == node.place.id ||
                                        node.isPrimaryInCluster,
                                  ),
                                ),
                              ),
                            );
                          }),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Center(
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F766E),
                                    shape: BoxShape.circle,
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 12,
                                        color: Color(0x550F766E),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _RadarLegend(label: '基準', color: const Color(0xFF0F766E)),
                _RadarLegend(label: '候補', color: const Color(0xFF16A34A)),
                _RadarLegend(label: '選択中', color: const Color(0xFFEA580C)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF0F766E).withValues(alpha: 0.30);
    final crossPaint = Paint()
      ..strokeWidth = 1
      ..color = const Color(0xFF0F766E).withValues(alpha: 0.20);
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          const Color(0x330F766E),
          const Color(0x110F766E),
          Colors.transparent,
        ],
        stops: const [0.0, 0.08, 0.16, 0.22],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    for (final factor in [0.25, 0.5, 0.75, 1.0]) {
      canvas.drawCircle(center, radius * factor, ringPaint);
    }

    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      crossPaint,
    );
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      crossPaint,
    );

    canvas.drawCircle(center, radius, sweepPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

List<_RadarNode> _buildRadarNodes({
  required BaseLocation baseLocation,
  required List<Place> places,
  required String? selectedPlaceId,
  required Offset center,
  required double radarRadius,
}) {
  final rawNodes = places.map((place) {
    final distance = calculateDistanceMeters(
      startLat: baseLocation.lat,
      startLng: baseLocation.lng,
      endLat: place.lat,
      endLng: place.lng,
    );
    final bearing = _calculateBearingDegrees(
      startLat: baseLocation.lat,
      startLng: baseLocation.lng,
      endLat: place.lat,
      endLng: place.lng,
    );

    return _RadarNode(
      place: place,
      distanceMeters: distance,
      position: _radarPoint(
        center: center,
        radius: radarRadius,
        distanceMeters: distance,
        bearingDegrees: bearing,
      ),
      isPrimaryInCluster: false,
    );
  }).toList();

  final adjustedNodes = <_RadarNode>[];
  final clusterThreshold = radarRadius * 0.14;

  for (var index = 0; index < rawNodes.length; index += 1) {
    final node = rawNodes[index];
    final neighbors = rawNodes
        .where((other) => !identical(other, node))
        .where(
          (other) =>
              (node.position - other.position).distance <= clusterThreshold,
        )
        .toList();

    final clusterIndex = neighbors.length;
    final angleOffset = clusterIndex == 0
        ? 0.0
        : (clusterIndex.isEven ? 1 : -1) *
              (10 + clusterIndex * 8) *
              math.pi /
              180;
    final radialOffset = clusterIndex == 0 ? 0.0 : 10.0 + clusterIndex * 6.0;
    final vector = node.position - center;
    final rotated = Offset(
      vector.dx * math.cos(angleOffset) - vector.dy * math.sin(angleOffset),
      vector.dx * math.sin(angleOffset) + vector.dy * math.cos(angleOffset),
    );
    final normalized = rotated.distance == 0
        ? const Offset(0, -1)
        : rotated / rotated.distance;

    adjustedNodes.add(
      node.copyWith(
        position: center + rotated + normalized * radialOffset,
        isPrimaryInCluster:
            neighbors.isEmpty ||
            selectedPlaceId == node.place.id ||
            clusterIndex == 0,
      ),
    );
  }

  return adjustedNodes;
}

class _RadarNode {
  const _RadarNode({
    required this.place,
    required this.distanceMeters,
    required this.position,
    required this.isPrimaryInCluster,
  });

  final Place place;
  final double distanceMeters;
  final Offset position;
  final bool isPrimaryInCluster;

  _RadarNode copyWith({
    Place? place,
    double? distanceMeters,
    Offset? position,
    bool? isPrimaryInCluster,
  }) {
    return _RadarNode(
      place: place ?? this.place,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      position: position ?? this.position,
      isPrimaryInCluster: isPrimaryInCluster ?? this.isPrimaryInCluster,
    );
  }
}

class _RadarBlip extends StatelessWidget {
  const _RadarBlip({
    required this.place,
    required this.distanceMeters,
    required this.isSelected,
    required this.showLabel,
  });

  final Place place;
  final double distanceMeters;
  final bool isSelected;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The dot itself is far below the 48dp minimum target, so it sits
        // centred in a 48dp box that takes the tap.
        SizedBox.square(
          dimension: 48,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: isSelected ? 18 : 12,
              height: isSelected ? 18 : 12,
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFEA580C)
                    : const Color(0xFF16A34A),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    blurRadius: isSelected ? 14 : 8,
                    color:
                        (isSelected
                                ? const Color(0xFFEA580C)
                                : const Color(0xFF16A34A))
                            .withValues(alpha: 0.35),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showLabel) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 80),
            // Two lines, hard-clamped: an unbounded label used to run past the
            // radar and print itself over the legend below it.
            child: Text(
              '${place.name}\n${formatMeters(distanceMeters)}',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: const Color(0xFF123B33),
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _RadarLegend extends StatelessWidget {
  const _RadarLegend({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: const Color(0xFF4C6F65)),
        ),
      ],
    );
  }
}

Offset _radarPoint({
  required Offset center,
  required double radius,
  required double distanceMeters,
  required double bearingDegrees,
}) {
  final normalizedDistance = (distanceMeters / walkingSearchRadiusMeters).clamp(
    0.08,
    1.0,
  );
  final visualRadius = radius * normalizedDistance * 0.92;
  final radians = (bearingDegrees - 90) * math.pi / 180;

  return Offset(
    center.dx + math.cos(radians) * visualRadius,
    center.dy + math.sin(radians) * visualRadius,
  );
}

double _calculateBearingDegrees({
  required double startLat,
  required double startLng,
  required double endLat,
  required double endLng,
}) {
  final startLatRad = startLat * math.pi / 180;
  final endLatRad = endLat * math.pi / 180;
  final deltaLng = (endLng - startLng) * math.pi / 180;

  final y = math.sin(deltaLng) * math.cos(endLatRad);
  final x =
      math.cos(startLatRad) * math.sin(endLatRad) -
      math.sin(startLatRad) * math.cos(endLatRad) * math.cos(deltaLng);
  final bearing = math.atan2(y, x) * 180 / math.pi;

  return (bearing + 360) % 360;
}

class _CandidateMap extends StatelessWidget {
  const _CandidateMap({
    required this.mapController,
    required this.baseLocation,
    required this.places,
    required this.selectedPlaceId,
    required this.onSelectPlace,
  });

  final MapController mapController;
  final BaseLocation? baseLocation;
  final List<Place> places;
  final String? selectedPlaceId;
  final ValueChanged<Place> onSelectPlace;

  /// A camera frame covering the base location and every place on the map.
  ///
  /// Null when there is only one point to show, where a bounds fit would zoom
  /// to the maximum level on a single coordinate.
  CameraFit? _cameraFit() {
    final points = <latlong.LatLng>[
      if (baseLocation != null)
        latlong.LatLng(baseLocation!.lat, baseLocation!.lng),
      for (final place in places) latlong.LatLng(place.lat, place.lng),
    ];
    if (points.length < 2) {
      return null;
    }
    return CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(56),
      maxZoom: 16.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedPlace = places
        .where((place) => place.id == selectedPlaceId)
        .firstOrNull;
    final centerPlace = selectedPlace ?? places.firstOrNull;
    if (baseLocation == null && centerPlace == null) {
      return const Center(child: Text('地図に表示できる地点がありません。'));
    }
    final center = latlong.LatLng(
      baseLocation?.lat ?? centerPlace!.lat,
      baseLocation?.lng ?? centerPlace!.lng,
    );
    // Everything the map is meant to show, so it opens framing all of it
    // instead of a fixed zoom around the base with the places off-screen.
    final fit = _cameraFit();

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: _MapReloadable(
        onReload: () {
          try {
            if (fit == null) {
              mapController.move(center, 15.5);
            } else {
              mapController.fitCamera(fit);
            }
          } catch (_) {
            // The map may not be attached yet; the rebuild already reset the
            // camera to the same frame.
          }
        },
        builder: (context) => FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15.5,
            initialCameraFit: fit,
            onTap: (_, point) {},
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: tileUserAgentPackageName,
            ),
            if (baseLocation != null && selectedPlace != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [
                      latlong.LatLng(baseLocation!.lat, baseLocation!.lng),
                      latlong.LatLng(selectedPlace.lat, selectedPlace.lng),
                    ],
                    strokeWidth: 4,
                    color: const Color(0xFF0D9488),
                    pattern: StrokePattern.dashed(segments: [10, 8]),
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (baseLocation != null)
                  Marker(
                    point: latlong.LatLng(baseLocation!.lat, baseLocation!.lng),
                    width: 120,
                    height: 56,
                    child: const _MapMarker(
                      label: '基準地点',
                      color: Color(0xFF1D4ED8),
                      isSelected: false,
                    ),
                  ),
                ...places.map(
                  (place) => Marker(
                    point: latlong.LatLng(place.lat, place.lng),
                    width: 140,
                    height: 64,
                    child: Semantics(
                      button: true,
                      selected: selectedPlaceId == place.id,
                      label: place.name,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelectPlace(place),
                        child: _MapMarker(
                          label: place.name,
                          color: const Color(0xFF0D9488),
                          isSelected: selectedPlaceId == place.id,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Last so no marker or polyline can be drawn over the attribution.
            const _OpenStreetMapAttribution(),
          ],
        ),
      ),
    );
  }
}

/// OpenStreetMap's tile usage policy requires visible attribution on every map.
class _OpenStreetMapAttribution extends StatelessWidget {
  const _OpenStreetMapAttribution();

  @override
  Widget build(BuildContext context) {
    // Hand-rolled rather than `SimpleAttributionWidget`: that one hardcodes a
    // "flutter_map | " prefix which advertises the mapping package to the user
    // and crowds out the credit that actually has to be visible. The rich
    // variant is no better — it hides the credit behind a badge to tap.
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: const Padding(
            padding: EdgeInsets.all(3),
            child: Text('© OpenStreetMap contributors'),
          ),
        ),
      ),
    );
  }
}

class _MapReloadable extends StatefulWidget {
  const _MapReloadable({
    required this.builder,
    this.onReload,
    this.reloadLabel = 'リロード',
  });

  final WidgetBuilder builder;
  final VoidCallback? onReload;

  /// What the button promises. "リロード" reads like a network retry, so a map
  /// whose button really just recentres says so instead.
  final String reloadLabel;

  @override
  State<_MapReloadable> createState() => _MapReloadableState();
}

class _MapReloadableState extends State<_MapReloadable> {
  int _generation = 0;

  void _reload() {
    setState(() => _generation += 1);
    final callback = widget.onReload;
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: KeyedSubtree(
            key: ValueKey('map-reload-$_generation'),
            child: Builder(builder: widget.builder),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Material(
            color: const Color(0xFF0F766E),
            elevation: 4,
            shadowColor: Colors.black.withValues(alpha: 0.35),
            shape: const StadiumBorder(
              side: BorderSide(color: Colors.white, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _reload,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Tooltip(
                  message: widget.reloadLabel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.reloadLabel,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MapMarker extends StatelessWidget {
  const _MapMarker({
    required this.label,
    required this.color,
    required this.isSelected,
  });

  final String label;
  final Color color;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? color : color.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(
                blurRadius: 12,
                offset: Offset(0, 6),
                color: Color(0x22000000),
              ),
            ],
          ),
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Icon(Icons.location_on, color: color, size: isSelected ? 30 : 24),
      ],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}

class _YahooDebugSummary extends StatelessWidget {
  const _YahooDebugSummary({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final summary = _buildYahooDebugSummary(place);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F1E3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(
              'Debug Summary',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            ...summary.entries.map(
              (entry) => Text('${entry.key}: ${entry.value}'),
            ),
          ],
        ),
      ),
    );
  }
}

class _YahooDebugSheet extends StatelessWidget {
  const _YahooDebugSheet({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final summary = _buildYahooDebugSummary(place);
    final raw = _formatRawPayload(place.rawPayload);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Text(place.name, style: Theme.of(context).textTheme.headlineSmall),
            Text('Yahoo candidate debug'),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF7F1E3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: summary.entries
                      .map((entry) => Text('${entry.key}: ${entry.value}'))
                      .toList(),
                ),
              ),
            ),
            SelectableText(
              raw,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}

Map<String, String> _buildYahooDebugSummary(Place place) {
  final parsed = _parseRawPayload(place.rawPayload);
  final property = _mapOrEmpty(parsed['Property']);
  final placeInfo = _mapOrEmpty(property['PlaceInfo']);
  final building = _mapOrEmpty(property['Building']);
  final geometry = _mapOrEmpty(parsed['Geometry']);
  final genreNames = (_listOrEmpty(
    property['Genre'],
  )).map((item) => _mapOrEmpty(item)['Name']).whereType<String>().join(', ');

  return {
    'ProviderPlaceId': place.providerPlaceId,
    'Name': place.name,
    'Address': place.address,
    'Genre': genreNames.isEmpty ? place.category : genreNames,
    'Building.Name': '${building['Name'] ?? ''}',
    'PlaceInfo.FloorName': '${placeInfo['FloorName'] ?? ''}',
    'Building.Floor': '${building['Floor'] ?? ''}',
    'Coordinates': '${geometry['Coordinates'] ?? ''}',
  };
}

Map<String, dynamic> _parseRawPayload(String rawPayload) {
  if (rawPayload.trim().isEmpty) {
    return const {};
  }

  try {
    return Map<String, dynamic>.from(jsonDecode(rawPayload) as Map);
  } catch (_) {
    return const {};
  }
}

Map<String, dynamic> _mapOrEmpty(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

List<dynamic> _listOrEmpty(Object? value) {
  if (value is List) {
    return value;
  }
  return const [];
}

String _formatRawPayload(String rawPayload) {
  final parsed = _parseRawPayload(rawPayload);
  if (parsed.isEmpty) {
    return rawPayload.isEmpty ? 'No raw payload' : rawPayload;
  }
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(parsed);
}

/// The create/edit form for a record.
///
/// Public so a widget test can pump it directly.
class RecordSheet extends StatefulWidget {
  const RecordSheet({
    super.key,
    required this.controller,
    this.initialPlace,
    this.existingRecord,
  });

  final ReachTrailController controller;
  final Place? initialPlace;
  final DineChallengeRecord? existingRecord;

  @override
  State<RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<RecordSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _buildingController;
  late final TextEditingController _floorLabelController;
  late final TextEditingController _entranceFloorLabelController;
  late final TextEditingController _elevatorRideCountController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late final TextEditingController _routeDistanceController;
  late final TextEditingController _categoryController;
  late final TextEditingController _menuController;
  late final TextEditingController _priceController;
  late final TextEditingController _paymentController;
  late final TextEditingController _memoController;
  late final TextEditingController _timeLimitController;
  DineType _dineType = DineType.dineIn;
  DateTime _visitedAt = DateTime.now();
  bool _submitting = false;

  /// Set once the user has actually *changed* something, so closing the sheet
  /// by accident cannot throw the entry away without asking.
  ///
  /// Compared against a snapshot rather than latched on the first listener
  /// callback: focusing a field or moving the caret fires the controller's
  /// listeners without editing anything, and used to arm the discard prompt on
  /// a form the user had not touched.
  bool _isDirty = false;
  late final List<String> _initialTexts;
  late final DineType _initialDineType;
  late final DateTime _initialVisitedAt;
  late final bool _initialHasElevator;
  bool _hasElevator = true;
  late bool _showPlaceDetails;
  late bool _showVisitDetails;

  /// Anchors used to scroll a section back into view once it expands.
  final _visitDetailsKey = GlobalKey();
  final _placeDetailsKey = GlobalKey();

  /// Coordinates are normally set by tapping the picker map; the raw fields
  /// stay collapsed for the rare case that needs them.
  bool _showRawCoordinates = false;

  @override
  void initState() {
    super.initState();
    final place = widget.initialPlace;
    // A placeholder carries fabricated data (0, 0 and a stand-in name) purely
    // so the record list stays readable. Offering it back as if the user had
    // typed it would let a save write those coordinates for real, so the
    // fields start empty and the form's own required rules take over.
    final isPlaceholder = place?.isPlaceholder ?? false;
    _nameController = TextEditingController(
      text: isPlaceholder && place!.name == placeholderPlaceName
          ? ''
          : place?.name ?? '',
    );
    _addressController = TextEditingController(text: place?.address ?? '');
    _buildingController = TextEditingController(
      text: place?.buildingName ?? '',
    );
    _floorLabelController = TextEditingController(
      text: place?.floorLabel ?? '',
    );
    _entranceFloorLabelController = TextEditingController(
      text: place?.entranceFloorLabel ?? '',
    );
    _elevatorRideCountController = TextEditingController(
      text: place?.elevatorRideCount?.toString() ?? '',
    );
    _latController = TextEditingController(
      text: isPlaceholder ? '' : place?.lat.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: isPlaceholder ? '' : place?.lng.toString() ?? '',
    );
    _routeDistanceController = TextEditingController(
      text: widget.existingRecord?.routeDistanceMeters.toStringAsFixed(0) ?? '',
    );
    _categoryController = TextEditingController(text: place?.category ?? '');
    _menuController = TextEditingController(
      text: widget.existingRecord?.menu ?? '',
    );
    _priceController = TextEditingController(
      text: widget.existingRecord?.price?.toString() ?? '',
    );
    _paymentController = TextEditingController(
      text: widget.existingRecord?.paymentMethod ?? '',
    );
    _memoController = TextEditingController(
      text: widget.existingRecord?.memo ?? '',
    );
    _timeLimitController = TextEditingController(
      text: '${widget.existingRecord?.timeLimitMinutes ?? 60}',
    );
    _dineType = widget.existingRecord?.dineType ?? DineType.dineIn;
    _visitedAt = widget.existingRecord?.visitedAt ?? DateTime.now();
    _hasElevator = place?.hasElevator ?? true;
    _showPlaceDetails = place == null || widget.existingRecord != null;
    _showVisitDetails = widget.existingRecord != null;

    final straightDistance = _estimatedStraightLineDistanceMeters;
    if (_routeDistanceController.text.trim().isEmpty &&
        straightDistance != null) {
      _routeDistanceController.text = straightDistance.toStringAsFixed(0);
    }

    for (final controller in [
      _nameController,
      _latController,
      _lngController,
      _timeLimitController,
    ]) {
      controller.addListener(_refreshRequiredStatus);
    }
    _initialTexts = [
      for (final controller in _editableControllers) controller.text,
    ];
    _initialDineType = _dineType;
    _initialVisitedAt = _visitedAt;
    _initialHasElevator = _hasElevator;

    for (final controller in _editableControllers) {
      controller.addListener(_recheckDirty);
    }
  }

  List<TextEditingController> get _editableControllers => [
    _nameController,
    _addressController,
    _buildingController,
    _floorLabelController,
    _entranceFloorLabelController,
    _elevatorRideCountController,
    _latController,
    _lngController,
    _routeDistanceController,
    _categoryController,
    _menuController,
    _priceController,
    _paymentController,
    _memoController,
    _timeLimitController,
  ];

  /// True when anything on the form differs from what it opened with.
  bool get _hasChanges {
    final controllers = _editableControllers;
    for (var i = 0; i < controllers.length; i++) {
      if (controllers[i].text != _initialTexts[i]) {
        return true;
      }
    }
    return _dineType != _initialDineType ||
        _visitedAt != _initialVisitedAt ||
        _hasElevator != _initialHasElevator;
  }

  void _recheckDirty() {
    final dirty = _hasChanges;
    if (dirty == _isDirty) {
      return;
    }
    // Without a rebuild the PopScope keeps its stale `canPop` and the back
    // gesture discards the entry without asking.
    if (mounted) {
      setState(() => _isDirty = dirty);
    } else {
      _isDirty = dirty;
    }
  }

  @override
  void dispose() {
    for (final controller in _editableControllers) {
      controller.removeListener(_recheckDirty);
    }
    _nameController.dispose();
    _addressController.dispose();
    _buildingController.dispose();
    _floorLabelController.dispose();
    _entranceFloorLabelController.dispose();
    _elevatorRideCountController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _routeDistanceController.dispose();
    _categoryController.dispose();
    _menuController.dispose();
    _priceController.dispose();
    _paymentController.dispose();
    _memoController.dispose();
    _timeLimitController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _required(_nameController.text) == null &&
      _requiredDouble(_latController.text) == null &&
      _requiredDouble(_lngController.text) == null &&
      _requiredInt(_timeLimitController.text) == null;

  List<String> get _missingRequiredLabels {
    final labels = <String>[];
    if (_required(_nameController.text) != null) {
      labels.add('店舗名');
    }
    if (_requiredDouble(_latController.text) != null ||
        _requiredDouble(_lngController.text) != null) {
      labels.add('位置');
    }
    if (_requiredInt(_timeLimitController.text) != null) {
      labels.add('制限時間');
    }
    return labels;
  }

  double? get _estimatedStraightLineDistanceMeters {
    final base = widget.controller.baseLocation;
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (base == null || lat == null || lng == null) {
      return null;
    }
    return calculateDistanceMeters(
      startLat: base.lat,
      startLng: base.lng,
      endLat: lat,
      endLng: lng,
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final missingRequiredLabels = _missingRequiredLabels;
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        unawaited(_close());
      },
      // The sheet can reach the top of the screen, where the status bar would
      // otherwise sit over the title and the ✕.
      child: SafeArea(
        top: true,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 14,
              children: [
                _RecordSheetHeader(
                  title: widget.existingRecord != null
                      ? '記録を編集'
                      : widget.initialPlace == null
                      ? '手入力で記録'
                      : '候補から記録',
                  onClose: _close,
                ),
                TextFormField(
                  controller: _nameController,
                  decoration: _fieldDecoration('店舗名', isRequired: true),
                  validator: _required,
                ),
                _RecordSheetSection(
                  key: _placeDetailsKey,
                  title: 'お店の詳細',
                  subtitle: _showPlaceDetails
                      ? '位置、階数、移動負荷を確認できます。'
                      : '候補の位置情報は入力済みです。必要な時だけ開いて修正できます。',
                  expanded: _showPlaceDetails,
                  onExpansionChanged: (value) {
                    setState(() => _showPlaceDetails = value);
                    if (value) {
                      _revealSection(_placeDetailsKey);
                    }
                  },
                  children: [_buildPlaceDetailsFields()],
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: DineType.values.map((type) {
                    return ChoiceChip(
                      label: Text(type == DineType.dineIn ? '店内飲食' : 'テイクアウト'),
                      selected: _dineType == type,
                      onSelected: (_) {
                        setState(() => _dineType = type);
                        _recheckDirty();
                      },
                    );
                  }).toList(),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _timeLimitController,
                        keyboardType: TextInputType.number,
                        decoration: _fieldDecoration(
                          '制限時間(分)',
                          isRequired: true,
                        ),
                        validator: _requiredInt,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDateTime,
                        icon: const Icon(Icons.event),
                        label: Text(
                          RecordCardHeader.formatVisitedDate(_visitedAt),
                        ),
                      ),
                    ),
                  ],
                ),
                _RecordSheetSection(
                  key: _visitDetailsKey,
                  title: '食事メモ',
                  subtitle: 'メニュー、価格、支払い方法、メモは後からでも追記できます。',
                  expanded: _showVisitDetails,
                  onExpansionChanged: (value) {
                    setState(() => _showVisitDetails = value);
                    if (value) {
                      _revealSection(_visitDetailsKey);
                    }
                  },
                  children: [_buildVisitDetailsFields()],
                ),
                _RecordSaveBar(
                  canSubmit: _canSubmit,
                  isSubmitting: _submitting,
                  isEditing: widget.existingRecord != null,
                  missingRequiredLabels: missingRequiredLabels,
                  onSubmit: _submitting || !_canSubmit ? null : _submit,
                ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Brings a section the user just opened back into view.
  ///
  /// An expansion near the bottom of the sheet otherwise unfolds entirely
  /// below the fold, so the tap appears to have done nothing.
  void _revealSection(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sectionContext = key.currentContext;
      if (sectionContext == null) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          sectionContext,
          duration: const Duration(milliseconds: 250),
          alignment: 0.1,
        ),
      );
    });
  }

  Future<void> _close() async {
    if (!await _confirmDiscard() || !mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  /// Returns true when the sheet may be closed.
  Future<bool> _confirmDiscard() async {
    if (!_isDirty || _submitting) {
      return true;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Sized down rather than shortened: at the default dialog title size
        // this question wraps in the middle of a word.
        titleTextStyle: Theme.of(
          dialogContext,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        title: const Text('入力内容を破棄しますか？'),
        content: const Text('保存していない入力内容は失われます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('編集を続ける'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('破棄する'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Widget _buildPlaceDetailsFields() {
    return Column(
      spacing: 14,
      children: [
        TextFormField(
          controller: _addressController,
          decoration: _fieldDecoration('住所'),
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _buildingController,
                decoration: _fieldDecoration('建物名'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _categoryController,
                decoration: _fieldDecoration('カテゴリ'),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _floorLabelController,
                decoration: _fieldDecoration('目的フロア'),
              ),
            ),
          ],
        ),
        TextFormField(
          controller: _entranceFloorLabelController,
          decoration: _fieldDecoration('入口フロア'),
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _routeDistanceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: _fieldDecoration(
                  '最短距離(m)',
                  hintText: '例: 850',
                  helperText: '最短距離は徒歩経路、直線距離は地図上の距離',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InputDecorator(
                decoration: _fieldDecoration(
                  '直線距離(m)',
                  hintText: '自動計算',
                  helperText: '基準地点からの直線距離',
                ),
                child: Text(
                  _estimatedStraightLineDistanceMeters == null
                      ? '—'
                      : formatCount(_estimatedStraightLineDistanceMeters!),
                ),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('店舗側にエレベータあり'),
          subtitle: const Text('入口階から目的階までの縦移動負荷を軽減します。'),
          value: _hasElevator,
          onChanged: (value) {
            setState(() => _hasElevator = value);
            _recheckDirty();
          },
        ),
        if (_hasElevator)
          TextFormField(
            controller: _elevatorRideCountController,
            keyboardType: TextInputType.number,
            decoration: _fieldDecoration('エレベータ乗車回数', hintText: '例: 1, 2'),
          ),
        // The primary way to give a manual record its position. Typing raw
        // latitude and longitude was the only way before, which made manual
        // registration effectively unusable on a phone.
        _BaseLocationPickerMap(
          lat: double.tryParse(_latController.text.trim()),
          lng: double.tryParse(_lngController.text.trim()),
          onSelected: _selectPlacePoint,
          title: '地図でお店の位置を指定',
          description: '地図をタップするとその地点が店舗の位置になります。',
          markerLabel: 'お店',
          reloadLabel: '基準地点に戻す',
          fallbackCenter: _baseCenter,
          height: 240,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _hasPickedCoordinates
                ? '選択座標: ${_latController.text.trim()}, ${_lngController.text.trim()}'
                : '位置が未設定です。地図をタップして指定してください。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        // Raw coordinates are still reachable for the rare case that needs
        // them, but they no longer greet the user as two required fields.
        _RecordSheetSection(
          title: '座標を直接入力',
          subtitle: '緯度・経度が分かっている場合のみ使います。',
          expanded: _showRawCoordinates,
          onExpansionChanged: (value) =>
              setState(() => _showRawCoordinates = value),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _latController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: _fieldDecoration('緯度', isRequired: true),
                    validator: _requiredDouble,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _lngController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: _fieldDecoration('経度', isRequired: true),
                    validator: _requiredDouble,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  bool get _hasPickedCoordinates =>
      double.tryParse(_latController.text.trim()) != null &&
      double.tryParse(_lngController.text.trim()) != null;

  latlong.LatLng? get _baseCenter {
    final base = widget.controller.baseLocation;
    return base == null ? null : latlong.LatLng(base.lat, base.lng);
  }

  /// Writes a tapped point into the coordinate fields.
  ///
  /// Six decimals is roughly 0.1 m, well past anything a tap can express, and
  /// keeps the text short enough to read back in the raw fields.
  void _selectPlacePoint(latlong.LatLng point) {
    _latController.text = point.latitude.toStringAsFixed(6);
    _lngController.text = point.longitude.toStringAsFixed(6);
    // The controllers' own listeners already refresh the required-field state
    // and the dirty flag; this rebuild is for the map's marker.
    setState(() {});
  }

  Widget _buildVisitDetailsFields() {
    return Column(
      spacing: 14,
      children: [
        TextFormField(
          controller: _menuController,
          decoration: _fieldDecoration('メニュー'),
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _priceController,
                keyboardType: TextInputType.number,
                // A pasted "1,200" would otherwise silently parse as null.
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _fieldDecoration('価格', hintText: '例: 1200'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _paymentController,
                decoration: _fieldDecoration('支払い方法'),
              ),
            ),
          ],
        ),
        TextFormField(
          controller: _memoController,
          decoration: _fieldDecoration('メモ'),
          maxLines: 3,
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration(
    String label, {
    bool isRequired = false,
    String? hintText,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: isRequired ? '$label *' : label,
      // Only the required fields say anything: an 「任意」 under every other
      // field was noise repeated a dozen times down the form.
      helperText: isRequired ? '必須' : helperText,
      hintText: hintText,
    );
  }

  void _refreshRequiredStatus() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      // A record that already stores an older visit must not open a picker
      // that cannot represent it.
      firstDate: _visitedAt.isBefore(DateTime(2020))
          ? DateTime(_visitedAt.year)
          : DateTime(2020),
      // A visit cannot have happened in the future; the only exception is a
      // record that already stores one, which must stay selectable.
      lastDate: _visitedAt.isAfter(now) ? _visitedAt : now,
      initialDate: _visitedAt,
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_visitedAt),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _visitedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
    _recheckDirty();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat == null || lng == null) {
      // The validator above already says so on the fields themselves; this is
      // the last guard against ever storing a coordinate-less place.
      return;
    }
    if (!await _confirmSameDayDuplicate()) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _submitting = true);
    final floorNumber = parseFloorNumber(_floorLabelController.text);
    final entranceFloorNumber = parseFloorNumber(
      _entranceFloorLabelController.text,
    );
    final place = Place(
      id: widget.initialPlace?.id ?? 'manual-${_newLocalId()}',
      provider: widget.initialPlace?.provider ?? 'manual',
      // A bare millisecond timestamp collides when two records are saved in the
      // same millisecond (web `DateTime` has no finer resolution).
      providerPlaceId:
          widget.initialPlace?.providerPlaceId ?? 'manual-${_newLocalId()}',
      name: _nameController.text.trim(),
      lat: lat,
      lng: lng,
      address: _addressController.text.trim(),
      buildingName: _buildingController.text.trim(),
      floorLabel: _floorLabelController.text.trim(),
      floorNumber: floorNumber,
      entranceFloorLabel: _entranceFloorLabelController.text.trim(),
      entranceFloorNumber: entranceFloorNumber,
      hasElevator: _hasElevator,
      elevatorRideCount: int.tryParse(_elevatorRideCountController.text.trim()),
      category: _categoryController.text.trim(),
      rawPayload:
          widget.initialPlace?.rawPayload ?? jsonEncode({'source': 'manual'}),
    );
    // Without this guard a persistence failure would leave `_submitting` true
    // forever, freezing the sheet with no way out.
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.saveRecord(
        recordId: widget.existingRecord?.id,
        place: place,
        routeDistanceMeters: double.tryParse(
          _routeDistanceController.text.trim(),
        ),
        visitedAt: _visitedAt,
        timeLimitMinutes: int.parse(_timeLimitController.text.trim()),
        dineType: _dineType,
        menu: _menuController.text.trim(),
        price: int.tryParse(
          _priceController.text.trim().replaceAll(',', '').replaceAll('，', ''),
        ),
        paymentMethod: _paymentController.text.trim(),
        memo: _memoController.text.trim(),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text(saveFailureMessage)));
      return;
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// Asks before adding a second record for the same place on the same day.
  ///
  /// Re-entering a visit that was already saved is the easiest mistake to make
  /// here, and nothing downstream would ever flag the duplicate.
  Future<bool> _confirmSameDayDuplicate() async {
    final placeId = widget.initialPlace?.id;
    // Editing an existing record is not a new visit.
    if (placeId == null || widget.existingRecord != null) {
      return true;
    }
    if (!widget.controller.hasRecordForPlaceOn(placeId, _visitedAt)) {
      return true;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('今日はすでに記録があります'),
        content: const Text('この店舗の同じ日の記録がすでにあります。もう一件追加しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('追加する'),
          ),
        ],
      ),
    );
    return proceed == true;
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '必須です';
    }
    return null;
  }

  String? _requiredDouble(String? value) {
    if (_required(value) != null) {
      return '必須です';
    }
    if (double.tryParse(value!.trim()) == null) {
      return '数値で入力してください';
    }
    return null;
  }

  String? _requiredInt(String? value) {
    if (_required(value) != null) {
      return '必須です';
    }
    if (int.tryParse(value!.trim()) == null) {
      return '整数で入力してください';
    }
    return null;
  }
}

/// The sheet's title row.
///
/// The readiness banner that used to live here said the same thing as the one
/// above the save button, one screen apart; only the one next to the button
/// the user is reaching for survives.
class _RecordSheetHeader extends StatelessWidget {
  const _RecordSheetHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.close),
          tooltip: '閉じる',
        ),
      ],
    );
  }
}

class _RecordSheetSection extends StatelessWidget {
  const _RecordSheetSection({
    super.key,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onExpansionChanged,
    required this.children,
  });

  final String title;
  final String subtitle;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDED7CC)),
      ),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        maintainState: true,
        onExpansionChanged: onExpansionChanged,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        // Top padding, or the first field's floating label is clipped by the
        // tile's own header as it animates into place.
        childrenPadding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        title: Text(title),
        subtitle: Text(subtitle),
        children: children,
      ),
    );
  }
}

class _RecordSaveBar extends StatelessWidget {
  const _RecordSaveBar({
    required this.canSubmit,
    required this.isSubmitting,
    required this.isEditing,
    required this.missingRequiredLabels,
    required this.onSubmit,
  });

  final bool canSubmit;
  final bool isSubmitting;
  final bool isEditing;
  final List<String> missingRequiredLabels;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    // Written out rather than assembled around a colon, so it never reads as
    // a label with stray spaces around a list.
    final helperText = canSubmit
        ? '必須項目は入力済みです。'
        : '保存には${missingRequiredLabels.join('と')}が必要です。';

    // Stacked rather than side by side: at a large font scale a row would push
    // the button off-screen.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          helperText,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: canSubmit
                ? const Color(0xFF0F766E)
                : const Color(0xFFB45309),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: onSubmit,
            child: Text(
              isSubmitting
                  ? '保存中...'
                  : isEditing
                  ? '更新する'
                  : '保存する',
            ),
          ),
        ),
      ],
    );
  }
}

class _MapTab extends StatefulWidget {
  const _MapTab({required this.controller});

  final ReachTrailController controller;

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  final _mapController = MapController();
  String? _selectedPlaceId;

  @override
  void dispose() {
    // Passed into FlutterMap, so it is this State's responsibility to release.
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseLocation = widget.controller.baseLocation;
    final entries = baseLocation == null
        ? const <_SharedPlaceEntry>[]
        : _buildMapEntries(widget.controller, baseLocation.id);
    final selectedEntry = entries
        .where((entry) => entry.place.id == _selectedPlaceId)
        .firstOrNull;
    final effectiveSelectedId =
        selectedEntry?.place.id ??
        (entries.isEmpty ? null : entries.first.place.id);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: '地図',
          // The shared "nearby" view is not built yet, so nothing here promises
          // it.
          subtitle: '現在の基準地点で記録したお店をマップで振り返ります。',
          child: baseLocation == null
              ? const Text('先に「基準」タブで基準地点を設定してください。')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    _BaseLocationBanner(baseLocation: baseLocation),
                    _MyMapView(
                      mapController: _mapController,
                      baseLocation: baseLocation,
                      entries: entries,
                      selectedPlaceId: effectiveSelectedId,
                      recordCount: widget.controller.records
                          .where(
                            (record) =>
                                record.baseLocationId == baseLocation.id,
                          )
                          .length,
                      onSelectEntry: _selectEntry,
                      onEditRecord: _editRecord,
                      onDeletePlaceRecords: _deletePlaceRecords,
                    ),
                  ],
                ),
        ),
        if (baseLocation != null && entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: '店舗ランキング',
            subtitle: '訪問回数、難易度、距離をお店単位で集約します。',
            child: Column(
              spacing: 12,
              children: [
                for (var index = 0; index < entries.length; index += 1)
                  _SharedPlaceRankTile(
                    rank: index + 1,
                    entry: entries[index],
                    isSelected: effectiveSelectedId == entries[index].place.id,
                    onTap: () => _selectEntry(entries[index]),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _selectEntry(_SharedPlaceEntry entry) {
    setState(() {
      _selectedPlaceId = entry.place.id;
    });
    // The map may not be attached yet (or may have been rebuilt), in which case
    // flutter_map throws; the selection itself is already applied.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      try {
        _mapController.move(
          latlong.LatLng(entry.place.lat, entry.place.lng),
          16,
        );
      } catch (_) {
        // Nothing to recover: the list selection is the source of truth.
      }
    });
  }

  Future<void> _editRecord(DineChallengeRecord record) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // The sheet can reach the status bar; without this its header would sit
      // under the clock and the ✕ would be hard to hit.
      useSafeArea: true,
      enableDrag: false,
      builder: (context) => RecordSheet(
        controller: widget.controller,
        initialPlace: placeFromSnapshot(record.placeSnapshot),
        existingRecord: record,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('記録を更新しました。')));
    }
  }

  Future<void> _deletePlaceRecords(_SharedPlaceEntry entry) async {
    // Captured before the first await so no BuildContext crosses an async gap.
    final messenger = ScaffoldMessenger.of(context);
    final baseLocation = widget.controller.baseLocation;
    if (baseLocation == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${entry.place.name} の記録を削除しますか？'),
        content: Text('この基準地点に紐づく ${entry.visitCount} 件の記録を削除します。削除後は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final int deletedCount;
    try {
      deletedCount = await widget.controller.deleteRecordsForPlace(
        entry.place.id,
        baseLocationId: baseLocation.id,
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(deleteFailureMessage)),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      if (_selectedPlaceId == entry.place.id) {
        _selectedPlaceId = null;
      }
    });
    messenger.showSnackBar(
      SnackBar(content: Text('$deletedCount 件の記録を削除しました。')),
    );
  }
}

class _BaseLocationBanner extends StatelessWidget {
  const _BaseLocationBanner({required this.baseLocation});

  final BaseLocation baseLocation;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6F6F3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.place, color: Color(0xFF0F766E)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '基準地点: ${baseLocation.name}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyMapView extends StatelessWidget {
  const _MyMapView({
    required this.mapController,
    required this.baseLocation,
    required this.entries,
    required this.selectedPlaceId,
    required this.recordCount,
    required this.onSelectEntry,
    required this.onEditRecord,
    required this.onDeletePlaceRecords,
  });

  final MapController mapController;
  final BaseLocation baseLocation;
  final List<_SharedPlaceEntry> entries;
  final String? selectedPlaceId;
  final int recordCount;
  final ValueChanged<_SharedPlaceEntry> onSelectEntry;
  final ValueChanged<DineChallengeRecord> onEditRecord;
  final ValueChanged<_SharedPlaceEntry> onDeletePlaceRecords;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Text('この基準地点でまだお店が記録されていません。「登録」タブから追加してください。');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 16,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricChip(
              icon: Icons.storefront,
              label: '店舗',
              value: '${entries.length} 件',
            ),
            _MetricChip(
              icon: Icons.receipt_long,
              label: '記録',
              value: '$recordCount 件',
            ),
            _MetricChip(icon: Icons.radar, label: '表示', value: 'レーダー＋地図'),
          ],
        ),
        _SharedPlaceMapOverview(
          mapController: mapController,
          baseLocation: baseLocation,
          entries: entries,
          selectedPlaceId: selectedPlaceId,
          onSelectEntry: onSelectEntry,
          onEditRecord: onEditRecord,
          onDeletePlaceRecords: onDeletePlaceRecords,
        ),
      ],
    );
  }
}

class _SharedPlaceMapOverview extends StatelessWidget {
  const _SharedPlaceMapOverview({
    required this.mapController,
    required this.baseLocation,
    required this.entries,
    required this.selectedPlaceId,
    required this.onSelectEntry,
    required this.onEditRecord,
    required this.onDeletePlaceRecords,
  });

  final MapController mapController;
  final BaseLocation? baseLocation;
  final List<_SharedPlaceEntry> entries;
  final String? selectedPlaceId;
  final ValueChanged<_SharedPlaceEntry> onSelectEntry;
  final ValueChanged<DineChallengeRecord> onEditRecord;
  final ValueChanged<_SharedPlaceEntry> onDeletePlaceRecords;

  /// Ignores a tap whose place has already left [entries] instead of throwing
  /// out of `firstWhere`.
  void _selectEntryForPlace(Place place) {
    final entry = entries
        .where((item) => item.place.id == place.id)
        .firstOrNull;
    if (entry == null) {
      return;
    }
    onSelectEntry(entry);
  }

  @override
  Widget build(BuildContext context) {
    final places = entries.map((entry) => entry.place).toList();
    final selectedEntry = entries
        .where((entry) => entry.place.id == selectedPlaceId)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        if (selectedEntry != null)
          _SelectedSharedPlaceSummary(
            entry: selectedEntry,
            onEditLatestRecord: () => onEditRecord(selectedEntry.latestRecord),
            onDeleteRecords: () => onDeletePlaceRecords(selectedEntry),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final map = SizedBox(
              height: wide ? 420 : 320,
              child: _CandidateMap(
                mapController: mapController,
                baseLocation: baseLocation,
                places: places,
                selectedPlaceId: selectedPlaceId,
                onSelectPlace: (place) => _selectEntryForPlace(place),
              ),
            );
            final radar = SizedBox(
              height: wide ? 420 : 320,
              child: _CandidateRadar(
                baseLocation: baseLocation,
                places: places,
                selectedPlaceId: selectedPlaceId,
                onSelectPlace: (place) => _selectEntryForPlace(place),
              ),
            );

            if (!wide) {
              return Column(spacing: 12, children: [map, radar]);
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: map),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: radar),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SelectedSharedPlaceSummary extends StatelessWidget {
  const _SelectedSharedPlaceSummary({
    required this.entry,
    required this.onEditLatestRecord,
    required this.onDeleteRecords,
  });

  final _SharedPlaceEntry entry;
  final VoidCallback onEditLatestRecord;
  final VoidCallback onDeleteRecords;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6F6F3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                const Icon(Icons.storefront, color: Color(0xFF0F766E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.place.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onEditLatestRecord,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: '最新記録を編集',
                ),
                IconButton(
                  onPressed: onDeleteRecords,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'このお店の記録を削除',
                ),
              ],
            ),
            if (entry.place.address.isNotEmpty) Text(entry.place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(label: '${entry.visitCount} 件'),
                _Tag(
                  label: '平均 ${formatCount(entry.averageDifficulty)}',
                ),
                _Tag(
                  label: 'ベスト ${formatMeters(entry.bestRouteDistanceMeters)}',
                ),
                if (entry.place.floorLabel.isNotEmpty)
                  _Tag(label: entry.place.floorLabel),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SharedPlaceRankTile extends StatelessWidget {
  const _SharedPlaceRankTile({
    required this.rank,
    required this.entry,
    required this.isSelected,
    required this.onTap,
  });

  final int rank;
  final _SharedPlaceEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE6F6F3) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0F766E)
                : const Color(0xFFDED7CC),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                child: Text('$rank'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Text(
                      entry.place.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (entry.place.address.isNotEmpty)
                      Text(
                        entry.place.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _Tag(label: '${entry.visitCount} 件'),
                        _Tag(
                          label: '平均 ${formatCount(entry.averageDifficulty)}',
                        ),
                        _Tag(
                          label:
                              '経路 ${formatMeters(entry.bestRouteDistanceMeters)}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDED7CC)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF0F766E)),
            const SizedBox(width: 8),
            Text('$label: '),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _SharedPlaceEntry {
  const _SharedPlaceEntry({
    required this.place,
    required this.visitCount,
    required this.averageDifficulty,
    required this.bestRouteDistanceMeters,
    required this.latestVisitedAt,
    required this.latestRecord,
  });

  final Place place;
  final int visitCount;
  final double averageDifficulty;
  final double bestRouteDistanceMeters;
  final DateTime? latestVisitedAt;
  final DineChallengeRecord latestRecord;
}

List<_SharedPlaceEntry> _buildMapEntries(
  ReachTrailController controller,
  String baseLocationId,
) {
  final recordsByPlace = <String, List<DineChallengeRecord>>{};
  for (final record in controller.records) {
    if (record.baseLocationId != baseLocationId) {
      continue;
    }
    recordsByPlace.putIfAbsent(record.placeId, () => []).add(record);
  }

  final entries = <_SharedPlaceEntry>[];
  for (final entry in recordsByPlace.entries) {
    final records = entry.value;
    final latest = records.reduce(
      (a, b) => a.visitedAt.isAfter(b.visitedAt) ? a : b,
    );
    final place = Place.tryFromJson(latest.placeSnapshot);
    if (place == null) {
      // Without coordinates the entry cannot be drawn on the map or radar.
      continue;
    }
    final averageDifficulty =
        records.fold<double>(0, (sum, record) => sum + record.difficultyScore) /
        records.length;
    final bestRouteDistance = records
        .map((record) => record.routeDistanceMeters)
        .reduce(math.min);

    entries.add(
      _SharedPlaceEntry(
        place: place,
        visitCount: records.length,
        averageDifficulty: averageDifficulty,
        bestRouteDistanceMeters: bestRouteDistance,
        latestVisitedAt: latest.visitedAt,
        latestRecord: latest,
      ),
    );
  }

  entries.sort((a, b) {
    final countCompare = b.visitCount.compareTo(a.visitCount);
    if (countCompare != 0) {
      return countCompare;
    }
    final difficultyCompare = b.averageDifficulty.compareTo(
      a.averageDifficulty,
    );
    if (difficultyCompare != 0) {
      return difficultyCompare;
    }
    final aLatest = a.latestVisitedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bLatest = b.latestVisitedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bLatest.compareTo(aLatest);
  });

  return entries;
}

class _RecordsTab extends StatelessWidget {
  const _RecordsTab({required this.controller});

  final ReachTrailController controller;

  @override
  Widget build(BuildContext context) {
    // With nothing recorded yet the Best cards, the sort chips and the score
    // maintenance row are three pieces of furniture around an empty room; one
    // sentence says more.
    if (controller.records.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _SectionCard(
            title: '記録',
            subtitle: '外食チャレンジの記録がここに並びます。',
            child: Text('まだ記録がありません。「登録」タブからお店を記録すると、ここにベスト記録と履歴が表示されます。'),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: 'ベスト記録',
          subtitle: '直線距離、最短距離、縦移動を分けて、移動の重さを見返せます。',
          child: Column(
            spacing: 12,
            children: [
              _BestRecordTile(
                label: '最長経路',
                record: controller.bestDistanceRecord,
                metricBuilder: (record) =>
                    formatMeters(record.routeDistanceMeters),
              ),
              _BestRecordTile(
                label: '最高難度',
                record: controller.bestDifficultyRecord,
                metricBuilder: (record) => formatCount(record.difficultyScore),
              ),
              _BestPlaceTile(
                label: '最多訪問',
                entry: controller.mostVisitedPlace,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '履歴',
          subtitle: '直線距離、最短距離、縦移動を分けて残し、後から評価を見直せます。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              // The score version and its recalculation button are maintenance
              // plumbing, not something a user can act on; they stay behind a
              // debug build. `recalculateScores` is still called on a base move.
              if (kDebugMode) _ScoreMaintenanceRow(controller: controller),
              Wrap(
                spacing: 8,
                children: RecordSort.values.map((sort) {
                  final label = switch (sort) {
                    RecordSort.latest => '最新順',
                    RecordSort.distance => '最短距離順',
                    RecordSort.difficulty => '難易度順',
                  };
                  return ChoiceChip(
                    label: Text(label),
                    selected: controller.recordSort == sort,
                    onSelected: (_) => controller.updateSort(sort),
                  );
                }).toList(),
              ),
              ...controller.sortedRecords.map(
                  (record) => _RecordTile(
                    record: record,
                    onEdit: () async {
                      final saved = await showModalBottomSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        // The sheet can reach the status bar; without this its
                        // header would sit under the clock and the ✕ would be
                        // hard to hit.
                        useSafeArea: true,
                        enableDrag: false,
                        builder: (context) => RecordSheet(
                          controller: controller,
                          initialPlace: placeFromSnapshot(record.placeSnapshot),
                          existingRecord: record,
                        ),
                      );
                      if (saved == true && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('記録を更新しました。')),
                        );
                      }
                    },
                    onDelete: () => _deleteRecord(context, record),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _deleteRecord(
    BuildContext context,
    DineChallengeRecord record,
  ) async {
    final place = placeFromSnapshot(record.placeSnapshot);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${place.name} の記録を削除しますか？'),
        content: const Text('この記録を削除します。削除後は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.deleteRecord(record.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(deleteFailureMessage)),
      );
      return;
    }
    // The deleted record is held here for as long as the notice is on screen,
    // so a mistake costs a tap rather than the whole entry.
    messenger.showSnackBar(
      SnackBar(
        content: const Text('記録を削除しました。'),
        action: SnackBarAction(
          label: '元に戻す',
          onPressed: () => unawaited(controller.restoreRecord(record)),
        ),
      ),
    );
  }
}

/// Score-version maintenance, shown only in a debug build.
class _ScoreMaintenanceRow extends StatelessWidget {
  const _ScoreMaintenanceRow({required this.controller});

  final ReachTrailController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '現行スコアバージョン: v$currentScoreVersion / 未更新: ${controller.outdatedScoreCount}件',
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: controller.records.isEmpty
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final int count;
                  try {
                    count = await controller.recalculateScores();
                  } catch (_) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text(saveFailureMessage)),
                    );
                    return;
                  }
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        count == 0
                            ? '再計算の差分はありませんでした。'
                            : '$count 件のスコアを再計算しました。',
                      ),
                    ),
                  );
                },
          icon: const Icon(Icons.refresh),
          label: const Text('再計算'),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  final DineChallengeRecord record;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final place = placeFromSnapshot(record.placeSnapshot);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDED7CC)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            RecordCardHeader(
              placeName: place.name,
              visitedAt: record.visitedAt,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
            Text(place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(label: '経路 ${formatMeters(record.routeDistanceMeters)}'),
                _Tag(
                  label:
                      '直線 ${formatMeters(record.straightLineDistanceMeters)}',
                ),
                _Tag(
                  label:
                      '高低差 ${record.baseVerticalFloors + record.placeVerticalFloors}F',
                ),
                _Tag(label: 'スコア ${formatCount(record.difficultyScore)}'),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                if (place.entranceFloorLabel.isNotEmpty)
                  _Tag(label: '入口 ${place.entranceFloorLabel}'),
                _Tag(label: place.hasElevator ? 'EVあり' : '階段中心'),
                if (place.hasElevator && place.elevatorRideCount != null)
                  _Tag(label: 'EV ${place.elevatorRideCount}回'),
                _Tag(
                  label: record.dineType == DineType.dineIn ? '店内飲食' : 'テイクアウト',
                ),
                _Tag(label: '${record.timeLimitMinutes}分'),
              ],
            ),
            Text(
              '拠点縦移動 ${record.baseVerticalFloors}F / 店舗縦移動 ${record.placeVerticalFloors}F',
            ),
            if (record.menu.isNotEmpty) Text('メニュー ${record.menu}'),
            if (record.price != null) Text('価格 ¥${formatCount(record.price!)}'),
            if (record.paymentMethod.isNotEmpty)
              Text('支払い ${record.paymentMethod}'),
            if (record.memo.isNotEmpty) Text(record.memo),
          ],
        ),
      ),
    );
  }
}

/// Header row of a record card: store name, visit date and the edit/delete
/// actions.
///
/// Public so a widget test can pump it at a large text scale; two icon buttons
/// plus a date used to overflow the row once the system font was enlarged, so
/// the actions live in a single overflow menu and the date may ellipsise.
class RecordCardHeader extends StatelessWidget {
  const RecordCardHeader({
    super.key,
    required this.placeName,
    required this.visitedAt,
    required this.onEdit,
    required this.onDelete,
  });

  final String placeName;
  final DateTime visitedAt;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  /// The visit date and time.
  ///
  /// Two visits to the same shop on one day are otherwise indistinguishable in
  /// the list, which is exactly when the user is trying to tell them apart.
  static String formatVisitedDate(DateTime visitedAt) {
    final month = visitedAt.month.toString().padLeft(2, '0');
    final day = visitedAt.day.toString().padLeft(2, '0');
    final hour = visitedAt.hour.toString().padLeft(2, '0');
    final minute = visitedAt.minute.toString().padLeft(2, '0');
    return '${visitedAt.year}/$month/$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Name over date rather than side by side: sharing one row, the two
        // fought for the same width and both truncated as soon as the system
        // font grew — and the timestamp is the half that cannot be guessed.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                placeName,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                formatVisitedDate(visitedAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          tooltip: 'この記録の操作',
          onSelected: (value) {
            if (value == 'edit') {
              onEdit();
            } else if (value == 'delete') {
              onDelete();
            }
          },
          itemBuilder: (context) {
            final errorColor = Theme.of(context).colorScheme.error;
            return [
              const PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('編集'),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline, color: errorColor),
                  title: Text('削除', style: TextStyle(color: errorColor)),
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}

class _BestRecordTile extends StatelessWidget {
  const _BestRecordTile({
    required this.label,
    required this.record,
    required this.metricBuilder,
  });

  final String label;
  final DineChallengeRecord? record;
  final String Function(DineChallengeRecord record) metricBuilder;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6F6F3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.workspace_premium),
            const SizedBox(width: 12),
            Expanded(
              // Label above, shop name below: joined on one line with a colon
              // they competed for the same row and both truncated as soon as
              // the system font grew.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                  Text(
                    record == null
                        ? 'まだ記録なし'
                        : placeFromSnapshot(record!.placeSnapshot).name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            if (record != null)
              Flexible(
                child: Text(
                  metricBuilder(record!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BestPlaceTile extends StatelessWidget {
  const _BestPlaceTile({required this.label, required this.entry});

  final String label;
  final ({String placeName, int count})? entry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6F6F3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.workspace_premium),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                  Text(
                    entry == null ? 'まだ記録なし' : entry!.placeName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            if (entry != null)
              Flexible(
                child: Text(
                  '${entry!.count} 回',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF4EFE6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            blurRadius: 24,
            offset: Offset(0, 14),
            color: Color(0x14000000),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            Text(subtitle),
            child,
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEBF5F4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label),
      ),
    );
  }
}
