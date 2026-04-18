import '../models/lunch_challenge_record.dart';

const int currentScoreVersion = 1;

double calculateDifficultyScore({
  required double horizontalDistanceMeters,
  required int? floorNumber,
  required DineType dineType,
}) {
  const floorWeight = 28.0;
  const dineInBonus = 120.0;
  const takeoutBonus = 35.0;
  final floorScore = (floorNumber ?? 0).abs() * floorWeight;
  final dineScore = switch (dineType) {
    DineType.dineIn => dineInBonus,
    DineType.takeout => takeoutBonus,
  };
  return horizontalDistanceMeters + floorScore + dineScore;
}
