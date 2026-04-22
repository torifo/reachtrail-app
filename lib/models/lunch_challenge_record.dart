enum DineType { dineIn, takeout }

enum RecordSort { latest, distance, difficulty }

class LunchChallengeRecord {
  const LunchChallengeRecord({
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

  LunchChallengeRecord copyWith({
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
    return LunchChallengeRecord(
      id: id ?? this.id,
      baseLocationId: baseLocationId ?? this.baseLocationId,
      placeId: placeId ?? this.placeId,
      placeSnapshot: placeSnapshot ?? this.placeSnapshot,
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

  factory LunchChallengeRecord.fromJson(Map<String, dynamic> json) {
    return LunchChallengeRecord(
      id: json['id'] as String,
      baseLocationId: json['baseLocationId'] as String,
      placeId: json['placeId'] as String,
      placeSnapshot: Map<String, dynamic>.from(
        (json['placeSnapshot'] as Map).cast<String, dynamic>(),
      ),
      visitedAt: DateTime.parse(json['visitedAt'] as String),
      timeLimitMinutes: (json['timeLimitMinutes'] as num).toInt(),
      dineType: DineType.values.byName(json['dineType'] as String),
      menu: (json['menu'] as String?) ?? '',
      price: (json['price'] as num?)?.toInt(),
      paymentMethod: (json['paymentMethod'] as String?) ?? '',
      memo: (json['memo'] as String?) ?? '',
      straightLineDistanceMeters:
          (json['straightLineDistanceMeters'] as num?)?.toDouble() ??
          (json['horizontalDistanceMeters'] as num?)?.toDouble() ??
          0,
      routeDistanceMeters:
          (json['routeDistanceMeters'] as num?)?.toDouble() ??
          (json['horizontalDistanceMeters'] as num?)?.toDouble() ??
          0,
      baseVerticalFloors: (json['baseVerticalFloors'] as num?)?.toInt() ?? 0,
      placeVerticalFloors: (json['placeVerticalFloors'] as num?)?.toInt() ?? 0,
      difficultyScore: (json['difficultyScore'] as num).toDouble(),
      scoreVersion: (json['scoreVersion'] as num).toInt(),
    );
  }
}
