import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' as latlong;

import 'models/base_location.dart';
import 'models/lunch_challenge_record.dart';
import 'models/place.dart';
import 'services/local_config_service.dart';
import 'services/persistence_service.dart';
import 'services/place_search_service.dart';
import 'utils/distance_calculator.dart';
import 'utils/floor_parser.dart';
import 'utils/score_calculator.dart';

class ReachTrailApp extends StatefulWidget {
  const ReachTrailApp({super.key});

  @override
  State<ReachTrailApp> createState() => _ReachTrailAppState();
}

class _ReachTrailAppState extends State<ReachTrailApp> {
  late final ReachTrailController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ReachTrailController(
      persistence: PersistenceService(),
      configService: LocalConfigService(),
    )..load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'ReachTrail',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0D9488),
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF5F3ED),
            useMaterial3: true,
          ),
          home: ReachTrailHome(controller: _controller),
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
  String? errorMessage;
  String? baseSearchError;
  String placeSearchProvider = 'mock';
  String yahooApiKey = '';
  BaseLocation? baseLocation;
  List<Place> places = const [];
  List<LunchChallengeRecord> records = const [];
  List<Place> searchResults = const [];
  List<Place> baseSearchResults = const [];
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
        yahooProxyBaseUrl: kIsWeb ? 'http://localhost:3000' : '',
      ),
    );
  }

  Future<void> saveBaseLocation({
    required String name,
    required double lat,
    required double lng,
    required String floorLabel,
    required String memo,
  }) async {
    final location = BaseLocation(
      id: baseLocation?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      lat: lat,
      lng: lng,
      floorLabel: floorLabel,
      memo: memo,
    );
    await _persistence.saveBaseLocation(location);
    baseLocation = location;
    notifyListeners();
  }

  Future<void> searchPlaces(String query, {required bool nearbyOnly}) async {
    isSearching = true;
    errorMessage = null;
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

    final distance = calculateDistanceMeters(
      startLat: currentBase.lat,
      startLng: currentBase.lng,
      endLat: place.lat,
      endLng: place.lng,
    );
    final score = calculateDifficultyScore(
      horizontalDistanceMeters: distance,
      floorNumber: place.floorNumber,
      dineType: dineType,
    );
    final savedPlace = _upsertPlace(place);
    final record = LunchChallengeRecord(
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
      horizontalDistanceMeters: distance,
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

  int get outdatedScoreCount =>
      records.where((item) => item.scoreVersion != currentScoreVersion).length;

  Future<int> recalculateScores() async {
    final currentBase = baseLocation;
    if (currentBase == null || records.isEmpty) {
      return 0;
    }

    var updatedCount = 0;
    final recalculated = records.map((record) {
      final place = Place.fromJson(record.placeSnapshot);
      final distance = calculateDistanceMeters(
        startLat: currentBase.lat,
        startLng: currentBase.lng,
        endLat: place.lat,
        endLng: place.lng,
      );
      final score = calculateDifficultyScore(
        horizontalDistanceMeters: distance,
        floorNumber: place.floorNumber,
        dineType: record.dineType,
      );

      final changed =
          record.horizontalDistanceMeters != distance ||
          record.difficultyScore != score ||
          record.scoreVersion != currentScoreVersion;
      if (changed) {
        updatedCount += 1;
      }

      return record.copyWith(
        horizontalDistanceMeters: distance,
        difficultyScore: score,
        scoreVersion: currentScoreVersion,
      );
    }).toList();

    records = recalculated;
    await _persistence.saveRecords(records);
    notifyListeners();
    return updatedCount;
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

  List<LunchChallengeRecord> get sortedRecords {
    final copy = [...records];
    switch (recordSort) {
      case RecordSort.latest:
        copy.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
      case RecordSort.distance:
        copy.sort(
          (a, b) =>
              b.horizontalDistanceMeters.compareTo(a.horizontalDistanceMeters),
        );
      case RecordSort.difficulty:
        copy.sort((a, b) => b.difficultyScore.compareTo(a.difficultyScore));
    }
    return copy;
  }

  LunchChallengeRecord? get bestDistanceRecord {
    if (records.isEmpty) {
      return null;
    }
    return sortedRecordsFor(RecordSort.distance).first;
  }

  LunchChallengeRecord? get bestDifficultyRecord {
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

  List<LunchChallengeRecord> sortedRecordsFor(RecordSort sort) {
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
  const ReachTrailHome({super.key, required this.controller});

  final ReachTrailController controller;

  @override
  State<ReachTrailHome> createState() => _ReachTrailHomeState();
}

class _ReachTrailHomeState extends State<ReachTrailHome> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.isBootstrapping) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ReachTrail'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                controller.placeSearchProvider == 'mock' ||
                        controller.yahooApiKey.isEmpty
                    ? 'Mock Search'
                    : 'Yahoo Search',
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          _BaseLocationTab(controller: controller),
          _RegisterTab(controller: controller),
          _RecordsTab(controller: controller),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
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
            icon: Icon(Icons.emoji_events_outlined),
            selectedIcon: Icon(Icons.emoji_events),
            label: 'Records',
          ),
        ],
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
  late final TextEditingController _floorController;
  late final TextEditingController _memoController;
  final _formKey = GlobalKey<FormState>();
  Place? _selectedCandidate;
  double? _selectedLat;
  double? _selectedLng;

  @override
  void initState() {
    super.initState();
    final base = widget.controller.baseLocation;
    _searchController = TextEditingController();
    _nameController = TextEditingController(text: base?.name ?? 'Office');
    _floorController = TextEditingController(text: base?.floorLabel ?? '');
    _memoController = TextEditingController(text: base?.memo ?? '');
    _selectedLat = base?.lat;
    _selectedLng = base?.lng;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nameController.dispose();
    _floorController.dispose();
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
          subtitle: 'Yahoo検索ベースで基準地点候補を探し、選んだ地点を拠点として保存します。',
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
                FilledButton.icon(
                  onPressed: controller.isBaseSearching ? null : _runBaseSearch,
                  icon: controller.isBaseSearching
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('基準地点を検索'),
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
                  controller: _floorController,
                  decoration: const InputDecoration(
                    labelText: '階数（任意）',
                    hintText: '例: 22F, B1, 3F',
                    prefixIcon: Icon(Icons.layers_outlined),
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
                  child: FilledButton(
                    onPressed: () async {
                      if (!_formKey.currentState!.validate()) {
                        return;
                      }
                      if (_selectedLat == null || _selectedLng == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('先に基準地点候補を選んでください。')),
                        );
                        return;
                      }
                      await controller.saveBaseLocation(
                        name: _nameController.text.trim(),
                        lat: _selectedLat!,
                        lng: _selectedLng!,
                        floorLabel: _floorController.text.trim(),
                        memo: _memoController.text.trim(),
                      );
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('基準地点を保存しました。')),
                      );
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Status',
          subtitle: '実装着手前に確認したかった成立性を、画面から追える形にしています。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              _MetricTile(
                label: '検索プロバイダ',
                value:
                    controller.placeSearchProvider == 'mock' ||
                        controller.yahooApiKey.isEmpty
                    ? 'Mock fallback'
                    : 'Yahoo API',
              ),
              _MetricTile(
                label: 'Yahoo API Key',
                value: controller.yahooApiKey.isEmpty ? '未設定' : '設定済み',
              ),
              _MetricTile(
                label: '登録記録数',
                value: '${controller.records.length} 件',
              ),
              _MetricTile(
                label: '現在の基準地点',
                value: base == null
                    ? '未設定'
                    : [
                        base.name,
                        if (base.floorLabel.isNotEmpty) base.floorLabel,
                        '(${base.lat.toStringAsFixed(4)}, ${base.lng.toStringAsFixed(4)})',
                      ].join(' '),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await controller.reloadConfig();
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('設定ファイルを再読み込みしました。')),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('設定を再読込'),
                ),
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
      _floorController.text = '';
      _memoController.text = place.address;
    });
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

