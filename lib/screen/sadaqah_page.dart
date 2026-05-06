import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../models/donation.dart';
import '../providers/donation_providers.dart';
import '../providers/mosambee_provider.dart';
import '../services/local_storage_service.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';

const String donationSuccessVideoAsset = 'assets/videos/boy_thankyou.mp4';
const bool donationSuccessVideoMuted = true;
const Size donationSuccessVideoFallbackSize = Size(1200, 1920);

bool shouldPlayDonationSuccessVideo(String? status) =>
    (status ?? '').trim().toUpperCase() == 'SUCCESS';

bool shouldShowDonationSaveLoading({
  required bool videoFinished,
  required bool donationSaveFinished,
}) => videoFinished && !donationSaveFinished;

bool isDonationCompletionPending({
  required bool videoFinished,
  required bool donationSaveFinished,
}) => !videoFinished || !donationSaveFinished;

class DonationSuccessVideoDialog extends StatefulWidget {
  final String assetPath;
  final VoidCallback? onFinished;

  const DonationSuccessVideoDialog({
    super.key,
    this.assetPath = donationSuccessVideoAsset,
    this.onFinished,
  });

  @override
  State<DonationSuccessVideoDialog> createState() =>
      _DonationSuccessVideoDialogState();
}

class _DonationSuccessVideoDialogState
    extends State<DonationSuccessVideoDialog> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  bool _failed = false;
  bool _finishing = false;
  Timer? _fallbackFinishTimer;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset(widget.assetPath)
      ..setLooping(false)
      ..addListener(_handleVideoTick);
    _initializeAndPlay();
  }

  Future<void> _initializeAndPlay() async {
    try {
      await _controller.initialize();
      if (donationSuccessVideoMuted) {
        await _controller.setVolume(0);
      }
      if (!mounted) return;
      setState(() => _initialized = true);
      await _controller.play();
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
      _scheduleFallbackFinish();
    }
  }

  void _handleVideoTick() {
    if (_finishing || !_controller.value.isInitialized) return;
    if (_controller.value.hasError) {
      setState(() => _failed = true);
      _scheduleFallbackFinish();
      return;
    }

    final duration = _controller.value.duration;
    if (duration == Duration.zero) return;
    final remaining = duration - _controller.value.position;
    if (remaining <= const Duration(milliseconds: 160)) {
      _finish();
    }
  }

  void _scheduleFallbackFinish() {
    _fallbackFinishTimer?.cancel();
    _fallbackFinishTimer = Timer(const Duration(milliseconds: 1800), _finish);
  }

  void _finish() {
    if (_finishing) return;
    _finishing = true;
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _fallbackFinishTimer?.cancel();
    _controller.removeListener(_handleVideoTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: SizedBox.expand(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: _initialized && !_failed
              ? _FullScreenVideo(controller: _controller)
              : const _DonationVideoFallback(),
        ),
      ),
    );
  }
}

class _FullScreenVideo extends StatelessWidget {
  final VideoPlayerController controller;

  const _FullScreenVideo({required this.controller});

  @override
  Widget build(BuildContext context) {
    final videoSize = controller.value.size;
    final width = videoSize.width > 0
        ? videoSize.width
        : donationSuccessVideoFallbackSize.width;
    final height = videoSize.height > 0
        ? videoSize.height
        : donationSuccessVideoFallbackSize.height;

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: width,
          height: height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _DonationVideoFallback extends StatelessWidget {
  const _DonationVideoFallback();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1EF17F)),
      ),
    );
  }
}

class DonationFinalizingDialog extends StatelessWidget {
  const DonationFinalizingDialog({super.key});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1EF17F);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF202126),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.44),
              blurRadius: 30,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 54,
              height: 54,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(green),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Finalizing donation',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '\u062c\u0627\u0631\u064a \u062d\u0641\u0638 \u0627\u0644\u062a\u0628\u0631\u0639',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PaymentLoadingDialog extends StatefulWidget {
  const PaymentLoadingDialog({super.key});

  @override
  State<PaymentLoadingDialog> createState() => _PaymentLoadingDialogState();
}

