import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/utils/floor_parser.dart';

void main() {
  test('parseFloorNumber handles Japanese floor labels', () {
    expect(parseFloorNumber('6F'), 6);
    expect(parseFloorNumber('６階'), 6);
    expect(parseFloorNumber('B1'), -1);
    expect(parseFloorNumber('地下2階'), -2);
    expect(parseFloorNumber('地下２階'), -2);
  });
}
