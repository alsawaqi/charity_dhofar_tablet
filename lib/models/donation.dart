import 'package:equatable/equatable.dart';

class Donation extends Equatable {
  final int id;
  final double amount;
  final Map<String, dynamic>? receipt;
  final String? status;

  // NEW:
  final double? latitude;
  final double? longitude;

  const Donation({
    required this.id,
    required this.amount,
    this.receipt,
    this.status,
    this.latitude,
    this.longitude,
  });

  static double _parseAmount(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    throw ArgumentError('Invalid amount type: $value');
  }

  static int _parseId(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    throw ArgumentError('Invalid id type: $value');
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    throw ArgumentError('Invalid double type: $value');
  }

  factory Donation.fromJson(Map<String, dynamic> json) {
    return Donation(
      id: _parseId(json['id']),
      amount: _parseAmount(json['amount']),
      receipt: json['receipt'] == null
          ? null
          : Map<String, dynamic>.from(json['receipt']),
      status: json['status'] as String?,
      latitude: _parseDouble(json['latitude']),
      longitude: _parseDouble(json['longitude']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'receipt': receipt,
    'status': status,
    'latitude': latitude,
    'longitude': longitude,
  };

  @override
  List<Object?> get props => [id, amount, receipt, status, latitude, longitude];
}
