import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/donation.dart';
import '../providers/donation_providers.dart';
import '../providers/mosambee_provider.dart';
import '../services/local_storage_service.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';

/// ----------------- NATIVE BRIDGE -----------------
class WizzitIndent {
  static const _ch = MethodChannel('wizzit_indent');

  static Future<Map?> configure() async {
    final res = await _ch.invokeMethod('CONFIGURE');
    if (res is Map) return Map.from(res);
    return null;
  }

  static Future<Map?> pay({required int amount, int tips = 0}) async {
    try {
      final res = await _ch.invokeMethod('PAYMENT', {
        'amount': amount,
        'tips': tips,
      });
      if (res is Map) return Map.from(res);
      return null;
    } on PlatformException catch (e) {
      // user canceled in APK
      if (e.code == 'PAY_CANCELED') {
        return {'status': 'canceled', 'message': 'User canceled payment'};
      }
      // some other error
      return {'status': 'error', 'code': e.code, 'message': e.message};
    }
  }
}

/// ----------------- PAGE -----------------
class SadaqahPage extends ConsumerStatefulWidget {
  const SadaqahPage({super.key});
  @override
  ConsumerState<SadaqahPage> createState() => _SadaqahPageState();
}

class _SadaqahPageState extends ConsumerState<SadaqahPage>
    with TickerProviderStateMixin {
  // Discrete options: 0.5 OMR, then 1..39 OMR
  final List<double> _omrSteps = [
    0.5,
    ...Iterable<double>.generate(39, (i) => (i + 1).toDouble()),
  ];

  int _stepIndex = 1; // start at 1 OMR (0 => 0.5, 1 => 1, ..., 39 => 39)
  bool _isPaying = false; // prevent double-tap + show loading

  static const int _minIndex = 0;
  static const int _maxIndex = 39;

  bool _sliderActive = false;

  // Drag accumulation so 1 step ~ N px of vertical movement
  double _dragAccumulator = 0.0;
  static const double _pixelsPerStep = 22; // feel free to tweak

  late final AnimationController _sparkleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..addListener(() => setState(() {}));

  // NEW: gentle breathing / pulse for the main dial + tap hint
  late final AnimationController _pulseCtrl =
      AnimationController(
          vsync: this,
          duration: const Duration(seconds: 2),
          lowerBound: 0.0,
          upperBound: 1.0,
        )
        ..addListener(() => setState(() {}))
        ..repeat(reverse: true);

  bool _dragging = false;

  void _resetAmountControls() {
    if (!mounted) return;

    setState(() {
      _stepIndex = 1; // back to 1 OMR
      _dragAccumulator = 0.0;
      _dragging = false;

      // Optional: also reset the hints if you want
      // _sliderHintVisible = true;
      // _dialTapHintVisible = false;
    });
  }

  // ignore: unused_field
  final String _log = 'Ready';

  bool _sliderHintVisible = true; // show finger on the slider at first
  bool _dialTapHintVisible = false; // show tap hint on dial only after touch

  // Helpers
  double get _currentOmr => _omrSteps[_stepIndex];
  int get _currentBaisa => (_currentOmr * 1000).round();

  // Shown label rules: 0.500 first, then integers (no decimals)
  String get _amountLabel {
    if (_stepIndex == 0) return '0.500';
    return _currentOmr.toInt().toString();
  }

  @override
  void initState() {
    super.initState();
    // Always run the water-ripple animation
    _sparkleCtrl.repeat();
  }

  void _onSliderStart() {
    // First time user touches the slider → hide slider hint, show dial tap hint
    if (_sliderHintVisible || !_dialTapHintVisible) {
      setState(() {
        _sliderHintVisible = false;
        _dialTapHintVisible = true;
        _sliderActive = true;
      });
    }
    _startSparkles();
  }

  void _onSliderEnd() {
    // When we finish sliding, hide the tap hint and show the slider hint again
    setState(() {
      _sliderHintVisible = true;
      _dialTapHintVisible = false;
      _sliderActive = false;
    });
    _stopSparkles();
  }

  void _onDialTap() {
    // User understood the tap → hide the hint permanently
    setState(() => _dialTapHintVisible = false);
    _payAndDonate(_currentBaisa / 1000.0);
  }

  void _onDialDragStart() {
    // If they drag on the dial, they also understood it → hide hint
    setState(() => _dialTapHintVisible = false);
    _startSparkles();
  }

  void _startSparkles() {
    _dragAccumulator = 0;
    setState(() {
      _dragging = true; // stronger ripples
    });
  }

  void _stopSparkles() {
    setState(() {
      _dragging = false; // back to gentle ripples
    });
    _dragAccumulator = 0;
  }

  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (_) {
        return Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            margin: const EdgeInsets.symmetric(horizontal: 40),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F23),
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
                SizedBox(
                  height: 56,
                  width: 56,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF1EF17F),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Processing your donation…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showResultDialog({
    required bool success,
    required double omrAmount,
    String? errorMessage,
  }) {
    // 1) Show the dialog
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Donation result',
      barrierColor: Colors.black.withOpacity(0.7),
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );

        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: curved,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1F23),
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
                    Icon(
                      success
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      size: 64,
                      color: success
                          ? const Color(0xFF1EF17F)
                          : Colors.redAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      success ? 'Thank you!' : 'Something went wrong',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      success
                          ? 'Your donation of OMR ${omrAmount.toStringAsFixed(3)} has been received.'
                          : (errorMessage ??
                                'Please try again or contact support.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Button is optional now, but we can keep it
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1EF17F),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text(
                        'Close',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    // 2) Auto-dismiss after 3 seconds (only if still mounted & dialog is open)
    //    You can change the duration if you like.
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) {
        navigator.pop();
      }
    });
  }

  String get _dialSubtitle {
    // If amount is 1 OMR or more ➜ show Riyal
    if (_currentOmr >= 1.0) {
      return 'Riyal / ريال';
    }
    // Below 1 ➜ show Baisa
    return 'Baisa / بيسة';
  }

  // custom amount (integer rials)
  int amount = 0;

  
  String? kioskNumberStr;



  Future<void> _donates(
    int? id,
    double omrAmount,
    Map<String, dynamic>? receipt,
    String? status, {
    bool showDialog = true,
  }) async {
    // 1) Read kiosk number from local storage
    final kioskNumberStr = await LocalStorageService.getKioskNumber();
    final Position? pos = await LocationService.getCurrentPosition();

    // 2) Convert to int (you can add better error handling if you want)
    final kioskId = int.tryParse(kioskNumberStr ?? '');

    if (kioskId == null) {
      // Safety guard: if something is wrong, you can show an error / return
      _showResultDialog(
        success: false,
        omrAmount: omrAmount,
        errorMessage: 'Device ID is not set. Please configure this kiosk.',
      );
      return;
    }

    // 3) Use kioskId as the id in Donation
    final newDonation = Donation(
      id: kioskId,
      amount: omrAmount,
      receipt: receipt,
      status: status,
      latitude: pos?.latitude, // double
      longitude: pos?.longitude,
    );

    if (!mounted) return;

    // If you’re using the loading + result dialogs we wrote earlier:
    // Show loading dialog only if showDialog is true
    if (showDialog) {
      _showLoadingDialog();
    }

    try {
      await ref.read(donationsProvider.notifier).addDonation(ref, newDonation);

      if (!mounted) return;
      
      // Close loading dialog if it was shown
      if (showDialog) {
        Navigator.of(context, rootNavigator: true).pop(); // close loading
      }

      // Only show result dialog if showDialog is true
      if (showDialog) {
        // Only show success dialog if status is SUCCESS
        final isSuccess = (status ?? '').trim().toUpperCase() == 'SUCCESS';
        if (isSuccess) {
          _showResultDialog(success: true, omrAmount: omrAmount);
          // ✅ reset slider + dial after success
          _resetAmountControls();
        } else {
          // Show error dialog for failed/cancelled payments
          _showResultDialog(
            success: false,
            omrAmount: omrAmount,
            errorMessage: receipt?['message']?.toString() ?? 
                          receipt?['paymentDescription']?.toString() ?? 
                          receipt?['error']?.toString() ??
                          'Payment was not successful',
          );
          _resetAmountControls();
        }
      }
    } catch (error) {
        if (!mounted) return;
        
        // Close loading dialog if it was shown
        if (showDialog) {
          Navigator.of(context, rootNavigator: true).pop(); // close loading
        }

        final msg = error.toString().replaceFirst('Exception: ', '');

        print('msg: $msg');
        
        // Only show error dialog if showDialog is true
        if (showDialog) {
          _showResultDialog(
            success: false,
            omrAmount: omrAmount,
            errorMessage: msg,
          );
          // ✅ also reset after failure
          _resetAmountControls();
        }
    }
  }

  // Future<void> _configure() async {
  //   try {
  //     final res = await WizzitIndent.configure();
  //     setState(() => _log = 'CONFIGURE SUCCESS:\n$res');
  //   } on PlatformException catch (e) {
  //     setState(() => _log = 'CONFIGURE ERROR [${e.code}]: ${e.message}\n${e.details}');
  //   } catch (e) {
  //     setState(() => _log = 'CONFIGURE UNKNOWN ERROR: $e');
  //   }
  // }

    /// Saves a donation record after a payment attempt.
  /// [donatedAmount] is in OMR (e.g., 0.500, 1.000).
  void _donate(double donatedAmount, String receipt) {
    Map<String, dynamic>? receiptMap;
    try {
      final decoded = json.decode(receipt);
      if (decoded is Map<String, dynamic>) {
        receiptMap = decoded;
      } else if (decoded is Map) {
        receiptMap = Map<String, dynamic>.from(decoded);
      } else {
        receiptMap = {'raw': receipt};
      }
    } catch (_) {
      receiptMap = {'raw': receipt};
    }

    final statusRaw = (receiptMap['status'] ??
            receiptMap['result'] ??
            receiptMap['Status'] ??
            receiptMap['paymentStatus'] ??
            receiptMap['payment_status'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();

    final errorValue = (receiptMap['error'] ??
            receiptMap['errorMessage'] ??
            receiptMap['error_message'])
        ?.toString()
        .trim();
    final messageValue = (receiptMap['message'] ??
            receiptMap['paymentDescription'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    final hasFailureMessage = messageValue.contains('fail') ||
        messageValue.contains('error') ||
        messageValue.contains('declin') ||
        messageValue.contains('cancel');
    final hasReceiptError = errorValue != null &&
        errorValue.isNotEmpty &&
        errorValue.toLowerCase() != 'null';

    final donationStatus =
        (statusRaw.isNotEmpty && statusRaw != 'success') ||
                hasReceiptError ||
                hasFailureMessage
            ? 'FAILED'
            : 'SUCCESS';

    // Reuse the existing Sadaqah flow (location + backend save + dialogs)
    _donates(null, donatedAmount, receiptMap, donationStatus);
  }

  /// Mosambee payment then donate.
  /// Pass [amt] in OMR (e.g., 0.100, 0.500, 1.000).
 Future<void> _payAndDonate(num amt) async {
  if (_isPaying) return;
  setState(() => _isPaying = true);

  final mosambee = ref.read(mosambeeProvider);

  String? result;
  double paidOmr = amt.toDouble();

  try {
    // This returns a String (usually JSON). Even if Mosambee returns a failed/cancelled
    // payload, we still want to forward it to the backend via `_donate`.
    result = await mosambee.loginAndPay(amt.toDouble());

    // No response at all (invoke failed / activity cancelled without data)
    if (result == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mosambee login/payment failed')),
        );
      }
      return;
    }

    final trimmed = result.trim();

    // Try to parse JSON so we can extract the paid amount (if any).
    Map<String, dynamic>? map;
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map) {
        map = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      map = null;
    }

    if (map != null) {
      // Prefer the amount returned by the gateway (if any), otherwise fallback
      // to what we requested.
      final dynamic amountValue = map['amount'] ??
          map['paidAmount'] ??
          map['paid_amount'] ??
          map['txnAmount'] ??
          map['txn_amount'];

      final parsed = double.tryParse(amountValue?.toString() ?? '');
      if (parsed != null) {
        // If the gateway returns baisa, convert to OMR; otherwise keep as-is.
        paidOmr = parsed > _omrSteps.last ? (parsed / 1000.0) : parsed;
      }
    }

    // ✅ Always forward whatever we got (success / failed / cancelled / non-JSON)
    // so the backend has the full receipt/payload.
    _donate(paidOmr, trimmed);

    // Optional: still show a message to user when Mosambee indicates failure/cancel.
    final statusRaw = (map?['status'] ??
            map?['result'] ??
            map?['Status'] ??
            map?['paymentStatus'] ??
            map?['payment_status'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();

    if (statusRaw.isNotEmpty && statusRaw != 'success') {
      final msg = (map?['paymentDescription'] ??
              map?['message'] ??
              'Payment not successful')
          .toString();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } else if (trimmed.isEmpty || trimmed == 'No receipt') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment cancelled or no receipt')),
        );
      }
    }
  } catch (e) {
    // Show error dialog immediately
    if (mounted) {
      final errorMsg = e.toString().replaceFirst('Exception: ', '');
      _showResultDialog(
        success: false,
        omrAmount: paidOmr,
        errorMessage: errorMsg.isNotEmpty ? errorMsg : 'An error occurred during payment',
      );
    }
    
    // ✅ Still forward what we have to backend to track the error
    final receipt = result ?? jsonEncode({'error': e.toString()});
    
    // Parse receipt to determine status
    Map<String, dynamic>? receiptMap;
    try {
      final decoded = json.decode(receipt);
      if (decoded is Map) {
        receiptMap = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      receiptMap = {'raw': receipt, 'error': e.toString()};
    }
    
    // Call _donates directly with FAILED status to track error (skip dialog since we already showed it)
    _donates(null, paidOmr, receiptMap, 'FAILED', showDialog: false);
    
    // Reset controls after error
    _resetAmountControls();
  } finally {
    if (mounted) setState(() => _isPaying = false);
  }
}

  // void _jumpToOmr(double omr) {
  //   final idx = _omrSteps.indexOf(omr);
  //   if (idx != -1) setState(() => _stepIndex = idx);
  // }

  @override
  void dispose() {
    _sparkleCtrl.dispose();
    _pulseCtrl.dispose(); // NEW
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = const Color(0xFF1B1C1F);
    final screen = MediaQuery.of(context).size;
    final screenHeight = screen.height;
    final screenWidth = screen.width;
    
    // Use screen dimensions directly to fill the screen
    // Base sizes are designed for 800x1280, but scale up/down to fill any screen
    final baseWidth = 800.0;
    final baseHeight = 1280.0;
    
    // Scale factor - use the larger of width/height scaling to ensure we fill the screen
    final widthScale = screenWidth / baseWidth;
    final heightScale = screenHeight / baseHeight;
    final scaleFactor = math.max(widthScale, heightScale);
    
    // Responsive sizes - scale up to fill screen
    final logoHeight = 60 * scaleFactor;
    final quickCircleDiameter = screenWidth * 0.30; // 25% of screen width
    final centerDialDiameter = screenWidth * 0.45; // 35% of screen width
    final titleFontSize = screenHeight * 0.03; // 3% of screen height
    final sponsorImageHeight = 50 * scaleFactor;
    final sponsorFontSize = screenHeight * 0.018; // 1.8% of screen height
    
    // Calculate slider height to fill available vertical space
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final safeAreaBottom = MediaQuery.of(context).padding.bottom;
    final availableHeight = screenHeight - safeAreaTop - safeAreaBottom;
    final sliderHeight = availableHeight * 0.7; // Use 70% of available height

    return Scaffold(
      backgroundColor: dark,
      body: SafeArea(
        child: Stack(
          children: [
            // radial green vignette
            Positioned.fill(
              child: Container(color: const Color.fromARGB(255, 48, 48, 47)),
            ),
            SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: screenHeight * 0.01),
                child: Column(
                  children: [
                    // Logo
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: screenWidth * 0.02,
                        vertical: screenHeight * 0.01,
                      ),
                      child: Image.asset(
                        'assets/brand/mithqallogo.png',
                        height: logoHeight,
                        fit: BoxFit.contain,
                      ),
                    ),
                    Divider(color: Colors.white.withOpacity(.15), height: 1),
                    SizedBox(height: screenHeight * 0.01),

                    // Title
                    Text(
                      'Sadaqah / صدقة',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .2,
                            fontSize: titleFontSize,
                          ),
                    ),
                    SizedBox(height: screenHeight * 0.015),

                    // Top quick 0.100
                    _QuickCircle(
                      diameter: quickCircleDiameter,
                      innerColor: const Color(0xFF1EF17F),
                      value: '5.000',
                      sub: 'OMR / ريال',
                      activeTextColor: Colors.black.withOpacity(.85),
                      onTap: () => _payAndDonate(5.000), // 5 OMR
                    ),

                    SizedBox(height: screenHeight * 0.02),

                    // Center dial — looks like Figma + discrete steps
                    _DialWithSparkles(
                      diameter: centerDialDiameter,
                      valueText: _amountLabel,
                      subtitle: _dialSubtitle,
                      dragging: _dragging,
                      sliderActive: _sliderActive,
                      progress: _sparkleCtrl.value,
                      pulse: _pulseCtrl.value,
                      showTapHint: _dialTapHintVisible,
                      onTap: _onDialTap,
                      onDragStart: _onDialDragStart,
                      onDragUpdate: (dy) {
                        _dragAccumulator += dy;
                        while (_dragAccumulator <= -_pixelsPerStep &&
                            _stepIndex < _maxIndex) {
                          _dragAccumulator += _pixelsPerStep;
                          _stepIndex++;
                        }
                        while (_dragAccumulator >= _pixelsPerStep &&
                            _stepIndex > _minIndex) {
                          _dragAccumulator -= _pixelsPerStep;
                          _stepIndex--;
                        }
                        setState(() {});
                      },
                      onDragEnd: _stopSparkles,
                    ),

                    SizedBox(height: screenHeight * 0.02),

                    // Bottom quick 1.000
                    _QuickCircle(
                      diameter: quickCircleDiameter,
                      innerColor: const Color(0xFF1EF17F),
                      value: '0.100',
                      sub: 'Baisa / بيسة',
                      activeTextColor: Colors.black.withOpacity(.85),
                      onTap: () => _payAndDonate(0.100), // 100 baisa
                    ),

                  ],
                ),
              ),
            ),

            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: screenWidth * 0.09),
                child: SizedBox(
                  height: sliderHeight,
                  width: screenWidth * 0.12,
                  child: _AmountSlider(
                    minIndex: _minIndex,
                    maxIndex: _maxIndex,
                    currentIndex: _stepIndex,
                    onIndexChanged: (newIndex) {
                      setState(() {
                        _stepIndex = newIndex.clamp(_minIndex, _maxIndex);
                      });
                    },
                    onSlideStart: _onSliderStart,
                    onSlideEnd: _onSliderEnd,
                    showHint: _sliderHintVisible,
                  ),
                ),
              ),
            ),

            // Sponsors section at the bottom
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  screenWidth * 0.02, 
                  screenHeight * 0.015, 
                  screenWidth * 0.02, 
                  screenHeight * 0.02
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: const Color.fromARGB(255, 255, 255, 255).withOpacity(0.15),
                      width: screenHeight * 0.003,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/sponsors/sirajlogo.png',
                      height: sponsorImageHeight,
                    ),
                    const Spacer(),
                    Text(
                      'Powered by',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(
                            color: Colors.white.withOpacity(.9),
                            fontWeight: FontWeight.w600,
                            fontSize: sponsorFontSize,
                          ),
                    ),
                    const Spacer(),
                    Image.asset(
                      'assets/brand/mithqallogo.png',
                      height: sponsorImageHeight,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ----------------- WIDGETS -----------------

// Top/bottom quick amount circle with crisp ring + soft glow (as before)
class _QuickCircle extends StatelessWidget {
  final double diameter;
  final Color innerColor;
  final String value;
  final String sub;
  final Color activeTextColor;
  final VoidCallback onTap;

  const _QuickCircle({
    required this.diameter,
    required this.innerColor,
    required this.value,
    required this.sub,
    required this.activeTextColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // halo
            Container(
              width: diameter,
              height: diameter,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,

                gradient: LinearGradient(
                  colors: [Color(0xFF1EF17F), Color(0xFFC6A04E)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // Optional: Define stops for more precise control over color transitions
                  // stops: [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white30,
                    blurRadius: 22,
                    spreadRadius: 4,
                  ),
                  BoxShadow(
                    color: Colors.white10,
                    blurRadius: 44,
                    spreadRadius: 8,
                  ),
                ],
              ),
            ),
            // circle + ring
            Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1EF17F), Color(0xFFC6A04E)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // Optional: Define stops for more precise control over color transitions
                  // stops: [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0],
                ),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 6),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 16,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: activeTextColor,
                            fontWeight: FontWeight.w900,
                            fontSize: diameter * 0.22, // Responsive font size
                          ),
                    ),
                    const SizedBox(height: 0),
                    Text(
                      sub,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: activeTextColor.withOpacity(.8),
                        fontWeight: FontWeight.w700,
                        fontSize: diameter * 0.08, // Responsive font size
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialWithSparkles extends StatelessWidget {
  final double diameter;
  final String valueText;
  final String subtitle;

  final bool dragging; // dial dragging
  final bool sliderActive; // 👈 slider on the right is being used

  final double progress; // from _sparkleCtrl
  final double pulse; // from _pulseCtrl
  final bool showTapHint;

  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final void Function(double dy) onDragUpdate;
  final VoidCallback onDragEnd;

  const _DialWithSparkles({
    required this.diameter,
    required this.valueText,
    required this.subtitle,
    required this.dragging,
    required this.sliderActive, // 👈 add this
    required this.progress,
    required this.pulse,
    required this.showTapHint,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final scale = 0.96 + pulse * 0.04; // breathing

    final bool anyInteraction = sliderActive || dragging;

    final CustomPainter sparklePainter = anyInteraction
        ? _OldSparklePainter(
            progress: progress,
            active: true, // always draw when interacting
          )
        : _NewSparklePainter(
            progress: progress,
            active: false, // idle ripples only
          );

    return GestureDetector(
      onTap: onTap,
      onVerticalDragStart: (_) => onDragStart(),
      onVerticalDragUpdate: (d) => onDragUpdate(d.delta.dy),
      onVerticalDragEnd: (_) => onDragEnd(),
      child: Transform.scale(
        scale: scale,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // ✨ Sparkles behind the dial
              CustomPaint(size: Size.square(diameter), painter: sparklePainter),
              // White disk
              Container(
                width: diameter - 6,
                height: diameter - 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color.fromARGB(51, 255, 248, 248),
                      blurRadius: 28,
                      spreadRadius: 1,
                      offset: Offset(0, 14),
                    ),
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 56,
                      spreadRadius: 6,
                      offset: Offset(0, 20),
                    ),
                  ],
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color.fromARGB(255, 255, 255, 255),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.10),
                        blurRadius: 16,
                        spreadRadius: -4,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.4),
                        blurRadius: 22,
                        spreadRadius: 10,
                      ),
                    ],
                    border: Border.all(
                      color: const Color.fromARGB(
                        255,
                        129,
                        201,
                        133,
                      ).withOpacity(0.9),
                      width: 8,
                    ),
                  ),
                ),
              ),

              // Number + subtitle
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        valueText,
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(
                              color: Colors.black87,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.0,
                              fontSize: diameter * 0.24, // Responsive font size
                            ),
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.black.withOpacity(.75),
                              fontWeight: FontWeight.w700,
                              fontSize: diameter * 0.088, // Responsive font size
                            ),
                      ),
                    ],
                  ),
                ),
              ),

              // Up arrow
              Positioned(
                top: diameter * (0.04 + pulse * 0.01),
                left: 0,
                right: 0,
                child: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: diameter * 0.22, // Responsive icon size
                  color: Colors.black87,
                ),
              ),

              // Down arrow
              Positioned(
                bottom: diameter * (0.04 + pulse * 0.01),
                left: 0,
                right: 0,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: diameter * 0.22, // Responsive icon size
                  color: Colors.black87,
                ),
              ),

              // Tap hint in the middle
              if (showTapHint)
                Positioned(
                  bottom: diameter * 0.16,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: _TapPulse(pulse: pulse)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TapPulse extends StatelessWidget {
  final double pulse; // 0..1 from _pulseCtrl

  const _TapPulse({required this.pulse});

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final size = screen.width * 0.09; // 9% of screen width
    
    // Outer expanding ring
    final outerScale = 1.0 + pulse * 0.35;
    final outerOpacity = 0.7 * (1.0 - pulse);

    // Slight breathing for the inner circle
    final innerScale = 0.9 + pulse * 0.1;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Expanding ring
          Opacity(
            opacity: outerOpacity,
            child: Transform.scale(
              scale: outerScale,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.black.withOpacity(0.20),
                    width: 3,
                  ),
                ),
              ),
            ),
          ),

          // Dark inner circle (see-through a bit so number is still readable)
          Transform.scale(
            scale: innerScale,
            child: Container(
              width: size * 0.83,
              height: size * 0.83,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                shape: BoxShape.circle,
              ),
            ),
          ),

          // Finger icon
          Icon(Icons.touch_app_rounded, color: Colors.white, size: size * 0.43),
        ],
      ),
    );
  }
}

