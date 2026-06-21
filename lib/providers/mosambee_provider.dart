import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/local_storage_service.dart';

final mosambeeProvider = Provider((ref) => MosambeeService());

class MosambeeService {
  static const MethodChannel _defaultChannel = MethodChannel(
    'com.example.mosambee',
  );

  final MethodChannel _channel;

  MosambeeService({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  Map<String, String> _loginArgs(String terminalId) => {
    'userName': terminalId,
    'pin': '1321',
    'partnerId': '',
    'packageName': 'com.mosambee.dhofar.softpos',
  };

  Map<String, String> _paymentArgs(double amount) => {
    'packageName': 'com.mosambee.dhofar.softpos',
    'amount': (amount * 1000).toInt().toString(),
    'mobNo': '91264444',
    'description': 'Charity Donation',
  };

  Future<String?> prepareSession() async {
    try {
      final terminalId = (await LocalStorageService.getTerminalId())?.trim();
      if (terminalId == null || terminalId.isEmpty) {
        throw PlatformException(
          code: 'MISSING_TERMINAL_ID',
          message: 'Terminal ID is not set',
        );
      }

      return _channel.invokeMethod<String>(
        'prepareLogin',
        _loginArgs(terminalId),
      );
    } on PlatformException catch (e) {
      return jsonEncode({
        'stage': 'flutter_platform',
        'status': 'failed',
        'code': e.code,
        'message': e.message,
        'details': e.details,
      });
    } catch (e) {
      return jsonEncode({
        'stage': 'flutter',
        'status': 'failed',
        'error': e.toString(),
      });
    }
  }

  Future<String?> payWithPreparedSession(double amount) async {
    try {
      return _channel.invokeMethod<String>(
        'payWithPreparedSession',
        _paymentArgs(amount),
      );
    } on PlatformException catch (e) {
      return jsonEncode({
        'stage': 'flutter_platform',
        'status': 'failed',
        'code': e.code,
        'message': e.message,
        'details': e.details,
      });
    } catch (e) {
      return jsonEncode({
        'stage': 'flutter',
        'status': 'failed',
        'error': e.toString(),
      });
    }
  }

  Future<String?> loginAndPay(double amount) async {
    try {
      final terminalId = (await LocalStorageService.getTerminalId())?.trim();
      if (terminalId == null || terminalId.isEmpty) {
        throw PlatformException(
          code: 'MISSING_TERMINAL_ID',
          message: 'Terminal ID is not set',
        );
      }

      final result = await _channel.invokeMethod<String>('loginAndPay', {
        ..._loginArgs(terminalId),
        ..._paymentArgs(amount),
      });

      return result;
    } on PlatformException catch (e) {
      return jsonEncode({
        'stage': 'flutter_platform',
        'status': 'failed',
        'code': e.code,
        'message': e.message,
        'details': e.details,
      });
    } catch (e) {
      return jsonEncode({
        'stage': 'flutter',
        'status': 'failed',
        'error': e.toString(),
      });
    }
  }
}
