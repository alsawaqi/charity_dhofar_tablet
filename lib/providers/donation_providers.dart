import 'package:charity_dhofar_tablet/models/donation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../services/api_donation.dart';

final apiDonationProvider = Provider<ApiDonation>((ref) {
  return ApiDonation();
});

final donationsProvider =
    StateNotifierProvider<DonationNotifier, AsyncValue<List<Donation>>>((ref) {
      return DonationNotifier(ref.read(apiDonationProvider));
    });

final isAddingProvider = StateProvider<bool>((ref) => false);

class DonationNotifier extends StateNotifier<AsyncValue<List<Donation>>> {
  final ApiDonation _apiDonation;

  DonationNotifier(this._apiDonation) : super(const AsyncValue.loading()) {
    fetchDonations();
  }

  Future<void> fetchDonations() async {
    state = const AsyncValue.loading();
    try {
      final donations = await _apiDonation.getDonations();
      state = AsyncValue.data(donations);
    } catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }

  Future<void> addDonation(WidgetRef ref, Donation donation) async {
    // Remove WidgetRef parameter

    ref.read(isAddingProvider.notifier).state = true;

    try {
      final previous = state.value ?? const <Donation>[];
      state = const AsyncValue.loading();
      final createdDonation = await _apiDonation.createDonation(donation);

      // Update state correctly (keep previous list)
      state = AsyncValue.data([createdDonation, ...previous]);
    } catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
      rethrow;
    } finally {
      ref.read(isAddingProvider.notifier).state = false;
    }
  }
}

final donationsNotifierProvider =
    StateNotifierProvider<DonationNotifier, AsyncValue<List<Donation>>>((ref) {
      return DonationNotifier(ref.read(apiDonationProvider));
    });