class _AmountSlider extends StatefulWidget {
  final int minIndex;
  final int maxIndex;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onSlideStart;
  final VoidCallback onSlideEnd;
  final bool showHint;

  const _AmountSlider({
    required this.minIndex,
    required this.maxIndex,
    required this.currentIndex,
    required this.onIndexChanged,
    required this.onSlideStart,
    required this.onSlideEnd,
    required this.showHint,
  });

  @override
  State<_AmountSlider> createState() => _AmountSliderState();
}

class _AmountSliderState extends State<_AmountSlider>
    with SingleTickerProviderStateMixin {
  double get _thumbSize {
    final screen = MediaQuery.of(context).size;
    // Scale thumb based on screen width
    return screen.width * 0.090; // 7.5% of screen width
  }
  
  double get _padding {
    final screen = MediaQuery.of(context).size;
    // Scale padding based on screen height
    return screen.height * 0.015; // 1.5% of screen height
  }

  // Animation: Loop continuously (0 -> 1 -> 0 -> 1)
  late final AnimationController _hintCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  bool _isDragging = false;

  @override
  void dispose() {
    _hintCtrl.dispose();
    super.dispose();
  }

  void _updateFromLocalOffset(Offset localPosition, double height) {
    final totalSteps = (widget.maxIndex - widget.minIndex).toDouble().clamp(
      1.0,
      double.infinity,
    );

    final double minCenter = _padding + _thumbSize / 2;
    final double maxCenter = height - _padding - _thumbSize / 2;
    final double centerRange = (maxCenter - minCenter).clamp(
      1.0,
      double.infinity,
    );

    final double y = localPosition.dy.clamp(minCenter, maxCenter);
    final double t = (maxCenter - y) / centerRange;

    final double newIndexDouble = widget.minIndex + t * totalSteps;
    final int newIndex = newIndexDouble.round().clamp(
      widget.minIndex,
      widget.maxIndex,
    );

    if (newIndex != widget.currentIndex) {
      widget.onIndexChanged(newIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double height = constraints.maxHeight;

        final double minCenter = _padding + _thumbSize / 2;
        final double maxCenter = height - _padding - _thumbSize / 2;
        final double centerRange = (maxCenter - minCenter).clamp(
          1.0,
          double.infinity,
        );

        final double totalSteps = (widget.maxIndex - widget.minIndex)
            .toDouble()
            .clamp(1.0, double.infinity);

        // Calculate thumb position
        final double t = (widget.currentIndex - widget.minIndex) / totalSteps;
        final double centerY = maxCenter - t * centerRange;

        final double trackTop = minCenter;
        final double trackHeight = centerRange;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (details) {
            _isDragging = true;
            widget.onSlideStart();
            setState(() {});
            _updateFromLocalOffset(details.localPosition, height);
          },
          onVerticalDragUpdate: (details) =>
              _updateFromLocalOffset(details.localPosition, height),
          onVerticalDragEnd: (_) {
            _isDragging = false;
            widget.onSlideEnd();
            setState(() {});
          },
          onVerticalDragCancel: () {
            _isDragging = false;
            widget.onSlideEnd();
            setState(() {});
          },
          onTapDown: (details) {
            _isDragging = true;
            widget.onSlideStart();
            setState(() {});
            _updateFromLocalOffset(details.localPosition, height);
          },
          onTapUp: (_) {
            _isDragging = false;
            widget.onSlideEnd();
            setState(() {});
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // --- Connector Line ---
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: EdgeInsets.only(right: MediaQuery.of(context).size.width * 0.045),
                  width: MediaQuery.of(context).size.width * 0.075,
                  height: MediaQuery.of(context).size.height * 0.005,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(1, -1.5),
                      end: Alignment(1.0, 1.5),
                      colors: [Color(0xFF1EF17F), Color(0xFFC6A04E)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),

              // --- Vertical Track ---
              Positioned(
                right: MediaQuery.of(context).size.width * 0.008,
                top: trackTop,
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.015,
                  height: trackHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1EF17F), Color(0xFFC6A04E)],
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black87,
                        blurRadius: 16,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                ),
              ),

              // --- Slider Thumb ---
              AnimatedPositioned(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutQuad,
                right: -_thumbSize / 4,
                top: centerY - _thumbSize / 2,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 120),
                  scale: _isDragging ? 1.08 : 1.0,
                  child: Container(
                    width: _thumbSize,
                    height: _thumbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF1EF17F), Color(0xFFC6A04E)],
                      ),
                      border: Border.all(
                        color: _isDragging
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFFEFEFEF),
                        width: 2.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 14,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // --- UPDATED ANIMATION: FINGER SLIDING UP ---
              if (widget.showHint)
                AnimatedBuilder(
                  animation: _hintCtrl,
                  // Make sure you still have the _HandCursor class I provided previously
                  child: const _HandCursor(),
                  builder: (context, child) {
                    // 1. Movement: Start below, move UP
                    final screen = MediaQuery.of(context).size;
                    final double slideDistance = screen.height * 0.04; // 4% of screen height
                    // Start positive Y (below thumb center)
                    final double startOffset = screen.height * 0.03; // 3% of screen height
                    // Subtracting as animation progresses moves it upwards (negative Y relative to start)
                    final double currentYOffset =
                        startOffset - (_hintCtrl.value * slideDistance);

                    // 2. Opacity: Fade in quickly at bottom, slide up, then fade out at top
                    double opacity = 1.0;
                    if (_hintCtrl.value < 0.2) {
                      // Fade In (0 to 1) at the start of movement
                      opacity = _hintCtrl.value * 5;
                    } else if (_hintCtrl.value > 0.7) {
                      // Fade Out towards the end of movement
                      opacity = 1.0 - ((_hintCtrl.value - 0.7) * 3.3);
                    }
                    opacity = opacity.clamp(0.0, 1.0);

                    // Base position is the center of the thumb
                    final double thumbBaseTop = centerY - _thumbSize / 2;

                    return Positioned(
                      right: -_thumbSize / 4,
                      top: thumbBaseTop + currentYOffset,
                      child: Opacity(opacity: opacity, child: child!),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HandCursor extends StatelessWidget {
  const _HandCursor();

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final iconSize = screen.width * 0.07; // 5% of screen width
    
    // Rotated slightly to look natural like the image
    return Transform.rotate(
      angle: -0.2,
      child: SizedBox(
        width: iconSize,
        height: iconSize,
        child: Stack(
          children: [
            // 1. The Shadow/Outline (Black)
            Positioned(
              top: screen.width * 0.0025,
              left: screen.width * 0.0025,
              child: Icon(
                Icons.touch_app_rounded,
                size: iconSize * 0.95,
                color: Colors.black.withOpacity(0.5),
              ),
            ),
            // 2. The Outline/Border (Black stroke effect)
            Positioned(
              top: screen.width * 0.00200,
              left: 0,
              child: Icon(
                Icons.touch_app_rounded,
                size: iconSize * 0.95,
                color: Colors.black,
              ),
            ),
            // 3. The Main Hand (White)
            Positioned(
              top: 0,
              left: 0,
              child: Icon(
                Icons.touch_app_rounded,
                size: iconSize * 0.9, // Slightly smaller to reveal black border
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Old ring-style sparkle painter (used when the **slider is active**)
class _OldSparklePainter extends CustomPainter {
  final double progress;
  final bool active;

  _OldSparklePainter({required this.progress, required this.active});

  final math.Random _rng = math.Random(11);

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;

    final center = Offset(size.width / 2, size.height / 2);
    final baseR = size.shortestSide * 0.47;
    final paint = Paint()..style = PaintingStyle.fill;

    for (int ring = 0; ring < 5; ring++) {
      final count = 26 + ring * 6;
      final ringR = baseR + ring * 10 + progress * 12;

      for (int i = 0; i < count; i++) {
        final theta = (i / count) * 2 * math.pi + progress * (1.6 + ring * 0.3);

        final jitter = (_rng.nextDouble() - .5) * 3.2;
        final pos =
            center +
            Offset(math.cos(theta), math.sin(theta)) * (ringR + jitter);

        final radius = 1.3 + _rng.nextDouble() * (ring == 0 ? 1.7 : 1.2);
        final alpha = (0.95 - ring * 0.14).clamp(0.0, 0.95);

        paint.color = const Color(
          0xFFFFFFFF,
        ).withOpacity(alpha * (0.6 + 0.4 * progress));

        canvas.drawCircle(pos, radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OldSparklePainter old) =>
      old.progress != progress || old.active != active;
}

/// New water-splash style sparkle painter (used when slider is **idle**)
class _NewSparklePainter extends CustomPainter {
  final double progress; // 0..1
  final bool active;

  _NewSparklePainter({required this.progress, required this.active});

  final math.Random _rng = math.Random(11);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final double baseR = (size.shortestSide / 2) + 6;

    final int dropletCount = active ? 55 : 30; // a bit more when active
    final double maxSpread = size.shortestSide * 0.20;

    final Color dropletColor = const Color(0xFF4FC3F7);
    final double baseAlpha = active ? 0.85 : 0.55;

    final Paint dropletPaint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < dropletCount; i++) {
      final double phase = (progress + i * 0.03) % 1.0;
      final double radius = baseR + phase * maxSpread;
      final double angle = _rng.nextDouble() * 2 * math.pi;

      final Offset pos =
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);

      final double dropletRadius = 2.0 + phase * 2.3;
      final double opacity = (1.0 - phase) * baseAlpha;

      dropletPaint.color = dropletColor.withOpacity(opacity);
      canvas.drawCircle(pos, dropletRadius, dropletPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NewSparklePainter old) =>
      old.progress != progress || old.active != active;
}