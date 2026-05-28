import '../models/dine_challenge_record.dart';

const int currentScoreVersion = 2;

int calculateVerticalFloorTravel({
  required int? startFloorNumber,
  required int? entryFloorNumber,
  required int? destinationFloorNumber,
}) {
  final normalizedEntry =
      entryFloorNumber ?? startFloorNumber ?? destinationFloorNumber;
  return (startFloorNumber != null && normalizedEntry != null
          ? (startFloorNumber - normalizedEntry).abs()
          : 0) +
      (destinationFloorNumber != null && normalizedEntry != null
          ? (destinationFloorNumber - normalizedEntry).abs()
          : 0);
}

double calculateDifficultyScore({
  required double routeDistanceMeters,
  required int baseVerticalFloors,
  required int placeVerticalFloors,
  required bool baseHasElevator,
  required bool placeHasElevator,
  required DineType dineType,
}) {
  const stairFloorWeight = 28.0;
  const elevatorFloorWeight = 10.0;
  const dineInBonus = 120.0;
  const takeoutBonus = 35.0;
  final baseFloorScore =
      baseVerticalFloors *
      (baseHasElevator ? elevatorFloorWeight : stairFloorWeight);
  final placeFloorScore =
      placeVerticalFloors *
      (placeHasElevator ? elevatorFloorWeight : stairFloorWeight);
  final dineScore = switch (dineType) {
    DineType.dineIn => dineInBonus,
    DineType.takeout => takeoutBonus,
  };
  return routeDistanceMeters + baseFloorScore + placeFloorScore + dineScore;
}
