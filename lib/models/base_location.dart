class BaseLocation {
  const BaseLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.floorLabel = '',
    this.floorNumber,
    this.entryFloorLabel = '',
    this.entryFloorNumber,
    this.hasElevator = true,
    this.elevatorRideCount,
    this.memo = '',
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String floorLabel;
  final int? floorNumber;
  final String entryFloorLabel;
  final int? entryFloorNumber;
  final bool hasElevator;
  final int? elevatorRideCount;
  final String memo;

  BaseLocation copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    String? floorLabel,
    int? floorNumber,
    bool clearFloorNumber = false,
    String? entryFloorLabel,
    int? entryFloorNumber,
    bool clearEntryFloorNumber = false,
    bool? hasElevator,
    int? elevatorRideCount,
    bool clearElevatorRideCount = false,
    String? memo,
  }) {
    return BaseLocation(
      id: id ?? this.id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      floorLabel: floorLabel ?? this.floorLabel,
      floorNumber: clearFloorNumber ? null : floorNumber ?? this.floorNumber,
      entryFloorLabel: entryFloorLabel ?? this.entryFloorLabel,
      entryFloorNumber: clearEntryFloorNumber
          ? null
          : entryFloorNumber ?? this.entryFloorNumber,
      hasElevator: hasElevator ?? this.hasElevator,
      elevatorRideCount: clearElevatorRideCount
          ? null
          : elevatorRideCount ?? this.elevatorRideCount,
      memo: memo ?? this.memo,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'lat': lat,
      'lng': lng,
      'floorLabel': floorLabel,
      'floorNumber': floorNumber,
      'entryFloorLabel': entryFloorLabel,
      'entryFloorNumber': entryFloorNumber,
      'hasElevator': hasElevator,
      'elevatorRideCount': elevatorRideCount,
      'memo': memo,
    };
  }

  factory BaseLocation.fromJson(Map<String, dynamic> json) {
    return BaseLocation(
      id: json['id'] as String,
      name: json['name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      floorLabel: (json['floorLabel'] as String?) ?? '',
      floorNumber: (json['floorNumber'] as num?)?.toInt(),
      entryFloorLabel: (json['entryFloorLabel'] as String?) ?? '',
      entryFloorNumber: (json['entryFloorNumber'] as num?)?.toInt(),
      hasElevator: (json['hasElevator'] as bool?) ?? true,
      elevatorRideCount: (json['elevatorRideCount'] as num?)?.toInt(),
      memo: (json['memo'] as String?) ?? '',
    );
  }
}
