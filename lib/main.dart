import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screen/sadaqah_page.dart';
import 'services/local_storage_service.dart';
import 'screen/setup_number_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CharityApp()));
}

class CharityApp extends StatelessWidget {
  const CharityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mithqal — Sadaqah',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const StartupGate(),
    );
  }
}

class StartupGate extends StatelessWidget {
  const StartupGate({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String?>>(
      future: Future.wait([
        LocalStorageService.getKioskNumber(),
        LocalStorageService.getTerminalId(),
      ]),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final kioskNumber = snapshot.data?[0];
        final terminalId = snapshot.data?[1];
        final hasKioskNumber = kioskNumber != null && kioskNumber.isNotEmpty;
        final hasTerminalId = terminalId != null && terminalId.isNotEmpty;

        if (!hasKioskNumber || !hasTerminalId) {
          // First-time setup: missing kiosk number or terminal id
          return const SetupNumberPage();
        }

        // Number exists -> unlock SadaqahPage
        return const SadaqahPage();
      },
    );
  }
}
