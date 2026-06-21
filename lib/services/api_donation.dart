import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/donation.dart';

/// Today's total + the per-device daily GOAL for one kiosk.
/// [goal] is the effective target (saved target x today's day uplift); it is
/// null when the device has no configured target. [progress] is 0..1.
class KioskGoal {
  final double total;
  final double? goal;
  final double progress;
  final int count; // THIS kiosk's successful-donation count today

  const KioskGoal({
    required this.total,
    required this.goal,
    required this.progress,
    required this.count,
  });
}

class ApiDonation {
  static const baseUrl = 'https://api.mithqal.net';

  Future<List<Donation>> getDonations() async {
    var urlDonations = 'donations';

    final response = await http.get(
      Uri.parse('$baseUrl/$urlDonations'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      List<dynamic> data = json.decode(response.body);
      return data.map((json) => Donation.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load donations');
    }
  }

  /// TODAY's successful-donation COUNT across ALL devices (Asia/Muscat day),
  /// from GET /api/donations-today. Throws on non-200 so the caller can keep
  /// the last known value.
  Future<int> getTodayDonationCount() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/donations-today'),
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final dynamic count = data['count'];
      if (count is int) return count;
      if (count is num) return count.toInt();
      if (count is String) return int.tryParse(count) ?? 0;
      return 0;
    }

    throw Exception('Failed to load today\'s donation count');
  }

  /// TODAY's successful-donation total (OMR) for ONE kiosk — drives the daily
  /// goal branch. GET /api/donations-today/{kioskId}. Throws on non-200.
  Future<double> getKioskTodayTotal(String kioskId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/donations-today/$kioskId'),
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final dynamic total = data['total'];
      if (total is num) return total.toDouble();
      if (total is String) return double.tryParse(total) ?? 0.0;
      return 0.0;
    }

    throw Exception('Failed to load kiosk daily total');
  }

  /// TODAY's total + the device's effective daily GOAL (target x day uplift) for
  /// ONE kiosk, from GET /api/donations-today/{kioskId}. The goal comes straight
  /// from the device table's configured target; null if none is set. Throws on
  /// non-200 so the caller can keep the last known value.
  Future<KioskGoal> getKioskGoal(String kioskId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/donations-today/$kioskId'),
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;

      double toDouble(dynamic v) {
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? 0.0;
        return 0.0;
      }

      int toInt(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v) ?? 0;
        return 0;
      }

      final total = toDouble(data['total']);
      final goal = data['goal'] == null ? null : toDouble(data['goal']);
      final progress = data['progress'] != null
          ? toDouble(data['progress']).clamp(0.0, 1.0).toDouble()
          : (goal != null && goal > 0
                ? (total / goal).clamp(0.0, 1.0).toDouble()
                : 0.0);

      return KioskGoal(
        total: total,
        goal: goal,
        progress: progress,
        count: toInt(data['count']),
      );
    }

    throw Exception('Failed to load kiosk goal');
  }

  Future<Donation> createDonation(Donation donation) async {
    var urlDonations = 'api/donations-dhofar';

    final response = await http.post(
      Uri.parse('$baseUrl/$urlDonations'),
      body: json.encode(donation.toJson()),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode == 201) {
      return Donation.fromJson(json.decode(response.body)['data']);
    } else {
      final errorBody = json.decode(response.body);
      throw Exception('Failed to create donation: ${errorBody['message']}');
    }
  }
}
