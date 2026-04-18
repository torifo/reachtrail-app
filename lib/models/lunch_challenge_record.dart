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
    required this.horizontalDistanceMeters,
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
  final double horizontalDistanceMeters;
  final double difficultyScore;
  final int scoreVersion;

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
      'horizontalDistanceMeters': horizontalDistanceMeters,
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
      horizontalDistanceMeters: (json['horizontalDistanceMeters'] as num)
          .toDouble(),
      difficultyScore: (json['difficultyScore'] as num).toDouble(),
      scoreVersion: (json['scoreVersion'] as num).toInt(),
    );
  }
}