class _PaymentLoadingDialogState extends State<PaymentLoadingDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accentGreen = Color(0xFF1EF17F);
    const accentGold = Color(0xFFC6A04E);
    const panel = Color(0xFF202126);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 310,
        padding: const EdgeInsets.all(1.4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.24),
              accentGreen.withValues(alpha: 0.72),
              accentGold.withValues(alpha: 0.66),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.46),
              blurRadius: 34,
              offset: const Offset(0, 18),
            ),
            BoxShadow(
              color: accentGreen.withValues(alpha: 0.16),
              blurRadius: 44,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 106,
                height: 106,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: _controller.value * math.pi * 2,
                          child: child,
                        );
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(
                            colors: [
                              accentGreen.withValues(alpha: 0),
                              accentGreen,
                              accentGold,
                              accentGreen.withValues(alpha: 0),
                            ],
                            stops: const [0.0, 0.28, 0.66, 1.0],
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF292B31),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.credit_card_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                    const SizedBox(
                      width: 106,
                      height: 106,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Loading to payment',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '\u062c\u0627\u0631\u064a \u0627\u0644\u062a\u062d\u0648\u064a\u0644 \u0625\u0644\u0649 \u0627\u0644\u062f\u0641\u0639',
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                height: 4,
                width: 142,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: const LinearGradient(
                    colors: [accentGreen, accentGold],
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

class DonationResultDialog extends StatefulWidget {
  final bool success;
  final double omrAmount;
  final String? errorMessage;
  final VoidCallback? onClose;

  const DonationResultDialog({
    super.key,
    required this.success,
    required this.omrAmount,
    this.errorMessage,
    this.onClose,
  });

  @override
  State<DonationResultDialog> createState() => _DonationResultDialogState();
}

class _DonationResultDialogState extends State<DonationResultDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1EF17F);
    const gold = Color(0xFFC6A04E);
    const red = Color(0xFFFF6B6B);
    const panel = Color(0xFF1E1F23);

    final isSuccess = widget.success;
    final accent = isSuccess ? green : red;
    final icon = isSuccess
        ? Icons.volunteer_activism_rounded
        : Icons.info_rounded;
    final title = isSuccess ? 'Sadaqah received' : 'Payment not completed';
    final arabicTitle = isSuccess
        ? '\u062a\u0645 \u0627\u0633\u062a\u0644\u0627\u0645 \u0635\u062f\u0642\u062a\u0643'
        : '\u0644\u0645 \u062a\u0643\u062a\u0645\u0644 \u0639\u0645\u0644\u064a\u0629 \u0627\u0644\u062f\u0641\u0639';
    final message = isSuccess
        ? 'May it be accepted and multiplied in goodness.'
        : 'No donation was recorded. Please try again when ready.';
    final arabicMessage = isSuccess
        ? '\u0646\u0633\u0623\u0644 \u0627\u0644\u0644\u0647 \u0623\u0646 \u064a\u062a\u0642\u0628\u0644\u0647\u0627 \u0648\u064a\u0636\u0627\u0639\u0641 \u0623\u062c\u0631\u0647\u0627'
        : '\u0644\u0645 \u064a\u062a\u0645 \u062a\u0633\u062c\u064a\u0644 \u0623\u064a \u062a\u0628\u0631\u0639. \u064a\u0631\u062c\u0649 \u0627\u0644\u0645\u062d\u0627\u0648\u0644\u0629 \u0645\u0631\u0629 \u0623\u062e\u0631\u0649.';
    final closeText = isSuccess
        ? 'Done / \u062a\u0645'
        : 'Close / \u0625\u063a\u0644\u0627\u0642';
    final details = widget.errorMessage?.trim();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 330,
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(1.4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.20),
              accent.withValues(alpha: 0.72),
              gold.withValues(alpha: isSuccess ? 0.76 : 0.36),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.52),
              blurRadius: 38,
              offset: const Offset(0, 20),
            ),
            BoxShadow(
              color: accent.withValues(alpha: 0.16),
              blurRadius: 42,
              spreadRadius: 3,
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(28),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 92,
                  height: 92,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final glow = 0.16 + (_controller.value * 0.10);
                      final scale = 0.96 + (_controller.value * 0.04);

                      return Transform.scale(
                        scale: scale,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                accent.withValues(alpha: 0.32),
                                accent.withValues(alpha: glow),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.56, 1.0],
                            ),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isSuccess
                                ? const [green, gold]
                                : const [red, Color(0xFF9A2F43)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.28),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(icon, color: Colors.white, size: 36),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  arabicTitle,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                if (isSuccess) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: Colors.white.withValues(alpha: 0.08),
                      border: Border.all(color: green.withValues(alpha: 0.38)),
                    ),
                    child: Text(
                      'OMR ${widget.omrAmount.toStringAsFixed(3)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: 16,
                    height: 1.32,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  arabicMessage,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 15,
                    height: 1.32,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isSuccess && details != null && details.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Text(
                      details,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 13,
                        height: 1.32,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isSuccess ? green : Colors.white,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: widget.onClose,
                    child: Text(
                      closeText,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => const Center(child: PaymentLoadingDialog()),
    );
  }

  void _dismissLoadingDialog() {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void _showDonationSaveLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => const Center(child: DonationFinalizingDialog()),
    );
  }

  Future<void> _showDonationSuccessVideo() {
    if (!mounted) return Future<void>.value();

    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Donation success video',
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return DonationSuccessVideoDialog(
          onFinished: () {
            final navigator = Navigator.of(ctx, rootNavigator: true);
            if (navigator.canPop()) {
              navigator.pop();
            }
          },
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
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
      barrierColor: Colors.black.withValues(alpha: 0.72),
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
              child: DonationResultDialog(
                success: success,
                omrAmount: omrAmount,
                errorMessage: errorMessage,
                onClose: () => Navigator.of(ctx).pop(),
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
    final isSuccess = shouldPlayDonationSuccessVideo(status);
    var loadingShown = false;

    if (showDialog && !isSuccess) {
      _showLoadingDialog();
      loadingShown = true;
    }

    try {
      if (showDialog && isSuccess) {
        var videoFinished = false;
        var donationSaveFinished = false;
        Object? saveError;
        StackTrace? saveStackTrace;

        final saveFuture = ref
            .read(donationsProvider.notifier)
            .addDonation(ref, newDonation)
            .catchError((Object error, StackTrace stackTrace) {
              saveError = error;
              saveStackTrace = stackTrace;
            })
            .whenComplete(() => donationSaveFinished = true);

        final videoFuture = _showDonationSuccessVideo().whenComplete(
          () => videoFinished = true,
        );

        await videoFuture;

        if (!mounted) return;

        if (shouldShowDonationSaveLoading(
          videoFinished: videoFinished,
          donationSaveFinished: donationSaveFinished,
        )) {
          _showDonationSaveLoadingDialog();
          loadingShown = true;
        }

        await saveFuture;

        if (!mounted) return;

        if (loadingShown) {
          _dismissLoadingDialog();
          loadingShown = false;
        }

        if (saveError != null) {
          Error.throwWithStackTrace(saveError!, saveStackTrace!);
        }

        _resetAmountControls();
        return;
      }

      await ref.read(donationsProvider.notifier).addDonation(ref, newDonation);

      if (!mounted) return;

      // Close loading dialog if it was shown
      if (loadingShown) {
        _dismissLoadingDialog();
        loadingShown = false;
      }

      // Only show result dialog if showDialog is true
      if (showDialog) {
        // Only show success dialog if status is SUCCESS
        if (shouldPlayDonationSuccessVideo(status)) {
          _showDonationSuccessVideo();
          // ✅ reset slider + dial after success
          _resetAmountControls();
        } else {
          // Show error dialog for failed/cancelled payments
          _showResultDialog(
            success: false,
            omrAmount: omrAmount,
            errorMessage:
                receipt?['message']?.toString() ??
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
      if (loadingShown) {
        _dismissLoadingDialog();
        loadingShown = false;
      }

      final msg = error.toString().replaceFirst('Exception: ', '');

      debugPrint('msg: $msg');

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
  Future<void> _donate(double donatedAmount, String receipt) async {
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

    final statusRaw =
        (receiptMap['status'] ??
                receiptMap['result'] ??
                receiptMap['Status'] ??
                receiptMap['paymentStatus'] ??
                receiptMap['payment_status'] ??
                '')
            .toString()
            .trim()
            .toLowerCase();

    final errorValue =
        (receiptMap['error'] ??
                receiptMap['errorMessage'] ??
                receiptMap['error_message'])
            ?.toString()
            .trim();
    final messageValue =
        (receiptMap['message'] ?? receiptMap['paymentDescription'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    final hasFailureMessage =
        messageValue.contains('fail') ||
        messageValue.contains('error') ||
        messageValue.contains('declin') ||
        messageValue.contains('cancel');
    final hasReceiptError =
        errorValue != null &&
        errorValue.isNotEmpty &&
        errorValue.toLowerCase() != 'null';

    final donationStatus =
        (statusRaw.isNotEmpty && statusRaw != 'success') ||
            hasReceiptError ||
            hasFailureMessage
        ? 'FAILED'
        : 'SUCCESS';

    // Reuse the existing Sadaqah flow (location + backend save + dialogs)
    await _donates(null, donatedAmount, receiptMap, donationStatus);
  }

  /// Mosambee payment then donate.
  /// Pass [amt] in OMR (e.g., 0.100, 0.500, 1.000).
  Future<void> _payAndDonate(num amt) async {
    if (_isPaying) return;
    setState(() => _isPaying = true);

    final mosambee = ref.read(mosambeeProvider);

    String? result;
    double paidOmr = amt.toDouble();
    var paymentLoadingShown = false;

    try {
      if (mounted) {
        _showLoadingDialog();
        paymentLoadingShown = true;
      }

      // This returns a String (usually JSON). Even if Mosambee returns a failed/cancelled
      // payload, we still want to forward it to the backend via `_donate`.
      result = await mosambee.loginAndPay(amt.toDouble());

      if (paymentLoadingShown) {
        _dismissLoadingDialog();
        paymentLoadingShown = false;
      }

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
        final dynamic amountValue =
            map['amount'] ??
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
      await _donate(paidOmr, trimmed);

      // Optional: still show a message to user when Mosambee indicates failure/cancel.
      final statusRaw =
          (map?['status'] ??
                  map?['result'] ??
                  map?['Status'] ??
                  map?['paymentStatus'] ??
                  map?['payment_status'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase();

      if (statusRaw.isNotEmpty && statusRaw != 'success') {
        final msg =
            (map?['paymentDescription'] ??
                    map?['message'] ??
                    'Payment not successful')
                .toString();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
      } else if (trimmed.isEmpty || trimmed == 'No receipt') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Payment cancelled or no receipt')),
          );
        }
      }
    } catch (e) {
      if (paymentLoadingShown) {
        _dismissLoadingDialog();
        paymentLoadingShown = false;
      }

      // Show error dialog immediately
      if (mounted) {
        final errorMsg = e.toString().replaceFirst('Exception: ', '');
        _showResultDialog(
          success: false,
          omrAmount: paidOmr,
          errorMessage: errorMsg.isNotEmpty
              ? errorMsg
              : 'An error occurred during payment',
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
      await _donates(null, paidOmr, receiptMap, 'FAILED', showDialog: false);

      // Reset controls after error
      _resetAmountControls();
    } finally {
      if (paymentLoadingShown) {
        _dismissLoadingDialog();
      }
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
                    Divider(
                      color: Colors.white.withValues(alpha: .15),
                      height: 1,
                    ),
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
                      activeTextColor: Colors.black.withValues(alpha: .85),
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
                      activeTextColor: Colors.black.withValues(alpha: .85),
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
                  key: const ValueKey('sadaqah-amount-slider'),
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
                  screenHeight * 0.02,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: const Color.fromARGB(
                        255,
                        255,
                        255,
                        255,
                      ).withValues(alpha: 0.15),
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
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .9),
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
                        color: activeTextColor.withValues(alpha: .8),
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
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 16,
                        spreadRadius: -4,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.4),
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
                      ).withValues(alpha: 0.9),
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
                              color: Colors.black.withValues(alpha: .75),
                              fontWeight: FontWeight.w700,
                              fontSize:
                                  diameter * 0.088, // Responsive font size
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
                  child: IgnorePointer(
                    child: TapGestureHint(
                      progress: pulse,
                      size: diameter * 0.32,
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

const String slideGestureHintSemanticsLabel =
    'Slide up to choose donation amount';
const String tapGestureHintSemanticsLabel = 'Tap donation amount gesture hint';

double _unitInterval(double value) => value.clamp(0.0, 1.0).toDouble();

double _fadeInOut(
  double value, {
  double fadeInEnd = 0.18,
  double fadeOutStart = 0.72,
}) {
  final v = _unitInterval(value);
  if (v < fadeInEnd) {
    return Curves.easeOutCubic.transform(_unitInterval(v / fadeInEnd));
  }
  if (v > fadeOutStart) {
    return Curves.easeInCubic.transform(
      _unitInterval((1 - v) / (1 - fadeOutStart)),
    );
  }
  return 1;
}

double slideGestureWaveOpacity(double progress) {
  final t = _unitInterval(progress);
  if (t < 0.08) {
    return Curves.easeOutCubic.transform(t / 0.08) * 0.88;
  }
  if (t < 0.68) return 1;
  if (t >= 0.88) return 0;

  return Curves.easeInCubic.transform((0.88 - t) / 0.20);
}

class TapGestureHint extends StatelessWidget {
  final double progress;
  final double size;

  const TapGestureHint({super.key, required this.progress, this.size = 92});

  @override
  Widget build(BuildContext context) {
    final t = _unitInterval(progress);
    final firstPulse = Curves.easeOutCubic.transform(t);
    final secondPulse = Curves.easeOutCubic.transform((t + 0.48) % 1.0);
    final press = math.sin(t * math.pi);
    const green = Color(0xFF1EF17F);
    const gold = Color(0xFFC6A04E);

    return Semantics(
      label: tapGestureHintSemanticsLabel,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              _GesturePulseRing(
                size: size * 0.82,
                scale: 0.78 + firstPulse * 0.42,
                opacity: (1 - firstPulse) * 0.62,
                color: green,
                width: 2.8,
              ),
              _GesturePulseRing(
                size: size * 0.7,
                scale: 0.82 + secondPulse * 0.46,
                opacity: (1 - secondPulse) * 0.34,
                color: gold,
                width: 2.2,
              ),
              Transform.scale(
                scale: 0.96 + press * 0.05,
                child: Container(
                  width: size * 0.64,
                  height: size * 0.64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.34),
                        Colors.black.withValues(alpha: 0.64),
                      ],
                      stops: const [0.0, 1.0],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.34),
                      width: 1.4,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: green.withValues(alpha: 0.28),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 14,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: size * 0.08,
                right: size * 0.12,
                child: TapGestureClickFeedback(
                  progress: t,
                  size: size * 0.44,
                  color: gold,
                ),
              ),
              _GestureHandMark(
                progress: t,
                size: size * 0.56,
                tilt: -0.08,
                glowColor: green,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SlideGestureHint extends StatelessWidget {
  final double progress;
  final double size;

  const SlideGestureHint({super.key, required this.progress, this.size = 76});

  @override
  Widget build(BuildContext context) {
    final t = _unitInterval(progress);
    final lift = Curves.easeInOutCubic.transform(t);
    final press = math.sin(t * math.pi);
    final waveOpacity = slideGestureWaveOpacity(t);
    const green = Color(0xFF1EF17F);
    const gold = Color(0xFFC6A04E);

    return Semantics(
      label: slideGestureHintSemanticsLabel,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size * 1.2,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              SlideGestureMotionWave(progress: t, size: size),
              Positioned(
                top: size * 0.1,
                left: size * 0.45,
                child: Opacity(
                  opacity: waveOpacity * 0.72,
                  child: Container(
                    width: size * 0.13,
                    height: size * 0.62,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          green.withValues(alpha: 0.0),
                          green.withValues(alpha: 0.42),
                          gold.withValues(alpha: 0.58),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: green.withValues(alpha: 0.16),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _GestureTrailDrop(
                top: size * (0.13 - lift * 0.04),
                left: size * 0.4,
                size: size * 0.16,
                opacity: waveOpacity * (0.52 + press * 0.18),
                color: gold,
              ),
              _GestureTrailDrop(
                top: size * (0.28 - lift * 0.06),
                left: size * 0.58,
                size: size * 0.12,
                opacity: waveOpacity * (0.48 + (1 - press) * 0.14),
                color: green,
              ),
              _GestureTrailDrop(
                top: size * (0.43 - lift * 0.08),
                left: size * 0.35,
                size: size * 0.1,
                opacity: waveOpacity * 0.42,
                color: Colors.white,
              ),
              Align(
                alignment: const Alignment(0, 0.12),
                child: Transform.translate(
                  offset: Offset(0, -press * 5),
                  child: Transform.scale(
                    scale: 1 + press * 0.04,
                    child: _GestureHandMark(
                      progress: t,
                      size: size * 0.74,
                      tilt: -0.24,
                      glowColor: green,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: size * 0.22,
                right: size * 0.17,
                child: _GesturePulseRing(
                  size: size * 0.36,
                  scale: 0.78 + press * 0.28,
                  opacity: 0.25 + press * 0.32,
                  color: gold,
                  width: 1.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SlideGestureMotionWave extends StatelessWidget {
  final double progress;
  final double size;

  const SlideGestureMotionWave({
    super.key,
    required this.progress,
    this.size = 76,
  });

  @override
  Widget build(BuildContext context) {
    final opacity = slideGestureWaveOpacity(progress);

    return Opacity(
      opacity: opacity,
      child: CustomPaint(
        size: Size(size * 0.86, size * 1.12),
        painter: _SlideGestureMotionWavePainter(
          progress: _unitInterval(progress),
          intensity: opacity,
        ),
      ),
    );
  }
}

class TapGestureClickFeedback extends StatelessWidget {
  final double progress;
  final double size;
  final Color color;

  const TapGestureClickFeedback({
    super.key,
    required this.progress,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = _unitInterval(progress);
    final press = Curves.easeOutBack.transform(math.sin(t * math.pi).abs());
    final ripple = Curves.easeOutCubic.transform(t);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _GesturePulseRing(
            size: size * 0.86,
            scale: 0.76 + ripple * 0.34,
            opacity: (1 - ripple) * 0.5,
            color: color,
            width: 1.6,
          ),
          Transform.translate(
            offset: Offset(0, press * 2.8),
            child: Transform.scale(
              scaleX: 1.04,
              scaleY: 1 - press * 0.12,
              child: Container(
                width: size * 0.46,
                height: size * 0.24,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * 0.09),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.95),
                      color.withValues(alpha: 0.88),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 7,
                      offset: Offset(0, 2 + press * 2),
                    ),
                    BoxShadow(
                      color: color.withValues(alpha: 0.38),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: size * 0.12,
            right: size * 0.16,
            child: Container(
              width: size * 0.16,
              height: size * 0.16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFF5B1).withValues(alpha: 0.95),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.58),
                    blurRadius: 9,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideGestureMotionWavePainter extends CustomPainter {
  final double progress;
  final double intensity;

  const _SlideGestureMotionWavePainter({
    required this.progress,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0.01) return;

    const green = Color(0xFF1EF17F);
    const gold = Color(0xFFC6A04E);
    const cyan = Color(0xFF78E7FF);
    final base = Offset(size.width * 0.5, size.height * 0.86);
    final lift = Curves.easeInOutCubic.transform(progress);
    final travel = size.height * (0.62 * lift);

    for (int i = 0; i < 4; i++) {
      final phase = _unitInterval(progress - i * 0.08);
      final localOpacity =
          _fadeInOut(phase, fadeInEnd: 0.08, fadeOutStart: 0.64) * intensity;
      if (localOpacity <= 0.01) continue;

      final vertical = travel * (0.52 + i * 0.12);
      final sway = math.sin((phase + i * 0.2) * math.pi * 2) * size.width * 0.1;
      final end = Offset(
        size.width * (0.5 + (i - 1.5) * 0.08),
        base.dy - vertical,
      );
      final control = Offset(
        size.width * (0.18 + i * 0.18) + sway,
        base.dy - vertical * 0.55,
      );

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4.2 - i * 0.55
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            green.withValues(alpha: localOpacity * 0.0),
            cyan.withValues(alpha: localOpacity * 0.58),
            gold.withValues(alpha: localOpacity * 0.82),
          ],
        ).createShader(Offset.zero & size);

      final path = Path()
        ..moveTo(base.dx + (i - 1) * size.width * 0.05, base.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);

      final dropPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.white.withValues(alpha: localOpacity * 0.74);
      canvas.drawCircle(end, 2.6 + i * 0.25, dropPaint);
    }

    for (int ring = 0; ring < 3; ring++) {
      final ringProgress = _unitInterval(progress * 1.12 - ring * 0.12);
      final ringOpacity =
          _fadeInOut(ringProgress, fadeInEnd: 0.05, fadeOutStart: 0.55) *
          intensity;
      if (ringOpacity <= 0.01) continue;

      final radius = size.width * (0.16 + ringProgress * 0.32);
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 - ring * 0.35
        ..color = cyan.withValues(alpha: ringOpacity * 0.42);

      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(base.dx, base.dy - travel * 0.2),
          width: radius * 1.42,
          height: radius * 0.72,
        ),
        ringPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SlideGestureMotionWavePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.intensity != intensity;
}

class _GesturePulseRing extends StatelessWidget {
  final double size;
  final double scale;
  final double opacity;
  final Color color;
  final double width;

  const _GesturePulseRing({
    required this.size,
    required this.scale,
    required this.opacity,
    required this.color,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _unitInterval(opacity),
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withValues(alpha: 0.64),
              width: width,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.18),
                blurRadius: 16,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GestureTrailDrop extends StatelessWidget {
  final double top;
  final double left;
  final double size;
  final double opacity;
  final Color color;

  const _GestureTrailDrop({
    required this.top,
    required this.left,
    required this.size,
    required this.opacity,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      child: Opacity(
        opacity: _unitInterval(opacity),
        child: Transform.rotate(
          angle: -0.72,
          child: Container(
            width: size * 0.72,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(size),
                topRight: Radius.circular(size),
                bottomLeft: Radius.circular(size),
                bottomRight: Radius.circular(size * 0.26),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.86),
                  color.withValues(alpha: 0.78),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.18),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GestureHandMark extends StatelessWidget {
  final double progress;
  final double size;
  final double tilt;
  final Color glowColor;

  const _GestureHandMark({
    required this.progress,
    required this.size,
    required this.tilt,
    required this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final wobble = math.sin(progress * math.pi * 2) * 0.035;
    final iconSize = size * 0.76;

    return Transform.rotate(
      angle: tilt + wobble,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size * 0.96,
              height: size * 0.96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    glowColor.withValues(alpha: 0.28),
                    glowColor.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, 0.72),
              child: Container(
                width: size * 0.48,
                height: size * 0.13,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.26),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            for (final offset in const [
              Offset(1.8, 2.0),
              Offset(-1.2, 1.1),
              Offset(1.2, -0.8),
            ])
              Transform.translate(
                offset: offset,
                child: Icon(
                  Icons.touch_app_rounded,
                  size: iconSize + 3,
                  color: Colors.black.withValues(alpha: 0.88),
                ),
              ),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Color(0xFFE7FFF0)],
              ).createShader(bounds),
              child: Icon(
                Icons.touch_app_rounded,
                size: iconSize,
                color: Colors.white,
              ),
            ),
            Positioned(
              top: size * 0.18,
              right: size * 0.23,
              child: Container(
                width: size * 0.09,
                height: size * 0.09,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFF5B1).withValues(alpha: 0.92),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFC6A04E).withValues(alpha: 0.52),
                      blurRadius: 9,
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
                  margin: EdgeInsets.only(
                    right: MediaQuery.of(context).size.width * 0.045,
                  ),
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
                    key: const ValueKey('sadaqah-slider-thumb'),
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

              if (widget.showHint)
                AnimatedBuilder(
                  animation: _hintCtrl,
                  builder: (context, child) {
                    final easedProgress = Curves.easeInOutCubic.transform(
                      _hintCtrl.value,
                    );
                    final slideHintSize = math.max(_thumbSize * 1.06, 76.0);
                    final slideHintHeight = slideHintSize * 1.2;
                    final slideDistance = math.max(_thumbSize * 1.32, 88.0);
                    final startOffset = (_thumbSize - slideHintHeight) / 2;
                    final double currentYOffset =
                        startOffset - (easedProgress * slideDistance);
                    final baseOpacity = _fadeInOut(
                      _hintCtrl.value,
                      fadeInEnd: 0.14,
                      fadeOutStart: 0.76,
                    );
                    final opacity = _hintCtrl.value < 0.16
                        ? 0.48 + baseOpacity * 0.52
                        : baseOpacity;
                    final double thumbBaseTop = centerY - _thumbSize / 2;
                    final hintRight =
                        -_thumbSize / 4 + (_thumbSize - slideHintSize) / 2;

                    return Positioned(
                      right: hintRight,
                      top: thumbBaseTop + currentYOffset,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: opacity,
                          child: SlideGestureHint(
                            key: const ValueKey('sadaqah-slide-gesture-hint'),
                            progress: _hintCtrl.value,
                            size: slideHintSize,
                          ),
                        ),
                      ),
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
        ).withValues(alpha: alpha * (0.6 + 0.4 * progress));

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

      dropletPaint.color = dropletColor.withValues(alpha: opacity);
      canvas.drawCircle(pos, dropletRadius, dropletPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NewSparklePainter old) =>
      old.progress != progress || old.active != active;
}
