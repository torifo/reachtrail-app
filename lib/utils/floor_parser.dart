final _floorPattern = RegExp(r'(-?\d+)\s*(?:F|階)', caseSensitive: false);
final _basementPattern = RegExp(
  r'(?:B|地下)\s*(\d+)\s*(?:F|階)?',
  caseSensitive: false,
);

String _normalizeFloorText(String input) {
  const pairs = <String, String>{
    '０': '0',
    '１': '1',
    '２': '2',
    '３': '3',
    '４': '4',
    '５': '5',
    '６': '6',
    '７': '7',
    '８': '8',
    '９': '9',
    '－': '-',
    'ー': '-',
    '−': '-',
    '　': ' ',
  };

  var value = input.trim();
  pairs.forEach((from, to) {
    value = value.replaceAll(from, to);
  });
  return value;
}

int? parseFloorNumber(String input) {
  final value = _normalizeFloorText(input);
  if (value.isEmpty) {
    return null;
  }

  // Every parse is a tryParse: an unusual label must yield null rather than
  // throwing out of whatever is rendering the place.
  final basement = _basementPattern.firstMatch(value);
  if (basement != null) {
    final parsed = int.tryParse(basement.group(1) ?? '');
    if (parsed != null) {
      return -parsed;
    }
  }

  final floor = _floorPattern.firstMatch(value);
  if (floor != null) {
    final parsed = int.tryParse(floor.group(1) ?? '');
    if (parsed != null) {
      return parsed;
    }
  }

  return int.tryParse(value);
}