class _RegisterTab extends StatefulWidget {
  const _RegisterTab({required this.controller});

  final ReachTrailController controller;

  @override
  State<_RegisterTab> createState() => _RegisterTabState();
}

class _RegisterTabState extends State<_RegisterTab> {
  final _searchController = TextEditingController();
  final _mapController = MapController();
  bool _nearbyOnly = true;
  bool _showDebugInfo = false;
  String? _selectedPlaceId;

  @override
  void dispose() {
    _searchController.dispose();
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
          subtitle: '候補選択を前提にしつつ、候補が弱い場合は手入力で完結させます。',
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
                title: const Text('基準地点から片道徒歩1時間圏内で絞り込む'),
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
              ? const Text('検索結果はまだありません。')
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
            subtitle: 'Google有料サービスは使わず、OpenStreetMapで基準地点と候補位置を見比べます。',
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
    if (_searchController.text.trim().isEmpty) {
      return;
    }
    await widget.controller.searchPlaces(
      _searchController.text.trim(),
      nearbyOnly: _nearbyOnly,
    );
    if (!mounted) {
      return;
    }
    final results = widget.controller.searchResults;
    if (results.isNotEmpty) {
      _selectPlace(results.first, moveMap: true);
    }
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
      ).showSnackBar(const SnackBar(content: Text('ランチ記録を保存しました。')));
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
                    _Tag(label: '${distance.round()} m from base'),
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
                    FilledButton.tonal(
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
      return const Center(child: Text('基準地点と候補があるとレーダー表示できます。'));
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
      child: FlutterMap(
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
  final LunchChallengeRecord? existingRecord;

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _buildingController;
  late final TextEditingController _floorLabelController;
  late final TextEditingController _floorNumberController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late final TextEditingController _categoryController;
  late final TextEditingController _menuController;
  late final TextEditingController _priceController;
  late final TextEditingController _paymentController;
  late final TextEditingController _memoController;
  late final TextEditingController _timeLimitController;
  DineType _dineType = DineType.dineIn;
  DateTime _visitedAt = DateTime.now();
  bool _submitting = false;

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
    _floorNumberController = TextEditingController(
      text: place?.floorNumber?.toString() ?? '',
    );
    _latController = TextEditingController(text: place?.lat.toString() ?? '');
    _lngController = TextEditingController(text: place?.lng.toString() ?? '');
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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _buildingController.dispose();
    _floorLabelController.dispose();
    _floorNumberController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _categoryController.dispose();
    _menuController.dispose();
    _priceController.dispose();
    _paymentController.dispose();
    _memoController.dispose();
    _timeLimitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
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
              Text(
                widget.existingRecord != null
                    ? '記録を編集'
                    : widget.initialPlace == null
                    ? '手入力で記録'
                    : '候補から記録',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: '店舗名'),
                validator: _required,
              ),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(labelText: '住所'),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _buildingController,
                      decoration: const InputDecoration(labelText: '建物名'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _categoryController,
                      decoration: const InputDecoration(labelText: 'カテゴリ'),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _floorLabelController,
                      decoration: const InputDecoration(labelText: '階数ラベル'),
                      onChanged: (value) {
                        final parsed = parseFloorNumber(value);
                        if (parsed != null &&
                            _floorNumberController.text.trim().isEmpty) {
                          _floorNumberController.text = '$parsed';
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _floorNumberController,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      decoration: const InputDecoration(labelText: '数値階'),
                    ),
                  ),
                ],
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
                      decoration: const InputDecoration(labelText: '緯度'),
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
                      decoration: const InputDecoration(labelText: '経度'),
                      validator: _requiredDouble,
                    ),
                  ),
                ],
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
                      decoration: const InputDecoration(labelText: '制限時間(分)'),
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
              TextFormField(
                controller: _menuController,
                decoration: const InputDecoration(labelText: 'メニュー'),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _priceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '価格'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _paymentController,
                      decoration: const InputDecoration(labelText: '支払い方法'),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: _memoController,
                decoration: const InputDecoration(labelText: 'メモ'),
                maxLines: 3,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(
                    _submitting
                        ? '保存中...'
                        : widget.existingRecord == null
                        ? '保存する'
                        : '更新する',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
    final explicitFloor = _floorNumberController.text.trim();
    final floorNumber = explicitFloor.isEmpty
        ? parseFloorNumber(_floorLabelController.text)
        : int.tryParse(explicitFloor);
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
      category: _categoryController.text.trim(),
      rawPayload:
          widget.initialPlace?.rawPayload ?? jsonEncode({'source': 'manual'}),
    );
    await widget.controller.saveRecord(
      recordId: widget.existingRecord?.id,
      place: place,
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
          subtitle: '実距離と難易度を分離し、両方の納得感を確認できます。',
          child: Column(
            spacing: 12,
            children: [
              _BestRecordTile(
                label: 'Longest distance',
                record: controller.bestDistanceRecord,
                metricBuilder: (record) =>
                    '${record.horizontalDistanceMeters.round()} m',
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
          subtitle: 'scoreVersion を保存し、後から再計算可能な前提で一覧化しています。',
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
                    RecordSort.distance => '距離順',
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
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record, required this.onEdit});

  final LunchChallengeRecord record;
  final Future<void> Function() onEdit;

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
              ],
            ),
            Text(place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(label: '${record.horizontalDistanceMeters.round()} m'),
                _Tag(
                  label: 'score ${record.difficultyScore.toStringAsFixed(0)}',
                ),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                _Tag(
                  label: record.dineType == DineType.dineIn ? '店内飲食' : 'テイクアウト',
                ),
                _Tag(label: 'v${record.scoreVersion}'),
              ],
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
  final LunchChallengeRecord? record;
  final String Function(LunchChallengeRecord record) metricBuilder;

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
