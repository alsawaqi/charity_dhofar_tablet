import 'package:shared_preferences/shared_preferences.dart';

class LocalStorageService {
  static const String _kioskNumberKey = 'kiosk_number';
  static const String _terminalIdKey = 'terminal_id';

  static Future<void> saveKioskNumber(String number) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kioskNumberKey, number);
  }

  static Future<String?> getKioskNumber() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kioskNumberKey);
  }

  static Future<void> clearKioskNumber() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kioskNumberKey);
  }

  static Future<void> saveTerminalId(String terminalId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_terminalIdKey, terminalId);
  }

  static Future<String?> getTerminalId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_terminalIdKey);
  }

  static Future<void> clearTerminalId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_terminalIdKey);
  }
}
