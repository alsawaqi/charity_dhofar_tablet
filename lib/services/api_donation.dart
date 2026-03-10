import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/donation.dart';

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
