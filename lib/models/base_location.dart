class BaseLocation {
  const BaseLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.floorLabel = '',
    this.memo = '',
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String floorLabel;
  final String memo;

  BaseLocation copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    String? floorLabel,
    String? memo,
  }) {
    return BaseLocation(
      id: id ?? this.id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      floorLabel: floorLabel ?? this.floorLabel,
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
      memo: (json['memo'] as String?) ?? '',
    );
  }
}
