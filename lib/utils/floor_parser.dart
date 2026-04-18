final _floorPattern = RegExp(r'(-?\d+)\s*F', caseSensitive: false);
final _basementPattern = RegExp(r'B\s*(\d+)', caseSensitive: false);

int? parseFloorNumber(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    return null;
  }

  final basement = _basementPattern.firstMatch(value);
  if (basement != null) {
    return -int.parse(basement.group(1)!);
  }

  final floor = _floorPattern.firstMatch(value);
  if (floor != null) {
    return int.parse(floor.group(1)!);
  }

  return int.tryParse(value);
}
