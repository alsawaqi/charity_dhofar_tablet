import 'package:geolocator/geolocator.dart';

class LocationService {
  /// Returns current Position or null if permission denied / service off.
  static Future<Position?> getCurrentPosition() async {
    // 1) Check if location services are enabled (GPS)
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // You can show a dialog to ask user to enable GPS
      return null;
    }

    // 2) Check permission
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // user denied the permission
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are permanently denied, show message or redirect to settings
      return null;
    }

    // 3) Get the actual position
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    return position;
  }
}
