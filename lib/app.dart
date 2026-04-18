import 'dart:convert';

import 'package:flutter/material.dart';

import 'models/base_location.dart';
import 'models/lunch_challenge_record.dart';
import 'models/place.dart';
import 'services/persistence_service.dart';
import 'services/place_search_service.dart';
import 'utils/distance_calculator.dart';
import 'utils/floor_parser.dart';
import 'utils/score_calculator.dart';

const _provider = String.fromEnvironment(
  'PLACE_SEARCH_PROVIDER',
  defaultValue: 'mock',
);
const _yahooApiKey = String.fromEnvironment('YAHOO_API_KEY', defaultValue: '');

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
      searchService: CompositePlaceSearchService(
        const SearchConfig(provider: _provider, yahooApiKey: _yahooApiKey),
      ),
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
    required PlaceSearchService searchService,
  }) : _persistence = persistence,
       _searchService = searchService;

  final PersistenceService _persistence;
  final PlaceSearchService _searchService;

  bool isBootstrapping = true;
  bool isSearching = false;
  String? errorMessage;
  BaseLocation? baseLocation;
  List<Place> places = const [];
  List<LunchChallengeRecord> records = const [];
  List<Place> searchResults = const [];
  RecordSort recordSort = RecordSort.latest;

  Future<void> load() async {
    isBootstrapping = true;
    notifyListeners();
    baseLocation = await _persistence.loadBaseLocation();
    places = await _persistence.loadPlaces();
    records = await _persistence.loadRecords();
    isBootstrapping = false;
    notifyListeners();
  }

  Future<void> saveBaseLocation({
    required String name,
    required double lat,
    required double lng,
    required String memo,
  }) async {
    final location = BaseLocation(
      id: baseLocation?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      lat: lat,
      lng: lng,
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
      searchResults = await _searchService.search(
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

  Future<void> saveRecord({
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
      id: DateTime.now().microsecondsSinceEpoch.toString(),
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
    records = [record, ...records];
    await _persistence.savePlaces(places);
    await _persistence.saveRecords(records);
    notifyListeners();
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
                _provider == 'mock' || _yahooApiKey.isEmpty
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
  late final TextEditingController _nameController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late final TextEditingController _memoController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final base = widget.controller.baseLocation;
    _nameController = TextEditingController(text: base?.name ?? 'Office');
    _latController = TextEditingController(text: base?.lat.toString() ?? '');
    _lngController = TextEditingController(text: base?.lng.toString() ?? '');
    _memoController = TextEditingController(text: base?.memo ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _latController.dispose();
    _lngController.dispose();
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
          subtitle: '単一拠点のMVP。後から複数拠点へ拡張しやすい形で保持します。',
          child: Form(
            key: _formKey,
            child: Column(
              spacing: 16,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '拠点名'),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty) ? '必須です' : null,
                ),
                TextFormField(
                  controller: _latController,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '緯度'),
                  validator: _validateDouble,
                ),
                TextFormField(
                  controller: _lngController,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '経度'),
                  validator: _validateDouble,
                ),
                TextFormField(
                  controller: _memoController,
                  decoration: const InputDecoration(labelText: 'メモ'),
                  maxLines: 2,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () async {
                      if (!_formKey.currentState!.validate()) {
                        return;
                      }
                      await controller.saveBaseLocation(
                        name: _nameController.text.trim(),
                        lat: double.parse(_latController.text.trim()),
                        lng: double.parse(_lngController.text.trim()),
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
                value: _provider == 'mock' || _yahooApiKey.isEmpty
                    ? 'Mock fallback'
                    : 'Yahoo API',
              ),
              _MetricTile(
                label: '登録記録数',
                value: '${controller.records.length} 件',
              ),
              _MetricTile(
                label: '現在の基準地点',
                value: base == null
                    ? '未設定'
                    : '${base.name} (${base.lat.toStringAsFixed(4)}, ${base.lng.toStringAsFixed(4)})',
              ),
            ],
          ),
        ),
      ],
    );
  }

  String? _validateDouble(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '必須です';
    }
    if (double.tryParse(value.trim()) == null) {
      return '数値で入力してください';
    }
    return null;
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
  bool _nearbyOnly = true;

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
                title: const Text('基準地点の近傍だけを表示'),
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
          subtitle: '建物名と階数ラベルを確認し、必要なら補正してから記録します。',
          child: controller.searchResults.isEmpty
              ? const Text('検索結果はまだありません。')
              : Column(
                  spacing: 12,
                  children: controller.searchResults
                      .map(
                        (place) => _PlaceResultTile(
                          place: place,
                          baseLocation: controller.baseLocation,
                          onUse: () => _openRecordSheet(context, place: place),
                        ),
                      )
                      .toList(),
                ),
        ),
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
}

class _PlaceResultTile extends StatelessWidget {
  const _PlaceResultTile({
    required this.place,
    required this.baseLocation,
    required this.onUse,
  });

  final Place place;
  final BaseLocation? baseLocation;
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
            Text(place.name, style: Theme.of(context).textTheme.titleMedium),
            Text(place.address),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(label: place.provider.toUpperCase()),
                if (place.buildingName.isNotEmpty)
                  _Tag(label: place.buildingName),
                if (place.floorLabel.isNotEmpty) _Tag(label: place.floorLabel),
                if (place.category.isNotEmpty) _Tag(label: place.category),
                if (distance != null)
                  _Tag(label: '${distance.round()} m from base'),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onUse,
                child: const Text('この候補で記録'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordSheet extends StatefulWidget {
  const _RecordSheet({required this.controller, this.initialPlace});

  final ReachTrailController controller;
  final Place? initialPlace;

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
    _menuController = TextEditingController();
    _priceController = TextEditingController();
    _paymentController = TextEditingController();
    _memoController = TextEditingController();
    _timeLimitController = TextEditingController(text: '60');
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
                widget.initialPlace == null ? '手入力で記録' : '候補から記録',
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
                  child: Text(_submitting ? '保存中...' : '保存する'),
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
                  (record) => _RecordTile(record: record),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final LunchChallengeRecord record;

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
