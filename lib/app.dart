import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show Listenable, kIsWeb;
import 'package:flutter/material.dart';
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

class ReachTrailApp extends StatefulWidget {
  const ReachTrailApp({super.key});

  @override
  State<ReachTrailApp> createState() => _ReachTrailAppState();
}

class _ReachTrailAppState extends State<ReachTrailApp> {
  late final ReachTrailController _controller;
  late final GoogleAuthService _authService;

  @override
  void initState() {
    super.initState();
    final configService = LocalConfigService();
    _controller = ReachTrailController(
      persistence: PersistenceService(),
      configService: configService,
    )..load();
    _authService = GoogleAuthService(configService: configService)
      ..initialize();
  }

  @override
  void dispose() {
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
          home: _authService.isInitializing
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

class ReachTrailController extends ChangeNotifier {
  ReachTrailController({
    required PersistenceService persistence,
    required LocalConfigService configService,
  }) : _persistence = persistence,
       _configService = configService;

  final PersistenceService _persistence;
  final LocalConfigService _configService;
  PlaceSearchService? _searchService;

  bool isBootstrapping = true;
  bool isSearching = false;
  bool isBaseSearching = false;
  bool isBuildingSearching = false;
  String? errorMessage;
  String? baseSearchError;
  String? buildingSearchError;
  String placeSearchProvider = 'mock';
  String yahooApiKey = '';
  BaseLocation? baseLocation;
  List<Place> places = const [];
  List<DineChallengeRecord> records = const [];
  List<Place> searchResults = const [];
  List<Place> baseSearchResults = const [];
  List<Place> buildingSearchResults = const [];
  RecordSort recordSort = RecordSort.latest;

  Future<void> load() async {
    isBootstrapping = true;
    notifyListeners();
    final config = await _configService.load();
    _applyConfig(config);
    baseLocation = await _persistence.loadBaseLocation();
    places = await _persistence.loadPlaces();
    records = await _persistence.loadRecords();
    isBootstrapping = false;
    notifyListeners();
  }

  Future<void> reloadConfig() async {
    final config = await _configService.load();
    _applyConfig(config);
    notifyListeners();
  }

  void _applyConfig(LocalConfig config) {
    placeSearchProvider = config.placeSearchProvider;
    yahooApiKey = config.yahooApiKey;
    _searchService = CompositePlaceSearchService(
      SearchConfig(
        provider: placeSearchProvider,
        yahooApiKey: yahooApiKey,
        yahooProxyBaseUrl: config.yahooProxyBaseUrl.isNotEmpty
            ? config.yahooProxyBaseUrl
            : (kIsWeb ? 'http://localhost:3000' : ''),
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
      id: baseLocation?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
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
      searchResults = await _searchService!.search(
        query: query,
        baseLocation: baseLocation,
        nearbyOnly: nearbyOnly,
      );
      if (searchResults.isEmpty) {
        errorMessage = '候補が見つかりません。手入力で登録できます。';
      }
    } catch (error) {
      errorMessage = '検索に失敗しました: $error';
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
      buildingSearchResults = await _searchService!.search(
        query: query,
        baseLocation: null,
        nearbyOnly: false,
        purpose: SearchPurpose.baseLocation,
      );
      if (buildingSearchResults.isEmpty) {
        buildingSearchError = '建物候補が見つかりません。建物名や住所の一部で試してください。';
      }
    } catch (error) {
      buildingSearchError = '建物候補検索に失敗しました: $error';
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
      baseSearchResults = await _searchService!.search(
        query: query,
        baseLocation: null,
        nearbyOnly: false,
        purpose: SearchPurpose.baseLocation,
      );
      if (baseSearchResults.isEmpty) {
        baseSearchError = '基準地点候補が見つかりません。別の建物名や住所で試してください。';
      }
    } catch (error) {
      baseSearchError = '基準地点検索に失敗しました: $error';
      baseSearchResults = const [];
    } finally {
      isBaseSearching = false;
      notifyListeners();
    }
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
      id: recordId ?? DateTime.now().microsecondsSinceEpoch.toString(),
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
    final place = Place.fromJson(record.placeSnapshot);
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
      names[record.placeId] ??= Place.fromJson(record.placeSnapshot).name;
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

class _ReachTrailHomeState extends State<ReachTrailHome> {
  int _index = 0;

  static const _desktopBreakpoint = 1080.0;
  static const _contentMaxWidth = 1280.0;

  Widget _buildCurrentTab(ReachTrailController controller) {
    return IndexedStack(
      index: _index,
      children: [
        _BaseLocationTab(controller: controller),
        _RegisterTab(controller: controller),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= _desktopBreakpoint;
        final content = _buildCurrentTab(controller);

        return Scaffold(
          appBar: AppBar(
            title: const Text('ReachTrail'),
            actions: [
              if (widget.authService.currentUser case final user?)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    child: Text(
                      user.displayName?.isNotEmpty == true
                          ? user.displayName!
                          : user.email,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: Text(
                    controller.placeSearchProvider == 'mock' ||
                            controller.yahooApiKey.isEmpty
                        ? 'Mock Search'
                        : 'Yahoo',
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: widget.authService.signOut,
                icon: const Icon(Icons.logout),
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
                            label: Text('Base'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.add_location_alt_outlined),
                            selectedIcon: Icon(Icons.add_location_alt),
                            label: Text('Register'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.map_outlined),
                            selectedIcon: Icon(Icons.map),
                            label: Text('Map'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.emoji_events_outlined),
                            selectedIcon: Icon(Icons.emoji_events),
                            label: Text('Records'),
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
                      label: 'Base',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.add_location_alt_outlined),
                      selectedIcon: Icon(Icons.add_location_alt),
                      label: 'Register',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.map_outlined),
                      selectedIcon: Icon(Icons.map),
                      label: 'Map',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.emoji_events_outlined),
                      selectedIcon: Icon(Icons.emoji_events),
                      label: 'Records',
                    ),
                  ],
                ),
        );
      },
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
  Place? _selectedCandidate;
  double? _selectedLat;
  double? _selectedLng;
  bool _hasElevator = true;

  @override
  void initState() {
    super.initState();
    final base = widget.controller.baseLocation;
    _searchController = TextEditingController();
    _nameController = TextEditingController(text: base?.name ?? 'Office');
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
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: 'Base Location',
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
                      onPressed: _useTypedAddressAsBase,
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: const Text('住所を手入力で使う'),
                    ),
                  ],
                ),
                if (controller.baseSearchError != null)
                  Text(
                    controller.baseSearchError!,
                    style: const TextStyle(color: Colors.redAccent),
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
                    child: Text(
                      '選択座標: ${_selectedLat!.toStringAsFixed(6)}, ${_selectedLng!.toStringAsFixed(6)}',
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (base != null)
                        OutlinedButton.icon(
                          onPressed: _deleteBaseLocation,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('基準地点と関連登録地を削除'),
                        ),
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
                          await controller.saveBaseLocation(
                            name: _nameController.text.trim(),
                            lat: _selectedLat!,
                            lng: _selectedLng!,
                            floorLabel: _floorController.text.trim(),
                            floorNumber: parseFloorNumber(
                              _floorController.text.trim(),
                            ),
                            entryFloorLabel: _entryFloorController.text.trim(),
                            entryFloorNumber: parseFloorNumber(
                              _entryFloorController.text.trim(),
                            ),
                            hasElevator: _hasElevator,
                            elevatorRideCount: int.tryParse(
                              _elevatorRideCountController.text.trim(),
                            ),
                            memo: _mergedBaseMemo,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('基準地点を保存しました。')),
                          );
                        },
                        child: Text(base == null ? '保存' : '修正を保存'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Current Base',
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

  Future<void> _runBaseSearch() async {
    if (_searchController.text.trim().isEmpty) {
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

  void _useTypedAddressAsBase() {
    final query = _searchController.text.trim();
    setState(() {
      if (_nameController.text.trim().isEmpty ||
          _nameController.text == 'Office') {
        _nameController.text = query.isEmpty ? 'Base' : query;
      }
      if (_addressController.text.trim().isEmpty) {
        _addressController.text = query;
      }
    });
  }

  void _selectBasePoint(latlong.LatLng point) {
    setState(() {
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
          FilledButton.tonalIcon(
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
    final deletedCount = await widget.controller.deleteBaseLocation();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCandidate = null;
      _selectedLat = null;
      _selectedLng = null;
      _nameController.text = 'Office';
      _addressController.clear();
      _floorController.clear();
      _entryFloorController.clear();
      _elevatorRideCountController.clear();
      _memoController.clear();
      _hasElevator = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
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
                  if (place.category.isNotEmpty) _Tag(label: place.category),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BaseLocationPickerMap extends StatelessWidget {
  const _BaseLocationPickerMap({
    required this.lat,
    required this.lng,
    required this.onSelected,
  });

  final double? lat;
  final double? lng;
  final ValueChanged<latlong.LatLng> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedPoint = lat == null || lng == null
        ? null
        : latlong.LatLng(lat!, lng!);
    final center = selectedPoint ?? const latlong.LatLng(35.681236, 139.767125);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text('地図で基準地点を選択', style: Theme.of(context).textTheme.titleSmall),
        const Text('住所候補がうまく出ない場合は、地図をタップして緯度経度を設定できます。'),
        SizedBox(
          height: 260,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: _MapReloadable(
              builder: (context) => FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: selectedPoint == null ? 12 : 16,
                  onTap: (_, point) => onSelected(point),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'reachtrail_app',
                  ),
                  if (selectedPoint != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: selectedPoint,
                          width: 120,
                          height: 56,
                          child: const _MapMarker(
                            label: 'Base',
                            color: Color(0xFF1D4ED8),
                            isSelected: true,
                          ),
                        ),
                      ],
                    ),
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
  const _RegisterTab({required this.controller});

  final ReachTrailController controller;

  @override
  State<_RegisterTab> createState() => _RegisterTabState();
}

class _RegisterTabState extends State<_RegisterTab> {
  final _searchController = TextEditingController();
  final _buildingSearchController = TextEditingController();
  final _mapController = MapController();
  bool _nearbyOnly = true;
  bool _showDebugInfo = false;
  String? _selectedPlaceId;
  String? _lastSearchQuery;

  @override
  void dispose() {
    _searchController.dispose();
    _buildingSearchController.dispose();
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
          title: 'Place Search',
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
                      onPressed: controller.isSearching ? null : _runSearch,
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
              if (base == null)
                const Text(
                  '先に基準地点を登録してください。',
                  style: TextStyle(color: Colors.redAccent),
                ),
              if (controller.errorMessage != null)
                Text(
                  controller.errorMessage!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Candidates',
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
                  children: controller.searchResults
                      .map(
                        (place) => _PlaceResultTile(
                          place: place,
                          baseLocation: controller.baseLocation,
                          showDebugInfo: _showDebugInfo,
                          isSelected: _selectedPlaceId == place.id,
                          onSelect: () => _selectPlace(place),
                          onUse: () => _openRecordSheet(context, place: place),
                        ),
                      )
                      .toList(),
                ),
        ),
        if (controller.searchResults.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Radar',
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
            title: 'Candidate Map',
            subtitle: 'Google有料サービスは利用しておらず、OpenStreetMapで基準地点と候補位置を見比べられます。',
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

  Future<void> _runSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return;
    }
    setState(() {
      _lastSearchQuery = query;
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
    if (query.isEmpty) {
      return;
    }
    await widget.controller.searchBuildingCandidates(query);
  }

  Future<void> _openRecordSheet(BuildContext context, {Place? place}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _RecordSheet(controller: widget.controller, initialPlace: place),
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
    if (moveMap) {
      final base = widget.controller.baseLocation;
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
    }
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

class _PlaceResultTile extends StatelessWidget {
  const _PlaceResultTile({
    required this.place,
    required this.baseLocation,
    required this.showDebugInfo,
    required this.isSelected,
    required this.onSelect,
    required this.onUse,
  });

  final Place place;
  final BaseLocation? baseLocation;
  final bool showDebugInfo;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onUse;

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
                  _Tag(label: place.provider.toUpperCase()),
                  if (place.buildingName.isNotEmpty)
                    _Tag(label: place.buildingName),
                  if (place.floorLabel.isNotEmpty)
                    _Tag(label: place.floorLabel),
                  if (place.category.isNotEmpty) _Tag(label: place.category),
                  if (distance != null)
                    _Tag(label: '${distance.round()}m from base'),
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
                        label: const Text('Debug'),
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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
            style: const TextStyle(color: Colors.redAccent),
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
                const _Tag(label: 'BUILDING'),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                if (place.category.isNotEmpty) _Tag(label: place.category),
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

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const RadialGradient(
          center: Alignment.center,
          radius: 1.1,
          colors: [Color(0xFF103E35), Color(0xFF071C18)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.radar, color: Color(0xFF89F0D0)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedPlace == null
                        ? '候補をタップして追跡'
                        : 'Tracking ${selectedPlace.name}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '5 km radius',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: Color(0xFF9CCABD)),
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
                              child: GestureDetector(
                                onTap: () => onSelectPlace(node.place),
                                child: _RadarBlip(
                                  place: node.place,
                                  distanceMeters: node.distanceMeters,
                                  isSelected: selectedPlaceId == node.place.id,
                                  showLabel:
                                      selectedPlaceId == node.place.id ||
                                      node.isPrimaryInCluster,
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
                                    color: const Color(0xFFB4FFF0),
                                    shape: BoxShape.circle,
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 20,
                                        color: Color(0x8835F7D0),
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
                _RadarLegend(label: 'Base', color: const Color(0xFFB4FFF0)),
                _RadarLegend(
                  label: 'Candidate',
                  color: const Color(0xFF4ADE80),
                ),
                _RadarLegend(label: 'Selected', color: const Color(0xFFF97316)),
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
      ..color = const Color(0xFF53B89E).withValues(alpha: 0.35);
    final crossPaint = Paint()
      ..strokeWidth = 1
      ..color = const Color(0xFF53B89E).withValues(alpha: 0.25);
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          const Color(0x5535F7D0),
          const Color(0x1035F7D0),
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
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: isSelected ? 18 : 12,
          height: isSelected ? 18 : 12,
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFFF97316)
                : const Color(0xFF4ADE80),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                blurRadius: isSelected ? 20 : 12,
                color:
                    (isSelected
                            ? const Color(0xFFF97316)
                            : const Color(0xFF4ADE80))
                        .withValues(alpha: 0.65),
              ),
            ],
          ),
        ),
        if (showLabel) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 80),
            child: Text(
              '${place.name}\n${distanceMeters.round()}m',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
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
          ).textTheme.labelSmall?.copyWith(color: Colors.white70),
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

  @override
  Widget build(BuildContext context) {
    final centerPlace = places.firstWhere(
      (place) => place.id == selectedPlaceId,
      orElse: () => places.first,
    );
    final selectedPlace = places
        .where((place) => place.id == selectedPlaceId)
        .firstOrNull;
    final center = latlong.LatLng(
      baseLocation?.lat ?? centerPlace.lat,
      baseLocation?.lng ?? centerPlace.lng,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: _MapReloadable(
        builder: (context) => FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15.5,
            onTap: (_, point) {},
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'reachtrail_app',
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
                      label: 'Base',
                      color: Color(0xFF1D4ED8),
                      isSelected: false,
                    ),
                  ),
                ...places.map(
                  (place) => Marker(
                    point: latlong.LatLng(place.lat, place.lng),
                    width: 140,
                    height: 64,
                    child: GestureDetector(
                      onTap: () => onSelectPlace(place),
                      child: _MapMarker(
                        label: place.name,
                        color: const Color(0xFF0D9488),
                        isSelected: selectedPlaceId == place.id,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MapReloadable extends StatefulWidget {
  const _MapReloadable({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_MapReloadable> createState() => _MapReloadableState();
}

class _MapReloadableState extends State<_MapReloadable> {
  int _generation = 0;

  void _reload() => setState(() => _generation += 1);

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
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Tooltip(
                  message: '地図をリロード',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'リロード',
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

class _RecordSheet extends StatefulWidget {
  const _RecordSheet({
    required this.controller,
    this.initialPlace,
    this.existingRecord,
  });

  final ReachTrailController controller;
  final Place? initialPlace;
  final DineChallengeRecord? existingRecord;

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
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
  bool _hasElevator = true;
  late bool _showPlaceDetails;
  late bool _showVisitDetails;

  @override
  void initState() {
    super.initState();
    final place = widget.initialPlace;
    _nameController = TextEditingController(text: place?.name ?? '');
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
    _latController = TextEditingController(text: place?.lat.toString() ?? '');
    _lngController = TextEditingController(text: place?.lng.toString() ?? '');
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
  }

  @override
  void dispose() {
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
    return Padding(
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
                missingRequiredLabels: missingRequiredLabels,
              ),
              TextFormField(
                controller: _nameController,
                decoration: _fieldDecoration('店舗名', isRequired: true),
                validator: _required,
              ),
              _RecordSheetSection(
                title: 'お店の詳細',
                subtitle: _showPlaceDetails
                    ? '位置、階数、移動負荷を確認できます。'
                    : '候補の位置情報は入力済みです。必要な時だけ開いて修正できます。',
                expanded: _showPlaceDetails,
                onExpansionChanged: (value) =>
                    setState(() => _showPlaceDetails = value),
                children: [_buildPlaceDetailsFields()],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: DineType.values.map((type) {
                  return ChoiceChip(
                    label: Text(type == DineType.dineIn ? '店内飲食' : 'テイクアウト'),
                    selected: _dineType == type,
                    onSelected: (_) => setState(() => _dineType = type),
                  );
                }).toList(),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _timeLimitController,
                      keyboardType: TextInputType.number,
                      decoration: _fieldDecoration('制限時間(分)', isRequired: true),
                      validator: _requiredInt,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDateTime,
                      icon: const Icon(Icons.event),
                      label: Text(
                        '${_visitedAt.year}/${_visitedAt.month}/${_visitedAt.day} ${_visitedAt.hour.toString().padLeft(2, '0')}:${_visitedAt.minute.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                ],
              ),
              _RecordSheetSection(
                title: '食事メモ',
                subtitle: 'メニュー、価格、支払い方法、メモは後からでも追記できます。',
                expanded: _showVisitDetails,
                onExpansionChanged: (value) =>
                    setState(() => _showVisitDetails = value),
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
    );
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
                decoration: _fieldDecoration('最短距離(m)'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InputDecorator(
                decoration: _fieldDecoration('直線距離(m)'),
                child: Text(
                  _estimatedStraightLineDistanceMeters == null
                      ? '-'
                      : _estimatedStraightLineDistanceMeters!.toStringAsFixed(
                          0,
                        ),
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
          onChanged: (value) => setState(() => _hasElevator = value),
        ),
        if (_hasElevator)
          TextFormField(
            controller: _elevatorRideCountController,
            keyboardType: TextInputType.number,
            decoration: _fieldDecoration('エレベータ乗車回数', hintText: '例: 1, 2'),
          ),
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
    );
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
                decoration: _fieldDecoration('価格'),
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
  }) {
    return InputDecoration(
      labelText: isRequired ? '$label *' : label,
      helperText: isRequired ? '必須' : '任意',
      hintText: hintText,
    );
  }

  void _refreshRequiredStatus() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: _visitedAt,
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_visitedAt),
    );
    if (time == null) {
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
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _submitting = true);
    final floorNumber = parseFloorNumber(_floorLabelController.text);
    final entranceFloorNumber = parseFloorNumber(
      _entranceFloorLabelController.text,
    );
    final place = Place(
      id:
          widget.initialPlace?.id ??
          'manual-${DateTime.now().microsecondsSinceEpoch}',
      provider: widget.initialPlace?.provider ?? 'manual',
      providerPlaceId:
          widget.initialPlace?.providerPlaceId ??
          'manual-${DateTime.now().millisecondsSinceEpoch}',
      name: _nameController.text.trim(),
      lat: double.parse(_latController.text.trim()),
      lng: double.parse(_lngController.text.trim()),
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
      price: int.tryParse(_priceController.text.trim()),
      paymentMethod: _paymentController.text.trim(),
      memo: _memoController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
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

class _RecordSheetHeader extends StatelessWidget {
  const _RecordSheetHeader({
    required this.title,
    required this.missingRequiredLabels,
  });

  final String title;
  final List<String> missingRequiredLabels;

  @override
  Widget build(BuildContext context) {
    final ready = missingRequiredLabels.isEmpty;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        DecoratedBox(
          decoration: BoxDecoration(
            color: ready ? const Color(0xFFE6F6F3) : const Color(0xFFFFF7ED),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: ready ? const Color(0xFF99D8CD) : const Color(0xFFF7C58A),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  ready ? Icons.check_circle_outline : Icons.info_outline,
                  color: ready
                      ? const Color(0xFF0F766E)
                      : const Color(0xFFB45309),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ready
                        ? '保存に必要な項目は入力済みです。任意項目は後から追記できます。'
                        : '保存には ${missingRequiredLabels.join('・')} が必要です。',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordSheetSection extends StatelessWidget {
  const _RecordSheetSection({
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
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
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
    final helperText = canSubmit
        ? '必須項目は入力済みです。'
        : '未入力: ${missingRequiredLabels.join('・')}';

    return Row(
      children: [
        Expanded(
          child: Text(
            helperText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: canSubmit
                  ? const Color(0xFF0F766E)
                  : const Color(0xFFB45309),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: onSubmit,
          child: Text(
            isSubmitting
                ? '保存中...'
                : isEditing
                ? '更新する'
                : '保存する',
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
  _MapMode _mode = _MapMode.myMap;
  String? _selectedPlaceId;

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
          title: 'Map',
          subtitle: _mode == _MapMode.myMap
              ? '現在の基準値で記録したお店をマップで振り返ります。'
              : '基準値から徒歩15分圏内に登録したユーザーのお店をまとめて表示します。',
          child: baseLocation == null
              ? const Text('先に「Base」タブで基準値を設定してください。')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    _BaseLocationBanner(baseLocation: baseLocation),
                    _MapModeSelector(
                      mode: _mode,
                      onChanged: (mode) {
                        setState(() => _mode = mode);
                      },
                    ),
                    IndexedStack(
                      index: _mode.index,
                      children: [
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
                        const _NearbySharedView(),
                      ],
                    ),
                  ],
                ),
        ),
        if (baseLocation != null &&
            _mode == _MapMode.myMap &&
            entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Place Ranking',
            subtitle: '訪問回数、難易度、距離をお店単位で集約します。共有データ接続後もこの並びをベースにできます。',
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
    _mapController.move(latlong.LatLng(entry.place.lat, entry.place.lng), 16);
  }

  Future<void> _editRecord(DineChallengeRecord record) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _RecordSheet(
        controller: widget.controller,
        initialPlace: Place.fromJson(record.placeSnapshot),
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
          FilledButton.tonalIcon(
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
    final deletedCount = await widget.controller.deleteRecordsForPlace(
      entry.place.id,
      baseLocationId: baseLocation.id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (_selectedPlaceId == entry.place.id) {
        _selectedPlaceId = null;
      }
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$deletedCount 件の記録を削除しました。')));
  }
}

enum _MapMode { myMap, nearby }

class _MapModeSelector extends StatelessWidget {
  const _MapModeSelector({required this.mode, required this.onChanged});

  final _MapMode mode;
  final ValueChanged<_MapMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        final tabs = [
          _MapModeTab(
            mode: _MapMode.myMap,
            selectedMode: mode,
            icon: Icons.map,
            label: 'マイマップ',
            description: '自分の記録',
            onChanged: onChanged,
          ),
          _MapModeTab(
            mode: _MapMode.nearby,
            selectedMode: mode,
            icon: Icons.groups,
            label: '近くの共有',
            description: '準備中',
            onChanged: onChanged,
          ),
        ];

        if (compact) {
          return Column(spacing: 10, children: tabs);
        }

        return Row(
          children: [
            Expanded(child: tabs[0]),
            const SizedBox(width: 12),
            Expanded(child: tabs[1]),
          ],
        );
      },
    );
  }
}

class _MapModeTab extends StatelessWidget {
  const _MapModeTab({
    required this.mode,
    required this.selectedMode,
    required this.icon,
    required this.label,
    required this.description,
    required this.onChanged,
  });

  final _MapMode mode;
  final _MapMode selectedMode;
  final IconData icon;
  final String label;
  final String description;
  final ValueChanged<_MapMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = mode == selectedMode;
    final theme = Theme.of(context);
    final color = selected ? const Color(0xFF0F766E) : const Color(0xFF475569);

    return InkWell(
      onTap: () => onChanged(mode),
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE6F6F3) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? const Color(0xFF0F766E) : const Color(0xFFDED7CC),
            width: selected ? 1.8 : 1,
          ),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: const Color(0xFF0F766E).withValues(alpha: 0.16),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
          ],
        ),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF0F766E)
                    : const Color(0xFFF8F4EA),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  selected ? Icons.check_circle : icon,
                  color: selected ? Colors.white : color,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: selected
                          ? const Color(0xFF0F766E)
                          : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
                '基準値: ${baseLocation.name}',
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
      return const Text('この基準値でまだお店が記録されていません。「Register」タブから追加してください。');
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
              label: 'Places',
              value: '${entries.length}',
            ),
            _MetricChip(
              icon: Icons.receipt_long,
              label: 'Records',
              value: '$recordCount',
            ),
            _MetricChip(icon: Icons.radar, label: 'View', value: 'Radar + Map'),
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

class _NearbySharedView extends StatelessWidget {
  const _NearbySharedView();

  @override
  Widget build(BuildContext context) {
    return const Text('近くの共有は準備中です。同じエリアで働く人のお店情報を、基準値から15分圏内でまとめて表示します。');
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
                onSelectPlace: (place) => onSelectEntry(
                  entries.firstWhere((entry) => entry.place.id == place.id),
                ),
              ),
            );
            final radar = SizedBox(
              height: wide ? 420 : 320,
              child: _CandidateRadar(
                baseLocation: baseLocation,
                places: places,
                selectedPlaceId: selectedPlaceId,
                onSelectPlace: (place) => onSelectEntry(
                  entries.firstWhere((entry) => entry.place.id == place.id),
                ),
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
                _Tag(label: '${entry.visitCount} records'),
                _Tag(
                  label: 'avg ${entry.averageDifficulty.toStringAsFixed(0)}',
                ),
                _Tag(label: 'best ${entry.bestRouteDistanceMeters.round()}m'),
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
                        _Tag(label: '${entry.visitCount} records'),
                        _Tag(
                          label:
                              'avg ${entry.averageDifficulty.toStringAsFixed(0)}',
                        ),
                        _Tag(
                          label:
                              'route ${entry.bestRouteDistanceMeters.round()}m',
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
    final place = Place.fromJson(latest.placeSnapshot);
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
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: 'Best',
          subtitle: '直線距離、最短距離、縦移動を分けて、移動の重さを見返せます。',
          child: Column(
            spacing: 12,
            children: [
              _BestRecordTile(
                label: 'Longest route',
                record: controller.bestDistanceRecord,
                metricBuilder: (record) =>
                    '${record.routeDistanceMeters.round()}m',
              ),
              _BestRecordTile(
                label: 'Highest difficulty',
                record: controller.bestDifficultyRecord,
                metricBuilder: (record) =>
                    record.difficultyScore.toStringAsFixed(0),
              ),
              _BestPlaceTile(
                label: 'Most visited',
                entry: controller.mostVisitedPlace,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'History',
          subtitle: '直線距離、最短距離、縦移動を分けて残し、後から評価を見直せます。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Row(
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
                            final count = await controller.recalculateScores();
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
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
              ),
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
              if (controller.records.isEmpty)
                const Text('まだ記録がありません。')
              else
                ...controller.sortedRecords.map(
                  (record) => _RecordTile(
                    record: record,
                    onEdit: () async {
                      final saved = await showModalBottomSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        builder: (context) => _RecordSheet(
                          controller: controller,
                          initialPlace: Place.fromJson(record.placeSnapshot),
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
    final place = Place.fromJson(record.placeSnapshot);
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
          FilledButton.tonalIcon(
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
    await controller.deleteRecord(record.id);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('記録を削除しました。')));
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
    final place = Place.fromJson(record.placeSnapshot);
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    place.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${record.visitedAt.year}/${record.visitedAt.month}/${record.visitedAt.day}',
                ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: '編集して再保存',
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '削除',
                ),
              ],
            ),
            Text(place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(label: 'route ${record.routeDistanceMeters.round()}m'),
                _Tag(
                  label:
                      'straight ${record.straightLineDistanceMeters.round()}m',
                ),
                _Tag(
                  label:
                      'vertical ${record.baseVerticalFloors + record.placeVerticalFloors}F',
                ),
                _Tag(
                  label: 'score ${record.difficultyScore.toStringAsFixed(0)}',
                ),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                if (place.entranceFloorLabel.isNotEmpty)
                  _Tag(label: 'entry ${place.entranceFloorLabel}'),
                _Tag(label: place.hasElevator ? 'EVあり' : '階段中心'),
                if (place.hasElevator && place.elevatorRideCount != null)
                  _Tag(label: 'EV ${place.elevatorRideCount}回'),
                _Tag(
                  label: record.dineType == DineType.dineIn ? '店内飲食' : 'テイクアウト',
                ),
                _Tag(label: 'v${record.scoreVersion}'),
              ],
            ),
            Text(
              '拠点縦移動 ${record.baseVerticalFloors}F / 店舗縦移動 ${record.placeVerticalFloors}F',
            ),
            if (record.menu.isNotEmpty) Text('Menu: ${record.menu}'),
            if (record.price != null) Text('Price: ${record.price}'),
            if (record.paymentMethod.isNotEmpty)
              Text('Payment: ${record.paymentMethod}'),
            if (record.memo.isNotEmpty) Text(record.memo),
          ],
        ),
      ),
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
              child: record == null
                  ? Text('$label: まだ記録なし')
                  : Text(
                      '$label: ${Place.fromJson(record!.placeSnapshot).name}',
                    ),
            ),
            if (record != null) Text(metricBuilder(record!)),
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
              child: entry == null
                  ? Text('$label: まだ記録なし')
                  : Text('$label: ${entry!.placeName}'),
            ),
            if (entry != null) Text('${entry!.count} 回'),
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
