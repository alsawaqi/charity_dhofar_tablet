import 'package:flutter/material.dart';
import '../services/local_storage_service.dart';
import 'sadaqah_page.dart';

class SetupNumberPage extends StatefulWidget {
  const SetupNumberPage({super.key});
  @override
  State<SetupNumberPage> createState() => _SetupNumberPageState();
}

class _SetupNumberPageState extends State<SetupNumberPage> {
  final TextEditingController _kioskController = TextEditingController();
  final TextEditingController _terminalIdController = TextEditingController();
  String? _kioskError;
  String? _terminalIdError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();

    () async {
      final kiosk = await LocalStorageService.getKioskNumber();
      final terminalId = await LocalStorageService.getTerminalId();

      if (!mounted) return;
      if (kiosk != null && kiosk.isNotEmpty) {
        _kioskController.text = kiosk;
      }
      if (terminalId != null && terminalId.isNotEmpty) {
        _terminalIdController.text = terminalId;
      }
    }();
  }

  @override
  void dispose() {
    _kioskController.dispose();
    _terminalIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1B1C1F);

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF242529),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Setup Kiosk',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter kiosk number and terminal id.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _kioskController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Kiosk number (e.g. 101)',
                  hintStyle: const TextStyle(color: Colors.white54),
                  errorText: _kioskError,
                  filled: true,
                  fillColor: const Color(0xFF303238),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _terminalIdController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Terminal ID (e.g. 10036997)',
                  hintStyle: const TextStyle(color: Colors.white54),
                  errorText: _terminalIdError,
                  filled: true,
                  fillColor: const Color(0xFF303238),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _saveError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          final kioskNumber = _kioskController.text.trim();
                          final terminalId = _terminalIdController.text.trim();

                          setState(() {
                            _kioskError = null;
                            _terminalIdError = null;
                            _saveError = null;
                          });

                          var hasError = false;
                          if (kioskNumber.isEmpty) {
                            hasError = true;
                            setState(() => _kioskError = 'Please enter kiosk number');
                          }
                          if (terminalId.isEmpty) {
                            hasError = true;
                            setState(() => _terminalIdError = 'Please enter terminal id');
                          }
                          if (hasError) return;

                          setState(() {
                            _saving = true;
                          });

                          try {
                            await Future.wait([
                              LocalStorageService.saveKioskNumber(kioskNumber),
                              LocalStorageService.saveTerminalId(terminalId),
                            ]);

                            if (!context.mounted) return;

                            // Navigate to SadaqahPage and replace this screen
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) => const SadaqahPage(),
                              ),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() {
                              _saving = false;
                              _saveError = 'Failed to save: $e';
                            });
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1EF17F),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.black,
                            ),
                          ),
                        )
                      : const Text(
                          'Continue',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
