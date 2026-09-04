enum DineType { dineIn, takeout }

enum RecordSort { latest, distance, difficulty }

class DineChallengeRecord {
  const DineChallengeRecord({
    required this.id,
    required this.baseLocationId,
    required this.placeId,
    required this.placeSnapshot,
    required this.visitedAt,
    required this.timeLimitMinutes,
    required this.dineType,
    required this.menu,
    required this.price,
    required this.paymentMethod,
    required this.memo,
    required this.straightLineDistanceMeters,
    required this.routeDistanceMeters,
    required this.baseVerticalFloors,
    required this.placeVerticalFloors,
    required this.difficultyScore,
    required this.scoreVersion,
  });

  final String id;
  final String baseLocationId;
  final String placeId;
  final Map<String, dynamic> placeSnapshot;
  final DateTime visitedAt;
  final int timeLimitMinutes;
  final DineType dineType;
  final String menu;
  final int? price;
  final String paymentMethod;
  final String memo;
  final double straightLineDistanceMeters;
  final double routeDistanceMeters;
  final int baseVerticalFloors;
  final int placeVerticalFloors;
  final double difficultyScore;
  final int scoreVersion;

  DineChallengeRecord copyWith({
    String? id,
    String? baseLocationId,
    String? placeId,
    Map<String, dynamic>? placeSnapshot,
    DateTime? visitedAt,
    int? timeLimitMinutes,
    DineType? dineType,
    String? menu,
    int? price,
    bool clearPrice = false,
    String? paymentMethod,
    String? memo,
    double? straightLineDistanceMeters,
    double? routeDistanceMeters,
    int? baseVerticalFloors,
    int? placeVerticalFloors,
    double? difficultyScore,
    int? scoreVersion,
  }) {
    return DineChallengeRecord(
      id: id ?? this.id,
      baseLocationId: baseLocationId ?? this.baseLocationId,
      placeId: placeId ?? this.placeId,
      // Defensive copy: without it every copyWith result would share the same
      // mutable snapshot map as the original record.
      placeSnapshot: Map<String, dynamic>.from(
        placeSnapshot ?? this.placeSnapshot,
      ),
      visitedAt: visitedAt ?? this.visitedAt,
      timeLimitMinutes: timeLimitMinutes ?? this.timeLimitMinutes,
      dineType: dineType ?? this.dineType,
      menu: menu ?? this.menu,
      price: clearPrice ? null : price ?? this.price,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      memo: memo ?? this.memo,
      straightLineDistanceMeters:
          straightLineDistanceMeters ?? this.straightLineDistanceMeters,
      routeDistanceMeters: routeDistanceMeters ?? this.routeDistanceMeters,
      baseVerticalFloors: baseVerticalFloors ?? this.baseVerticalFloors,
      placeVerticalFloors: placeVerticalFloors ?? this.placeVerticalFloors,
      difficultyScore: difficultyScore ?? this.difficultyScore,
      scoreVersion: scoreVersion ?? this.scoreVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'baseLocationId': baseLocationId,
      'placeId': placeId,
      'placeSnapshot': placeSnapshot,
      'visitedAt': visitedAt.toIso8601String(),
      'timeLimitMinutes': timeLimitMinutes,
      'dineType': dineType.name,
      'menu': menu,
      'price': price,
      'paymentMethod': paymentMethod,
      'memo': memo,
      'straightLineDistanceMeters': straightLineDistanceMeters,
      'routeDistanceMeters': routeDistanceMeters,
      'baseVerticalFloors': baseVerticalFloors,
      'placeVerticalFloors': placeVerticalFloors,
      'difficultyScore': difficultyScore,
      'scoreVersion': scoreVersion,
    };
  }

  /// Tolerant decoder: records written by older builds (or partially corrupted
  /// entries) must never crash the app at startup, so every field falls back to
  /// a sane default instead of hard-casting.
  factory DineChallengeRecord.fromJson(Map<String, dynamic> json) {
    return DineChallengeRecord(
      id: _asString(json['id']),
      baseLocationId: _asString(json['baseLocationId']),
      placeId: _asString(json['placeId']),
      placeSnapshot: json['placeSnapshot'] is Map
          ? Map<String, dynamic>.from(json['placeSnapshot'] as Map)
          : <String, dynamic>{},
      // An unparseable timestamp used to become 1970-01-01, which sorts and
      // reads as a real visit. Treat it as corrupt so the persistence layer
      // skips the entry instead.
      visitedAt: _parseVisitedAt(json['visitedAt']),
      timeLimitMinutes: _asInt(json['timeLimitMinutes']) ?? 0,
      dineType: parseDineType(json['dineType']),
      menu: _asOptionalString(json['menu']) ?? '',
      price: _asInt(json['price']),
      paymentMethod: _asOptionalString(json['paymentMethod']) ?? '',
      memo: _asOptionalString(json['memo']) ?? '',
      straightLineDistanceMeters:
          _asDouble(json['straightLineDistanceMeters']) ??
          _asDouble(json['horizontalDistanceMeters']) ??
          0,
      routeDistanceMeters:
          _asDouble(json['routeDistanceMeters']) ??
          _asDouble(json['horizontalDistanceMeters']) ??
          0,
      baseVerticalFloors: _asInt(json['baseVerticalFloors']) ?? 0,
      placeVerticalFloors: _asInt(json['placeVerticalFloors']) ?? 0,
      difficultyScore: _asDouble(json['difficultyScore']) ?? 0,
      scoreVersion: _asInt(json['scoreVersion']) ?? 1,
    );
  }
}

DateTime _parseVisitedAt(Object? value) {
  final parsed = DateTime.tryParse(_asString(value));
  if (parsed == null) {
    throw const FormatException(
      'DineChallengeRecord requires a parseable visitedAt value.',
    );
  }
  return parsed.toLocal();
}

/// Resolves a stored `dineType` name, defaulting to [DineType.dineIn] for
/// values written by a future build or otherwise unrecognised.
DineType parseDineType(Object? value) {
  final name = _asOptionalString(value);
  if (name == null) {
    return DineType.dineIn;
  }
  for (final type in DineType.values) {
    if (type.name == name) {
      return type;
    }
  }
  return DineType.dineIn;
}

String _asString(Object? value) => _asOptionalString(value) ?? '';

String? _asOptionalString(Object? value) {
  if (value == null) {
    return null;
  }
  return value is String ? value : '$value';
}

int? _asInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}
