import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

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
import '../services/api_donation.dart';

const String donationSuccessVideoAsset = 'assets/videos/boy_thankyou.mp4';
const bool donationSuccessVideoMuted = true;
const Size donationSuccessVideoFallbackSize = Size(1200, 1920);

/// The kiosk runs on fixed, low-RAM (~4GB) hardware. This single flag scales the
/// decorative animations' DENSITY (particle counts) and repaint CADENCE (fps)
/// down so they stay smooth while looking essentially the same. All the
/// structural perf fixes (offstage-under-video, image-cache cap, RepaintBoundary
/// placement) are unconditional — this flag ONLY trades a little density. Flip it
/// to false on a capable dev machine to preview full-density visuals.
const bool kLowEndDevice = true;

/// ~30fps repaint gate for the continuously-looping decorative painters. On the
/// kiosk we only repaint when the quantized progress bucket changes, halving the
/// per-frame paint work for drifts the eye can't tell apart from 60fps. [steps]
/// is roughly round(targetFps * controllerPeriodSeconds). Full rate off-kiosk.
bool decorRepaint(double oldP, double newP, int steps) => kLowEndDevice
    ? (oldP * steps).floor() != (newP * steps).floor()
    : oldP != newP;

bool shouldPlayDonationSuccessVideo(String? status) =>
    (status ?? '').trim().toUpperCase() == 'SUCCESS';

bool isPreparedMosambeeSessionResponse(String? response) {
  if (response == null || response.trim().isEmpty) return false;

  try {
    final decoded = json.decode(response);
    if (decoded is! Map) return false;

    final status = decoded['status']?.toString().trim().toLowerCase();
    final sessionReady = decoded['sessionReady'];

    return status == 'success' && sessionReady != false;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic>? mosambeeJsonMap(String? response) {
  if (response == null || response.trim().isEmpty) return null;

  try {
    final decoded = json.decode(response);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    return null;
  }

  return null;
}

bool isMosambeeSessionExpiredPaymentResponse(Map<String, dynamic>? response) {
  if (response == null) return false;

  final receiptResponse = response['receiptResponse'];
  final codes = <dynamic>[
    response['paymentResponseCode'],
    response['responseCode'],
    response['code'],
    if (receiptResponse is Map) receiptResponse['responseCode'],
  ];

  return codes.any((code) => code?.toString().trim() == '99');
}

String mosambeeSessionErrorMessage(String? response) {
  if (response == null || response.trim().isEmpty) {
    return 'Payment terminal is not ready. Please try again.';
  }

  try {
    final decoded = json.decode(response);
    if (decoded is Map) {
      return (decoded['message'] ??
              decoded['description'] ??
              decoded['paymentDescription'] ??
              decoded['error'] ??
              'Payment terminal is not ready. Please try again.')
          .toString();
    }
  } catch (_) {
    // Fall through to the default message.
  }

  return 'Payment terminal is not ready. Please try again.';
}

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
      if (mounted) {
        setState(() => _failed = true);
      }
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

    // SizedBox.expand re-imposes TIGHT screen-sized constraints. The parent
    // AnimatedSwitcher hands down LOOSE constraints (its internal Stack), under
    // which FittedBox(cover) degrades to contain and leaves black side bars.
    // With tight constraints, cover fills the full 1200x1920 — the 464x832 clip
    // scales to the width and only a little is cropped off the top/bottom.
    return SizedBox.expand(
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: width,
            height: height,
            child: VideoPlayer(controller),
          ),
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
              'جاري حفظ التبرع',
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
                'جاري التحويل إلى الدفع',
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
    final arabicTitle = isSuccess ? 'تم استلام صدقتك' : 'لم تكتمل عملية الدفع';
    final message = isSuccess
        ? 'May it be accepted and multiplied in goodness.'
        : 'No donation was recorded. Please try again when ready.';
    final arabicMessage = isSuccess
        ? 'نسأل الله أن يتقبلها ويضاعف أجرها'
        : 'لم يتم تسجيل أي تبرع. يرجى المحاولة مرة أخرى.';
    final closeText = isSuccess ? 'Done / تم' : 'Close / إغلاق';
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Donation options: 1..39 OMR, ascending up the slider.
  final List<double> _omrSteps = List<double>.generate(
    39,
    (i) => (i + 1).toDouble(),
  );

  static const int _defaultIndex = 0; // 1 OMR

  // Backed by a ValueNotifier so changing the amount rebuilds ONLY the dial +
  // slider (via ValueListenableBuilder), never the whole page — this is what
  // keeps sliding smooth (no full-page setState per drag frame).
  final ValueNotifier<int> _stepIndexVN = ValueNotifier<int>(_defaultIndex);
  int get _stepIndex => _stepIndexVN.value;
  set _stepIndex(int v) => _stepIndexVN.value = v.clamp(_minIndex, _maxIndex);
  bool _isPaying = false; // prevent double-tap + show loading
  // When false, ALL the page's decorative animations (fireflies, dial sparkles,
  // goal-bar shimmer, hints) are muted via TickerMode — used while the
  // full-screen success video plays so it isn't fighting them for the GPU.
  bool _animationsEnabled = true;
  bool _mosambeeSessionReady = false;
  bool _isPreparingMosambeeSession = false;
  Future<void>? _mosambeeSessionPrepareFuture;
  Timer? _mosambeeSessionRetryTimer;

  // Keeps the daily goal/total/count fresh on an always-on kiosk:
  //  - _midnightResetTimer fires just after local midnight so the goal bar
  //    visibly resets to 0 against the new day's target (re-armed each day).
  //  - _goalRefreshTimer is a slow safety-net poll (covers timer drift and
  //    picks up admin target / day-uplift changes mid-day without a restart).
  //  - the WidgetsBindingObserver resume hook re-syncs after the device wakes,
  //    since timers don't fire reliably while the app is suspended.
  Timer? _midnightResetTimer;
  Timer? _goalRefreshTimer;

  static const int _minIndex = 0;
  static const int _maxIndex = 38; // _omrSteps has 39 elements, indices 0..38

  bool _sliderActive = false;

  // Drag accumulation so 1 step ~ N px of vertical movement
  double _dragAccumulator = 0.0;
  static const double _pixelsPerStep = 20; // ~1 step per 20px of vertical drag

  // Drives the dial sparkles. Read via an AnimatedBuilder so only the dial
  // repaints each frame — NOT the whole page (with its blur effects).
  late final AnimationController _sparkleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  // Ambient yellow "firefly" dots drifting in the background. Isolated in a
  // RepaintBoundary + AnimatedBuilder so it never rebuilds the whole page.
  late final AnimationController _fireflyCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  bool _dragging = false;

  void _resetAmountControls() {
    if (!mounted) return;

    setState(() {
      _stepIndex = _defaultIndex; // back to the default amount (1 OMR)
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

  // THIS kiosk's successful-donation count today (per-kiosk, not global).
  // Shown in both top stat boxes (left English, right Arabic). Comes from the
  // per-kiosk endpoint via _loadGoal(). null = not loaded yet.
  int? _todayCount;

  // Per-kiosk daily goal: THIS kiosk's successful-donation total (OMR) today,
  // visualised as the growing branch on the left. The goal (5 OMR) is never
  // shown as a number — only the branch grows toward it.
  // Fallback used only until the API goal loads, or if a device has no target set.
  static const double kFallbackGoalOmr = 5.0;
  double _goalTotalOmr = 0.0;
  // Per-device daily goal from the API (the device's configured target x today's
  // day uplift). null until loaded / when the device has no configured target.
  double? _goalTargetOmr;
  double get _goalProgress {
    final target = _goalTargetOmr ?? kFallbackGoalOmr;
    if (target <= 0) return 0.0;
    return (_goalTotalOmr / target).clamp(0.0, 1.0).toDouble();
  }

  Future<void> _loadGoal() async {
    try {
      final kiosk = await LocalStorageService.getKioskNumber();
      if (kiosk == null || kiosk.trim().isEmpty) return;
      // Goal comes straight from the API per device (its configured target x
      // today's day uplift), alongside this kiosk's running total today.
      final goal = await ApiDonation().getKioskGoal(kiosk.trim());
      if (!mounted) return;
      setState(() {
        _goalTotalOmr = goal.total;
        _goalTargetOmr = goal.goal; // null -> falls back to kFallbackGoalOmr
        _todayCount = goal.count; // THIS kiosk's successful count today
      });
    } catch (_) {
      // Keep the last known value.
    }
  }

  // Called once a successful donation is recorded: optimistic update for
  // instant feedback (count +1, goal grows), then reconcile with the server.
  void _onDonationRecorded(double omrAmount) {
    if (mounted) {
      setState(() {
        _todayCount = (_todayCount ?? 0) + 1;
        _goalTotalOmr += omrAmount;
      });
    }
    unawaited(_loadGoal());
  }

  // Helpers
  double get _currentOmr => _omrSteps[_stepIndex.clamp(_minIndex, _maxIndex)];
  int get _currentBaisa => (_currentOmr * 1000).round();
  bool get _paymentControlsEnabled =>
      _mosambeeSessionReady && !_isPreparingMosambeeSession && !_isPaying;

  // Shown label: "0.100" for sub-Riyal amounts, otherwise the integer (1/2/5/10).
  String get _amountLabel {
    final omr = _currentOmr;
    if (omr < 1.0) return omr.toStringAsFixed(3); // 0.100
    return omr.toInt().toString();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Always run the water-ripple animation
    _sparkleCtrl.repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_primeMosambeeSession());
      unawaited(_loadGoal());
      _scheduleMidnightReset();
      _startGoalRefreshTimer();
    });
  }

  // Schedule a one-shot refresh just after the next LOCAL midnight, then re-arm
  // for the following day. The kiosks run on Asia/Muscat (device local time ==
  // the server's reset boundary), so local midnight is exactly when the API's
  // "today" donation window rolls over and the running total returns to 0.
  void _scheduleMidnightReset() {
    _midnightResetTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    // Small cushion so the server has definitely crossed into the new day
    // before we re-fetch (avoids reading yesterday's window at 23:59:59.x).
    final wait = nextMidnight.difference(now) + const Duration(seconds: 5);
    _midnightResetTimer = Timer(wait, () {
      if (!mounted) return;
      unawaited(_loadGoal());
      _scheduleMidnightReset(); // arm the next day
    });
  }

  // Slow safety-net poll: insures against timer drift on a long-running kiosk
  // and picks up admin target / day-uplift changes without needing a restart.
  void _startGoalRefreshTimer() {
    _goalRefreshTimer?.cancel();
    _goalRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!mounted) return;
      unawaited(_loadGoal());
    });
  }

  // When the kiosk app returns to the foreground (screen wake, relaunch) the
  // timers may have been frozen while suspended — re-sync immediately and
  // re-arm the midnight timer in case the device slept across midnight.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_loadGoal());
      _scheduleMidnightReset();
    }
  }

  Future<void> _primeMosambeeSession({bool force = false}) {
    if (_isPreparingMosambeeSession && _mosambeeSessionPrepareFuture != null) {
      return _mosambeeSessionPrepareFuture!;
    }
    if (_mosambeeSessionReady && !force) {
      return Future<void>.value();
    }

    final future = _prepareMosambeeSession();
    _mosambeeSessionPrepareFuture = future;
    return future.whenComplete(() => _mosambeeSessionPrepareFuture = null);
  }

  void _scheduleMosambeeSessionRetry() {
    _mosambeeSessionRetryTimer?.cancel();
    _mosambeeSessionRetryTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _mosambeeSessionReady) return;
      unawaited(_primeMosambeeSession(force: true));
    });
  }

  Future<void> _prepareMosambeeSession() async {
    if (mounted) {
      setState(() {
        _isPreparingMosambeeSession = true;
      });
    }

    final response = await ref.read(mosambeeProvider).prepareSession();
    final ready = isPreparedMosambeeSessionResponse(response);

    if (!mounted) return;
    setState(() {
      _mosambeeSessionReady = ready;
      _isPreparingMosambeeSession = false;
    });

    if (ready) {
      _mosambeeSessionRetryTimer?.cancel();
    } else {
      _scheduleMosambeeSessionRetry();
    }
  }

  Future<String?> _sendPreparedMosambeePayment(
    MosambeeService mosambee,
    double amount, {
    bool prepareNextAfterReturn = true,
  }) async {
    if (mounted) {
      setState(() => _mosambeeSessionReady = false);
    } else {
      _mosambeeSessionReady = false;
    }

    final paymentResult = await mosambee.payWithPreparedSession(amount);
    if (prepareNextAfterReturn && mounted) {
      unawaited(_primeMosambeeSession(force: true));
    }

    return paymentResult;
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
    if (!_paymentControlsEnabled) return;

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

    // Hand the GPU entirely to the video: setting _animationsEnabled = false
    // both (a) mutes every page ticker via TickerMode and (b) takes the whole
    // page subtree Offstage in build() so it is NOT PAINTED (and not hit-tested)
    // while the video shows. (TickerMode alone only stops ticks, not the
    // per-frame composite of the tree image + gradients + shadows + CustomPaint
    // underneath the opaque barrier — that overdraw is what was starving the
    // video. Offstage keeps the subtree in the tree so widget state survives,
    // and the goal-bar growth animation resumes when the page comes back.)
    setState(() => _animationsEnabled = false);

    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Donation success video',
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return DonationSuccessVideoDialog(
          onFinished: () {
            // Un-offstage + start repainting the page NOW, one frame BEFORE we
            // begin dismissing the video. This way the page's cold re-raster
            // (tree image + shadow/blur layers + the 3 CustomPaints, all dropped
            // while Offstage) happens hidden behind the still-opaque barrier,
            // instead of as a visible dropped frame after the barrier fades out.
            if (mounted) setState(() => _animationsEnabled = true);
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
    ).whenComplete(() {
      // Fallback: guarantee the page is re-enabled even if the dialog closed
      // without onFinished (e.g. an unexpected dismissal). On the normal path
      // onFinished already did this one frame earlier; re-setting is harmless.
      if (mounted) setState(() => _animationsEnabled = true);
    });
  }

  void _showResultDialog({
    required bool success,
    required double omrAmount,
    String? errorMessage,
  }) {
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
    // 1) Kiosk id — a FAST local read, so we can guard before anything visual
    //    without delaying the success video (the slow GPS read is deferred).
    final kioskNumberStr = await LocalStorageService.getKioskNumber();

    if (!mounted) return;

    final kioskId = int.tryParse(kioskNumberStr ?? '');

    if (kioskId == null) {
      // Safety guard: device not configured. Respect showDialog so we don't
      // stack a second dialog on the silent (showDialog:false) failure path.
      if (mounted && showDialog) {
        _showResultDialog(
          success: false,
          omrAmount: omrAmount,
          errorMessage: 'Device ID is not set. Please configure this kiosk.',
        );
      }
      return;
    }

    // Builds the donation record, fetching location lazily. On the SUCCESS
    // path this runs in the BACKGROUND while the video plays, so a slow GPS
    // read never delays the video.
    Future<Donation> buildDonation() async {
      final Position? pos = await LocationService.getCurrentPosition();
      return Donation(
        id: kioskId,
        amount: omrAmount,
        receipt: receipt,
        status: status,
        latitude: pos?.latitude, // double
        longitude: pos?.longitude,
      );
    }

    final isSuccess = shouldPlayDonationSuccessVideo(status);
    var loadingShown = false;

    // Loading dialog only for the NON-success path; on success we go straight
    // to the video (no "Loading to payment" shown before it).
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

        // ▶ Play the thank-you video IMMEDIATELY on a successful payment.
        final videoFuture = _showDonationSuccessVideo().whenComplete(
          () => videoFinished = true,
        );

        // ⤷ Meanwhile (in the background, WHILE the video plays): fetch the
        //   location, build the record, and save the receipt. The next
        //   Mosambee session is already being primed by the caller.
        final saveFuture = () async {
          try {
            final donation = await buildDonation();
            await ref
                .read(donationsProvider.notifier)
                .addDonation(ref, donation);
          } catch (error, stackTrace) {
            saveError = error;
            saveStackTrace = stackTrace;
            // Always log, so a failed receipt save is observable even if the
            // page unmounts before the post-video rethrow can surface it.
            debugPrint('Donation receipt save failed: $error');
          } finally {
            donationSaveFinished = true;
          }
        }();

        await videoFuture;

        if (!mounted) return;

        // If saving is still in flight when the video ends, show the small
        // "saving" loader until it completes.
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

        _onDonationRecorded(omrAmount);
        _resetAmountControls();
        return;
      }

      // Non-success (or no-dialog) path: no video to protect, so fetch the
      // location + save before continuing.
      final newDonation = await buildDonation();

      if (!mounted) return;

      await ref.read(donationsProvider.notifier).addDonation(ref, newDonation);

      if (!mounted) return;

      // Close loading dialog if it was shown
      if (loadingShown) {
        _dismissLoadingDialog();
        loadingShown = false;
      }

      // Only show a dialog if showDialog is true. (isSuccess is already handled
      // above, so this branch is always a failure/cancel.)
      if (showDialog) {
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
    if (!_mosambeeSessionReady || _isPreparingMosambeeSession) {
      unawaited(_primeMosambeeSession());
      return;
    }

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

      result = await _sendPreparedMosambeePayment(
        mosambee,
        amt.toDouble(),
        prepareNextAfterReturn: false,
      );

      // No response at all (invoke failed / activity cancelled without data)
      if (result == null) {
        if (paymentLoadingShown) {
          _dismissLoadingDialog();
          paymentLoadingShown = false;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mosambee login/payment failed')),
          );
        }
        return;
      }

      var trimmed = result.trim();

      // Try to parse JSON so we can extract the paid amount (if any).
      var map = mosambeeJsonMap(trimmed);

      void applyGatewayAmount(Map<String, dynamic>? responseMap) {
        if (responseMap == null) return;

        // Prefer the amount returned by the gateway (if any), otherwise fallback
        // to what we requested.
        final dynamic amountValue =
            responseMap['amount'] ??
            responseMap['paidAmount'] ??
            responseMap['paid_amount'] ??
            responseMap['txnAmount'] ??
            responseMap['txn_amount'];

        final parsed = double.tryParse(amountValue?.toString() ?? '');
        if (parsed != null) {
          // If the gateway returns baisa, convert to OMR; otherwise keep as-is.
          paidOmr = parsed > _omrSteps.last ? (parsed / 1000.0) : parsed;
        }
      }

      // ✅ Always forward whatever we got (success / failed / cancelled / non-JSON)
      // so the backend has the full receipt/payload.
      applyGatewayAmount(map);

      if (isMosambeeSessionExpiredPaymentResponse(map)) {
        await _primeMosambeeSession(force: true);

        if (_mosambeeSessionReady) {
          result = await _sendPreparedMosambeePayment(mosambee, amt.toDouble());

          if (result == null) {
            if (paymentLoadingShown) {
              _dismissLoadingDialog();
              paymentLoadingShown = false;
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Mosambee login/payment failed')),
              );
            }
            return;
          }

          trimmed = result.trim();
          map = mosambeeJsonMap(trimmed);
          applyGatewayAmount(map);
        }
      } else if (mounted) {
        // Start preparing the next single-use login session as soon as Mosambee
        // returns from payment, while receipt saving/result UI continues.
        unawaited(_primeMosambeeSession(force: true));
      }

      if (paymentLoadingShown) {
        _dismissLoadingDialog();
        paymentLoadingShown = false;
      }

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
      if (mounted) {
        setState(() => _isPaying = false);
        unawaited(_primeMosambeeSession());
      }
    }
  }

  // void _jumpToOmr(double omr) {
  //   final idx = _omrSteps.indexOf(omr);
  //   if (idx != -1) setState(() => _stepIndex = idx);
  // }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnightResetTimer?.cancel();
    _goalRefreshTimer?.cancel();
    _mosambeeSessionRetryTimer?.cancel();
    _sparkleCtrl.dispose();
    _fireflyCtrl.dispose();
    _stepIndexVN.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paymentControlsEnabled = _paymentControlsEnabled;
    final mq = MediaQuery.of(context);
    final topInset = mq.padding.top;
    final double cardWidth = (mq.size.width * 0.21).clamp(74.0, 104.0);

    return TickerMode(
      enabled: _animationsEnabled,
      child: Scaffold(
        backgroundColor: const Color(0xFF06100A),
        // While the success video plays (_animationsEnabled == false) the whole
        // page goes Offstage: not painted (no raster cost) and not hit-tested —
        // so the video gets the device to itself. Widget state is preserved, so
        // growth animations resume when the video closes.
        body: Offstage(
          offstage: !_animationsEnabled,
          child: Stack(
            fit: StackFit.expand,
            children: [
            // Glowing-tree background (blurred + dark scrim). Isolated so its
            // blur isn't recomputed when the page rebuilds on interaction.
            const RepaintBoundary(child: _SadaqahBackground()),

            // Ambient drifting yellow fireflies behind the content. Isolated +
            // non-interactive so it stays cheap and never blocks taps.
            Positioned.fill(
              child: RepaintBoundary(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _fireflyCtrl,
                    builder: (context, _) => CustomPaint(
                      painter: _FireflyPainter(progress: _fireflyCtrl.value),
                    ),
                  ),
                ),
              ),
            ),

            // Main vertical layout.
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  _buildHeader(context, cardWidth),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: paymentControlsEnabled
                        ? const SizedBox.shrink()
                        : const Padding(
                            key: ValueKey('mosambee-session-status'),
                            padding: EdgeInsets.fromLTRB(22, 6, 22, 0),
                            child: Center(child: _MosambeeSessionStatus()),
                          ),
                  ),
                  Expanded(
                    child: _buildDonationArea(context, paymentControlsEnabled),
                  ),
                  const RepaintBoundary(child: _SadaqahFooterBar()),
                ],
              ),
            ),

            // Floating stat cards in the top corners.
            Positioned(
              top: topInset + 8,
              left: 30,
              child: RepaintBoundary(
                child: _StatCard(
                  width: cardWidth,
                  icon: Icons.volunteer_activism_rounded,
                  topLabel: 'Today',
                  value: _todayCount?.toString() ?? '—',
                  bottomLabel: 'Donors',
                ),
              ),
            ),
            Positioned(
              top: topInset + 8,
              right: 10,
              child: RepaintBoundary(
                child: _StatCard(
                  width: cardWidth,
                  icon: Icons.volunteer_activism_rounded,
                  topLabel: 'اليوم',
                  value: _todayCount?.toString() ?? '—',
                  bottomLabel: 'مُتَبَرِّعُون',
                  textDirection: TextDirection.rtl,
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, double cardWidth) {
    const green = Color(0xFF8DE86A);
    // Dark shadow so text stays readable over the bright tree background.
    const textShadows = [
      Shadow(color: Color(0xCC000000), blurRadius: 4),
      Shadow(color: Color(0x80000000), blurRadius: 8),
    ];

    return Padding(
      // Keep the centered header clear of the corner stat cards.
      padding: EdgeInsets.symmetric(horizontal: cardWidth + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/brand/mithqallogo.png',
            height: 34,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 2),
          // Each line is kept to ONE line via FittedBox (scales down if needed).
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Sadaqah / صدقة',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                letterSpacing: .3,
                shadows: textShadows,
              ),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.spa_rounded, size: 16, color: green),
                const SizedBox(width: 6),
                Text(
                  'Please donate to reach our goal',
                  maxLines: 1,
                  softWrap: false,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: green,
                    fontWeight: FontWeight.w700,
                    shadows: textShadows,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.spa_rounded, size: 16, color: green),
              ],
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'تبرّع لنبلغ هدفنا',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              textDirection: TextDirection.rtl,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                shadows: textShadows,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDonationArea(BuildContext context, bool enabled) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        // Space reserved on the right edge for the slider track + tick labels.
        final double sliderZone = (w * 0.27).clamp(98.0, 150.0);
        // Gap between the dial and each quick orb. Larger on the tablet so the
        // "5" orb sits higher and the "0.100" orb sits lower (more separation);
        // it's also subtracted from dialMaxH below, so the dial can't overflow.
        const double clusterGap = 30.0;
        // Dial fits BOTH the width (centered between the side lanes) AND the
        // height: 2 quick circles + dial + gaps must not overflow the screen.
        final double dialMaxW = w - 2 * sliderZone - 8;
        // quickD ≈ 0.733*dialD (0.814 * 0.9), so cluster height ≈ 2.466*dialD + 2*gap.
        final double dialMaxH = (h - 2 * clusterGap - 12) / 2.466;
        // Tablet (1200x1920 / 800x1280 logical) has more vertical room than the
        // phone kiosk, so allow a larger cluster to fill it. dialMaxH still binds
        // via the min() above, so this only grows when the height actually allows.
        final double dialD = math.min(dialMaxW, dialMaxH).clamp(140.0, 330.0);
        // The central dial renders a touch smaller than its layout size (per
        // request); the quick orbs below keep their full dialD-derived size.
        final double dialDisplayD = dialD * 0.9;
        // Quick orbs (5 / 0.100): 10% smaller than the dial-derived size so they
        // read as secondary and leave more breathing room around the dial.
        final double quickD = (dialD * 0.814 * 0.9).clamp(96.0, 216.0);

        return Stack(
          children: [
            // Central cluster centered on the full width.
            Positioned.fill(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _QuickCircle(
                        diameter: quickD,
                        innerColor: const Color(0xFF409427),
                        badgeEmoji: '★',
                        badge: 'Benefactor / سخاء',
                        value: '5',
                        sub: 'OMR / ريال',
                        activeTextColor: Colors.black.withValues(alpha: .85),
                        onTap: enabled ? () => _payAndDonate(5.000) : null,
                      ),
                      const SizedBox(height: clusterGap),
                      // Rebuilds only on amount change (ValueListenableBuilder)
                      // and drives its own sparkle animation internally.
                      RepaintBoundary(
                        child: ValueListenableBuilder<int>(
                          valueListenable: _stepIndexVN,
                          builder: (context, _, _) => _DialWithSparkles(
                            diameter: dialDisplayD,
                            valueText: _amountLabel,
                            subtitle: _dialSubtitle,
                            dragging: _dragging,
                            sliderActive: _sliderActive,
                            sparkle: _sparkleCtrl,
                            showTapHint: _dialTapHintVisible,
                            onTap: enabled ? _onDialTap : null,
                            onDragStart: _onDialDragStart,
                            onDragUpdate: (dy) {
                              // Mutating _stepIndex notifies the listenable —
                              // no full-page setState needed.
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
                            },
                            onDragEnd: _stopSparkles,
                          ),
                        ),
                      ),
                      const SizedBox(height: clusterGap),
                      _QuickCircle(
                        diameter: quickD,
                        innerColor: const Color(0xFF409427),
                        badgeEmoji: '🌱',
                        badge: 'Seed / بذرة',
                        value: '0.100',
                        sub: 'Baisa / بيسة',
                        activeTextColor: Colors.black.withValues(alpha: .85),
                        onTap: enabled ? () => _payAndDonate(0.100) : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Right side: vertical amount slider with tick labels.
            // ~15% shorter than full height (shortened from the top).
            Positioned(
              right: 20,
              top: 12 + h * 0.07,
              bottom: 16,
              width: sliderZone,
              child: RepaintBoundary(
                child: ValueListenableBuilder<int>(
                  valueListenable: _stepIndexVN,
                  builder: (context, stepIndex, _) => _AmountSlider(
                    key: const ValueKey('sadaqah-amount-slider'),
                    minIndex: _minIndex,
                    maxIndex: _maxIndex,
                    currentIndex: stepIndex,
                    stepValues: _omrSteps,
                    onIndexChanged: (newIndex) {
                      // Setter clamps + notifies the listenable; rebuilds only
                      // the dial + slider, not the whole page.
                      _stepIndex = newIndex;
                    },
                    onSlideStart: _onSliderStart,
                    onSlideEnd: _onSliderEnd,
                    showHint: _sliderHintVisible,
                  ),
                ),
              ),
            ),

            // Left side: the daily-goal FILL BAR — thin, ~20% shorter (from the
            // top). The lane is wide enough for the "Our goal" header label
            // above it (the capsule itself stays thin, centered in the lane).
            Positioned(
              left: 30,
              top: 45 + h * 0.05,
              bottom: 35,
              width: sliderZone, // mirror the right lane — room for a big ring
              child: RepaintBoundary(
                child: IgnorePointer(
                  child: _GoalBranch(progress: _goalProgress),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// ----------------- WIDGETS -----------------

class _MosambeeSessionStatus extends StatelessWidget {
  const _MosambeeSessionStatus();

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1EF17F);
    const gold = Color(0xFFC6A04E);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202126),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              key: ValueKey('mosambee-session-spinner'),
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation<Color>(green),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Preparing payment terminal',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Please wait before choosing an amount',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.76),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 6,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [green, gold],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Top/bottom quick amount circle with crisp ring + soft glow (as before)
class _QuickCircle extends StatelessWidget {
  final double diameter;
  final Color innerColor;
  final String value;
  final String sub;
  final Color activeTextColor;
  final VoidCallback? onTap;
  final String? badge;
  final String? badgeEmoji; // shown ABOVE the badge text (e.g. ⭐ / 🌱)

  const _QuickCircle({
    required this.diameter,
    required this.innerColor,
    required this.value,
    required this.sub,
    required this.activeTextColor,
    required this.onTap,
    this.badge,
    this.badgeEmoji,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final double ringPad = diameter * 0.06; // gap between orb and outer ring

    // Isolate the orb (5 stacked layers + several blurred shadows) so a
    // neighbour's per-frame repaint — the dial sparkles, the scroll bounce —
    // never forces these expensive blur layers to re-raster.
    return RepaintBoundary(
      child: GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled ? 1.0 : 0.45,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // 0) Outer ring with a soft drop shadow + green glow.
              Positioned(
                left: -ringPad,
                top: -ringPad,
                right: -ringPad,
                bottom: -ringPad,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFAADD7B), // outer ring colour
                      width: 2.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.40),
                        blurRadius: 26,
                        spreadRadius: 1,
                        offset: const Offset(0, 14),
                      ),
                      BoxShadow(
                        color: const Color(0xFFAADD7B).withValues(alpha: 0.30),
                        blurRadius: 30,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
              // 1) Soft luminous green outer glow.
              Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF78A81E).withValues(alpha: 0.40),
                      blurRadius: 34,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: const Color(0xFF90AB1A).withValues(alpha: 0.22),
                      blurRadius: 48,
                      spreadRadius: 8,
                    ),
                  ],
                ),
              ),
              // 2) Base orb: glossy GOLD (#e4b952) — lighter sheen at the TOP,
              //    deeper gold toward the BOTTOM, evenly blended (no band).
              Container(
                width: diameter,
                height: diameter,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFFFFBEF), // soft white sheen mixed in at the top
                      Color(0xFFF0D483),
                      Color(0xFFE4B952),
                      Color(0xFFD7AA46),
                      Color(0xFFC2933A),
                    ],
                    stops: [0.0, 0.16, 0.46, 0.72, 1.0],
                  ),
                ),
              ),
              // 3) Glossy top highlight for the 3D sphere sheen.
              Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.45),
                    radius: 0.85,
                    colors: [
                      Colors.white.withValues(alpha: 0.45),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
              // 4) Very thin soft rim (no hard white ring).
              Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
                ),
              ),
              // 5) Content.
              SizedBox(
                width: diameter,
                height: diameter,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (badgeEmoji != null)
                            Text(
                              badgeEmoji!,
                              textAlign: TextAlign.center,
                              // Monochrome glyphs (e.g. ★) take this colour;
                              // true colour-emoji (🌱) ignore it and keep their
                              // own colours.
                              style: TextStyle(
                                fontSize: 22,
                                height: 1.0,
                                color: activeTextColor,
                              ),
                            ),
                          if (badge != null)
                            Text(
                              badge!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: activeTextColor.withValues(alpha: .82),
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                                letterSpacing: 0.6,
                              ),
                            ),
                          Text(
                            value,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: activeTextColor,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 46,
                                  height: 1.05,
                                ),
                          ),
                          Text(
                            sub,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: activeTextColor.withValues(alpha: .8),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                          ),
                        ],
                      ),
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

class _DialWithSparkles extends StatelessWidget {
  final double diameter;
  final String valueText;
  final String subtitle;

  final bool dragging; // dial dragging
  final bool sliderActive; // 👈 slider on the right is being used

  final Animation<double> sparkle; // drives the twinkle (own RepaintBoundary)
  final bool showTapHint;

  final VoidCallback? onTap;
  final VoidCallback onDragStart;
  final void Function(double dy) onDragUpdate;
  final VoidCallback onDragEnd;

  const _DialWithSparkles({
    required this.diameter,
    required this.valueText,
    required this.subtitle,
    required this.dragging,
    required this.sliderActive,
    required this.sparkle,
    required this.showTapHint,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final bool anyInteraction = sliderActive || dragging;
    final double sparkPad = diameter * 0.14;

    return GestureDetector(
      onTap: onTap,
      onVerticalDragStart: (_) => onDragStart(),
      onVerticalDragUpdate: (d) => onDragUpdate(d.delta.dy),
      onVerticalDragEnd: (_) => onDragEnd(),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // ✨ Twinkling sparkles — isolated layer that repaints each frame,
            // while the (expensive) glowing disk below stays cached.
            Positioned(
              left: -sparkPad,
              top: -sparkPad,
              right: -sparkPad,
              bottom: -sparkPad,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: sparkle,
                  builder: (context, _) => CustomPaint(
                    size: Size.square(diameter + sparkPad * 2),
                    painter: _DialSparklePainter(
                      progress: sparkle.value,
                      active: anyInteraction,
                    ),
                  ),
                ),
              ),
            ),
            // White disk + neon glow — cached (rendered once, not per frame).
            RepaintBoundary(
              child: Container(
                width: diameter - 6,
                height: diameter - 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    // Soft dark shadow only — no bright glow (it was lighting
                    // up the whole screen).
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 36,
                      spreadRadius: 2,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
                    // Clean green ring, no glow.
                    border: Border.all(
                      color: const Color(0xFF1EF17F),
                      width: 6,
                    ),
                  ),
                ),
              ),
            ),

            // Number + subtitle (scaled to fit the responsive dial size).
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: diameter * 0.18),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
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
                                fontSize: 52,
                                height: 1.0,
                              ),
                        ),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.black.withValues(alpha: .75),
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Up / down arrows (static).
            Positioned(
              top: diameter * 0.05,
              left: 0,
              right: 0,
              child: const Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 40,
                color: Colors.black87,
              ),
            ),
            Positioned(
              bottom: diameter * 0.05,
              left: 0,
              right: 0,
              child: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 40,
                color: Colors.black87,
              ),
            ),

            // Tap hint (driven by the sparkle controller when shown).
            if (showTapHint)
              Positioned(
                bottom: diameter * 0.16,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: sparkle,
                    builder: (context, _) =>
                        TapGestureHint(progress: sparkle.value),
                  ),
                ),
              ),
          ],
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
    final press = math.sin(t * math.pi);
    final waveOpacity = slideGestureWaveOpacity(t);
    const green = Color(0xFF1EF17F);

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
              // Subtle motion lines behind the finger.
              SlideGestureMotionWave(progress: t, size: size),
              // A single clean tapering trail the finger glides along.
              Positioned(
                top: size * 0.44,
                child: Opacity(
                  opacity: waveOpacity * 0.7,
                  child: Container(
                    width: size * 0.1,
                    height: size * 0.66,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          green.withValues(alpha: 0.0),
                          green.withValues(alpha: 0.5),
                          Colors.white.withValues(alpha: 0.85),
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // Soft contact ripple at the press point.
              Positioned(
                bottom: size * 0.2,
                child: _GesturePulseRing(
                  size: size * 0.42,
                  scale: 0.7 + press * 0.55,
                  opacity: (1 - press) * 0.5,
                  color: green,
                  width: 2.0,
                ),
              ),
              // The finger, with a smooth, subtle press.
              Align(
                alignment: const Alignment(0, 0.08),
                child: Transform.translate(
                  offset: Offset(0, -press * 5),
                  child: Transform.scale(
                    scale: 0.97 + press * 0.05,
                    child: _GestureHandMark(
                      progress: t,
                      size: size * 0.78,
                      tilt: -0.12,
                      glowColor: green,
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
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.isEmpty ||
        !progress.isFinite ||
        !intensity.isFinite) {
      return;
    }

    final cyan = Color(0xFF78E7FF);
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
        ..color = cyan.withValues(alpha: localOpacity * 0.6);

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
    final wobble = math.sin(progress * math.pi * 2) * 0.02; // very subtle
    final iconSize = size * 0.74;

    return Transform.rotate(
      angle: tilt + wobble,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Soft glow behind the finger.
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    glowColor.withValues(alpha: 0.30),
                    glowColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
            // Contact shadow grounding the finger.
            Align(
              alignment: const Alignment(0, 0.8),
              child: Container(
                width: size * 0.42,
                height: size * 0.1,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            // Single clean drop shadow.
            Transform.translate(
              offset: const Offset(0, 2.5),
              child: Icon(
                Icons.touch_app_rounded,
                size: iconSize,
                color: Colors.black.withValues(alpha: 0.28),
              ),
            ),
            // Crisp white finger.
            Icon(Icons.touch_app_rounded, size: iconSize, color: Colors.white),
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
  final List<double> stepValues;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onSlideStart;
  final VoidCallback onSlideEnd;
  final bool showHint;

  const _AmountSlider({
    super.key,
    required this.minIndex,
    required this.maxIndex,
    required this.currentIndex,
    required this.stepValues,
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
  static const double _thumbSize = 40.0;
  static const double _padding = 22.0;
  static const double _trackWidth = 8.0;

  // Vivid green (matched to the mockup's slider) — clearly green, not light.
  static const Color _green = Color(0xFF2FD158);
  static const Color _greenBright = Color(0xFF63E97D);
  // Slider thumb (ring) colours: outer circle, inner circle, small inner circle.
  static const Color _thumbOuter = Color(0xFFE0F8B9);
  static const Color _thumbInner = Color(0xFF7DC72C);
  static const Color _thumbSmall = Color(0xFFF6F9DF);

  // Finger-hint pulse. Loops ONLY while the hint is shown (see
  // _syncHintAnimation) instead of ticking + repainting forever.
  late final AnimationController _hintCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _syncHintAnimation();
  }

  @override
  void didUpdateWidget(covariant _AmountSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showHint != widget.showHint) _syncHintAnimation();
  }

  // Once the user has interacted (showHint == false) the hint controller STOPS,
  // removing a forever-looping ticker + repaint from the idle frame budget.
  void _syncHintAnimation() {
    if (widget.showHint) {
      if (!_hintCtrl.isAnimating) _hintCtrl.repeat();
    } else {
      _hintCtrl.stop();
    }
  }

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
        final double width = constraints.maxWidth;

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
        // Sit the track a bit right of the lane's left edge — centered-ish, but
        // far enough right that the connector line (dial → thumb, drawn from the
        // lane's left) stays visible on the left of the ring.
        final double trackLeftInset = ((width - 74) / 2 + 24).clamp(
          10.0,
          width,
        );
        final double trackCenterX = trackLeftInset + _trackWidth / 2;

        // Ruler ticks for every step (1..39); major values are labelled.
        const Set<int> majorValues = {1, 10, 20, 30, 39};
        final List<Widget> ticks = [];
        for (int i = widget.minIndex; i <= widget.maxIndex; i++) {
          if (i < 0 || i >= widget.stepValues.length) continue;
          final double tickT = (i - widget.minIndex) / totalSteps;
          final double tickCenterY = maxCenter - tickT * centerRange;
          final int v = widget.stepValues[i].round();
          final bool isActive = i == widget.currentIndex;
          final bool isMajor = majorValues.contains(v);

          // tick line (longer + brighter for major values / the current step)
          final double lineLen = isMajor ? 16 : 8;
          ticks.add(
            Positioned(
              left: trackLeftInset + _trackWidth + 3,
              top: tickCenterY - (isActive ? 1.5 : 1),
              child: Container(
                width: lineLen,
                height: isActive ? 4 : (isMajor ? 3 : 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: isActive
                      ? _greenBright
                      : Colors.white.withValues(alpha: isMajor ? 1.0 : 0.75),
                  boxShadow: const [
                    BoxShadow(color: Color(0xB3000000), blurRadius: 3),
                  ],
                ),
              ),
            ),
          );

          // number + unit label for major ticks
          if (isMajor) {
            ticks.add(
              Positioned(
                left: trackLeftInset + _trackWidth + 3 + lineLen + 6,
                top: tickCenterY - 13,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$v',
                      style: TextStyle(
                        color: isActive ? _greenBright : Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                        shadows: const [
                          Shadow(color: Color(0xE6000000), blurRadius: 4),
                          Shadow(color: Color(0x99000000), blurRadius: 8),
                        ],
                      ),
                    ),
                    const Text(
                      'OMR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        shadows: [
                          Shadow(color: Color(0xE6000000), blurRadius: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }

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
              // --- Connector line from the dial toward the thumb ---
              Positioned(
                left: 0,
                top: centerY - 1.5,
                child: Container(
                  width: (trackCenterX - _thumbSize / 2).clamp(0.0, width),
                  height: 3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        _green.withValues(alpha: 0.0),
                        _green.withValues(alpha: 0.85),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _green.withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ),

              // --- Tick marks + labels ---
              ...ticks,

              // --- Vertical neon track ---
              Positioned(
                left: trackLeftInset,
                top: trackTop,
                child: Container(
                  width: _trackWidth,
                  height: trackHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [_greenBright, _green],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _green.withValues(alpha: 0.5),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),

              // --- Slider thumb (neon ring + bright core) ---
              // Plain Positioned (not Animated) so the thumb stays exactly in
              // sync with the connector line and the dial value.
              Positioned(
                left: trackCenterX - _thumbSize / 2,
                top: centerY - _thumbSize / 2,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 120),
                  scale: _isDragging ? 1.15 : 1.0,
                  child: Container(
                    key: const ValueKey('sadaqah-slider-thumb'),
                    width: _thumbSize,
                    height: _thumbSize,
                    // 1) Outer circle.
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _thumbOuter,
                      boxShadow: [
                        BoxShadow(
                          color: _thumbInner.withValues(alpha: 0.6),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Center(
                      // 2) Inner circle (large, so the outer rim stays thin).
                      child: Container(
                        width: _thumbSize * 0.82,
                        height: _thumbSize * 0.82,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _thumbInner,
                        ),
                        child: Center(
                          // 3) Small inner circle.
                          child: Container(
                            width: _thumbSize * 0.28,
                            height: _thumbSize * 0.28,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: _thumbSmall,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              if (widget.showHint)
                AnimatedBuilder(
                  animation: _hintCtrl,
                  builder: (context, child) {
                    // At the top of the range (39) the hint points DOWN to show
                    // the user they can slide back down; otherwise it points UP.
                    final bool slideDown =
                        widget.currentIndex >= widget.maxIndex;
                    final double easedProgress = Curves.easeInOutCubic
                        .transform(_hintCtrl.value);
                    const double slideHintSize = 70.0;
                    const double slideHintHeight = slideHintSize * 1.2;
                    const double slideDistance = 84.0;
                    const double startOffset =
                        (_thumbSize - slideHintHeight) / 2;
                    final double travel = easedProgress * slideDistance;
                    final double currentYOffset = slideDown
                        ? startOffset + travel
                        : startOffset - travel;
                    final double baseOpacity = _fadeInOut(
                      _hintCtrl.value,
                      fadeInEnd: 0.14,
                      fadeOutStart: 0.76,
                    );
                    final double opacity = _hintCtrl.value < 0.16
                        ? 0.48 + baseOpacity * 0.52
                        : baseOpacity;
                    final double thumbBaseTop = centerY - _thumbSize / 2;

                    return Positioned(
                      left: trackCenterX - slideHintSize / 2,
                      top: thumbBaseTop + currentYOffset,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: opacity,
                          // Flip vertically so the finger + trail point downward.
                          child: Transform.scale(
                            scaleY: slideDown ? -1.0 : 1.0,
                            child: SlideGestureHint(
                              key: const ValueKey('sadaqah-slide-gesture-hint'),
                              progress: _hintCtrl.value,
                              size: slideHintSize,
                            ),
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

/// Fine twinkling sparkle dots ringing the dial. They twinkle continuously and
/// become denser/brighter while the amount is being changed ([active]).
class _DialSparklePainter extends CustomPainter {
  final double progress; // 0..1, loops
  final bool active;

  _DialSparklePainter({required this.progress, required this.active});

  // A fresh seed each frame keeps every dot's position/size stable across
  // frames; the motion comes entirely from [progress].
  final math.Random _rng = math.Random(9);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final Offset center = Offset(size.width / 2, size.height / 2);
    final double dialR = size.shortestSide * 0.39; // just outside the dial edge
    final double band = size.shortestSide * 0.17; // ring thickness outward
    // Many more sparkles WHILE sliding/dragging (transient — doesn't touch the
    // idle cost); a calm count at rest. Trimmed on the low-RAM kiosk.
    final int count = active
        ? (kLowEndDevice ? 80 : 120)
        : (kLowEndDevice ? 14 : 24);

    final Paint dot = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < count; i++) {
      final double angle = _rng.nextDouble() * 2 * math.pi;
      final double bandT = _rng.nextDouble();
      final double phaseSeed = _rng.nextDouble();
      final double sizeSeed = _rng.nextDouble();
      final double colorSeed = _rng.nextDouble();

      // Twinkle (opacity + size pulse) and a gentle in/out drift per dot.
      final double tw =
          0.5 + 0.5 * math.sin((progress + phaseSeed) * 2 * math.pi);
      final double drift =
          math.sin((progress + phaseSeed) * 2 * math.pi) * band * 0.12;
      final double radius = dialR + bandT * band + drift;

      final Offset pos =
          center + Offset(math.cos(angle), math.sin(angle)) * radius;

      final double baseDot = 0.5 + sizeSeed * 1.4; // small: 0.5..1.9 px
      final double dotR = baseDot * (active ? 1.15 : 1.0) * (0.65 + 0.35 * tw);
      final double maxA = active ? 0.95 : 0.7;
      final double alpha = (maxA * (0.3 + 0.7 * tw)).clamp(0.0, 1.0);

      Color c;
      if (colorSeed < 0.72) {
        c = const Color(0xFFFFFFFF); // white
      } else if (colorSeed < 0.9) {
        c = const Color(0xFFBFFFD6); // pale green
      } else {
        c = const Color(0xFFFFE9A8); // pale gold
      }

      // Cheap soft halo for the brightest few (a faint larger circle — no
      // MaskFilter, so nothing to re-blur each frame).
      if (sizeSeed > 0.9) {
        dot.color = c.withValues(alpha: alpha * 0.16);
        canvas.drawCircle(pos, dotR * 2.4, dot);
      }
      dot.color = c.withValues(alpha: alpha);
      canvas.drawCircle(pos, dotR, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _DialSparklePainter old) =>
      // Always repaint when interaction starts/stops; otherwise ~30fps gate on
      // the kiosk (900ms loop -> 30 * 0.9 ~= 27 buckets).
      old.active != active || decorRepaint(old.progress, progress, 27);
}

/// A few small yellow "firefly" dots that gently drift and twinkle in the
/// background, concentrated around the centre (behind the donation buttons).
/// Glow is faked with cheap concentric circles (no MaskFilter) to stay light.
class _FireflyPainter extends CustomPainter {
  final double progress; // 0..1, loops

  _FireflyPainter({required this.progress});

  // Fresh seed each frame -> stable dot layout; motion comes from [progress].
  final math.Random _rng = math.Random(23);

  // Kept light for smooth animation; trimmed further on the low-RAM kiosk.
  static const int _count = kLowEndDevice ? 20 : 28;
  static const Color _core = Color(0xFFFFF3B0); // warm yellow
  static const Color _glow = Color(0xFFFFD451); // gold

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Paint p = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < _count; i++) {
      final double fx = _rng.nextDouble();
      final double fy = _rng.nextDouble();
      final double phase = _rng.nextDouble();
      final double sizeSeed = _rng.nextDouble();
      final double driftSeed = _rng.nextDouble();

      // Base position: a central band, around the donation cluster.
      final double baseX = size.width * (0.08 + fx * 0.84);
      // Reach higher up the screen so there's a bit more light near the top.
      final double baseY = size.height * (0.08 + fy * 0.74);

      // Slow circular drift.
      final double driftR = 6 + driftSeed * 12;
      final double dx = math.cos((progress + phase) * 2 * math.pi) * driftR;
      final double dy =
          math.sin((progress + phase + driftSeed) * 2 * math.pi) * driftR;
      final Offset pos = Offset(baseX + dx, baseY + dy);

      // Twinkle (each dot on its own rhythm).
      final double tw =
          0.5 + 0.5 * math.sin((progress * 1.4 + phase) * 2 * math.pi);
      final double a = 0.2 + 0.8 * tw;
      final double coreR = 1.0 + sizeSeed * 1.6;

      // Soft glow via ONE faint halo + a bright core (cheap: 2 circles/dot).
      p.color = _glow.withValues(alpha: 0.18 * a);
      canvas.drawCircle(pos, coreR * 2.6, p);
      p.color = _core.withValues(alpha: 0.95 * a);
      canvas.drawCircle(pos, coreR, p);
    }
  }

  @override
  bool shouldRepaint(covariant _FireflyPainter old) =>
      // 8s loop -> ~30fps gate on the kiosk (30 * 8 = 240 buckets).
      decorRepaint(old.progress, progress, 240);
}

/// Daily-goal "branch" that grows with each donation (PLACEHOLDER painted
/// branch — a real branch image can be dropped in later). [progress] 0..1 toward
/// the goal. Animates the growth on each change, and blooms when the goal is hit.
class _GoalBranch extends StatefulWidget {
  final double progress;
  const _GoalBranch({required this.progress});

  @override
  State<_GoalBranch> createState() => _GoalBranchState();
}

class _GoalBranchState extends State<_GoalBranch>
    with TickerProviderStateMixin {
  // One shared threshold for every bloom-gated effect.
  static const double _bloomEps = 0.01;

  // Transient growth (runs ~1.4s on each donation, then STOPS).
  late final AnimationController _growthCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  // Transient goal-reached celebration (runs ~1.6s, then STOPS).
  late final AnimationController _bloomCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  // Continuous gentle shimmer — a soft light that travels up the liquid + a
  // breathing glow, so the bar feels alive. Cheap + isolated to this small
  // RepaintBoundary (cached fill shader, no blur), so it doesn't lag the page.
  late final AnimationController _shimmerCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  // Animated "displayed" growth: tweens old -> new on each donation, then stops.
  late Animation<double> _progressAnim;

  @override
  void initState() {
    super.initState();
    _progressAnim = AlwaysStoppedAnimation<double>(widget.progress);
    if (widget.progress >= 1.0) _bloomCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _GoalBranch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progress != oldWidget.progress) {
      final double from = _progressAnim.value;
      _progressAnim = Tween<double>(begin: from, end: widget.progress).animate(
        CurvedAnimation(parent: _growthCtrl, curve: Curves.easeOutCubic),
      );
      _growthCtrl.forward(from: 0.0); // transient; settles and stops ticking.
      if (widget.progress >= 1.0 && oldWidget.progress < 1.0) {
        _bloomCtrl.forward(from: 0.0); // celebrate once on crossing the goal.
      } else if (widget.progress < 1.0) {
        _bloomCtrl.value = 0.0; // dropped below goal: no celebration.
      }
    }
  }

  @override
  void dispose() {
    _growthCtrl.dispose();
    _bloomCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The shimmer controller ticks continuously, but it only repaints THIS
    // small bar's RepaintBoundary (cheap, cached shader, no blur) — the rest of
    // the page stays still.
    return AnimatedBuilder(
      animation: Listenable.merge([_growthCtrl, _bloomCtrl, _shimmerCtrl]),
      builder: (context, _) {
        final double fill = _progressAnim.value.clamp(0.0, 1.0);
        final double bloom = _bloomCtrl.value.clamp(0.0, 1.0);
        final bool celebrating = bloom > _bloomEps;
        final bool reached = widget.progress >= 1.0;

        // The vertical capsule "fill bar" + (on goal) the sparkle pop.
        Widget bar = CustomPaint(
          size: Size.infinite,
          painter: _GoalBarPainter(
            fill: fill,
            bloom: bloom,
            shimmer: _shimmerCtrl.value,
          ),
        );
        if (celebrating) {
          bar = Stack(
            children: [
              Positioned.fill(child: bar),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BloomSparklePainter(bloom: bloom),
                  ),
                ),
              ),
            ],
          );
        }

        // Circular % progress ring (tree + percent) on top, then the "Goal"
        // label, then the vertical bar fills the rest of the lane.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 124, maxHeight: 124),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _GoalRing(progress: fill),
                ),
              ),
            ),
            const SizedBox(height: 2),
            _GoalBarLabel(reached: reached),
            const SizedBox(height: 6),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRect(clipBehavior: Clip.hardEdge, child: bar),
                  ),
                  // Vertical "TODAY · اليوم" caption running up the LEFT edge of
                  // the goal lane, beside the fill bar (matches the kiosk mockup).
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          'TODAY · اليوم',
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.ltr,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2.0,
                            shadows: const [
                              Shadow(color: Color(0xE6000000), blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Bilingual header shown ABOVE the goal bar: "Our goal / هدفنا" normally,
/// switching to the reached message once the daily goal is hit. Always visible.
class _GoalBarLabel extends StatelessWidget {
  final bool reached;
  const _GoalBarLabel({required this.reached});

  static const List<Shadow> _sh = [
    Shadow(color: Color(0xE6000000), blurRadius: 4),
  ];

  @override
  Widget build(BuildContext context) {
    final String en = reached ? 'We reached the goal!' : 'Goal';
    final String ar = reached ? 'وصلنا إلى الهدف' : 'هدف';
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              en,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: reached ? const Color(0xFFFFE9A8) : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                shadows: _sh,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              ar,
              maxLines: 1,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                shadows: _sh,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular progress "loader" for the daily goal (tree icon + percent in the
/// middle, a bright green arc sweeping clockwise). Isolated in a RepaintBoundary
/// and repaints only when the progress changes (not with the bar's shimmer).
class _GoalRing extends StatelessWidget {
  final double progress; // 0..1
  const _GoalRing({required this.progress});

  @override
  Widget build(BuildContext context) {
    final double p = progress.clamp(0.0, 1.0);
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, c) {
          // d = ring diameter; size the tree + % as fixed FRACTIONS of it so
          // they scale with the ring and "0%"/"57%"/"100%" share one digit size.
          final double d = c.maxWidth.isFinite ? c.maxWidth : 100.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _GoalRingPainter(progress: p)),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('🌳', style: TextStyle(fontSize: d * 0.19, height: 1.0)),
                  SizedBox(height: d * 0.02),
                  SizedBox(
                    width: d * 0.74, // cap so "100%" stays inside the ring
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${(p * 100).round()}%',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: d * 0.30,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                          shadows: const [
                            Shadow(color: Color(0xE6000000), blurRadius: 3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GoalRingPainter extends CustomPainter {
  final double progress; // 0..1
  _GoalRingPainter({required this.progress});

  static const Color _track = Color(0xFF103523); // dim ring background
  static const Color _arc = Color(0xFF9BFF6E); // bright lime progress
  static const Color _glow = Color(0xFF5AE06A);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double stroke = size.shortestSide * 0.085;
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = (size.shortestSide - stroke) / 2 - 1;
    final Rect rect = Rect.fromCircle(center: c, radius: r);

    // Full dim track.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = _track,
    );

    final double sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep <= 0.001) return;

    // Soft glow behind the progress arc (no blur — a wider faint arc).
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 6
        ..strokeCap = StrokeCap.round
        ..color = _glow.withValues(alpha: 0.35),
    );
    // Bright progress arc (solid — no per-frame shader).
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = _arc,
    );
  }

  @override
  bool shouldRepaint(covariant _GoalRingPainter old) =>
      old.progress != progress;
}

/// A handful of warm sparkles that pop and fade during the goal-reached bloom.
/// Driven by the already-running _bloomCtrl (transient): repaints only while
/// bloom is in flight, then stops. No blur, no MaskFilter, no continuous loop.
class _BloomSparklePainter extends CustomPainter {
  final double bloom; // 0..1
  _BloomSparklePainter({required this.bloom});

  // Deterministic anchors in normalized [0,1] zone space, each with its own
  // phase so they twinkle out of sync (clustered toward the canopy).
  static const List<Offset> _anchors = [
    Offset(0.50, 0.18),
    Offset(0.38, 0.30),
    Offset(0.62, 0.34),
    Offset(0.46, 0.46),
    Offset(0.58, 0.55),
    Offset(0.40, 0.62),
  ];
  static const List<double> _phase = [0.0, 0.18, 0.35, 0.12, 0.5, 0.28];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || bloom <= 0.01) return;
    final Paint core = Paint()..style = PaintingStyle.fill;
    final Paint halo = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < _anchors.length; i++) {
      final double local = (bloom - _phase[i]).clamp(0.0, 1.0);
      final double tw = math.sin(local * math.pi); // 0..1..0
      if (tw <= 0.01) continue;

      final Offset c = Offset(
        _anchors[i].dx * size.width,
        _anchors[i].dy * size.height,
      );
      final double r = 1.4 + 2.2 * tw;

      halo.color = const Color(0xFFFFE39A).withValues(alpha: 0.22 * tw);
      canvas.drawCircle(c, r * 2.4, halo);

      core.color = const Color(0xFFFFF6D8).withValues(alpha: 0.95 * tw);
      final double spike = r * 2.0;
      canvas.drawRect(
        Rect.fromCenter(center: c, width: spike, height: 0.9),
        core,
      );
      canvas.drawRect(
        Rect.fromCenter(center: c, width: 0.9, height: spike),
        core,
      );
      canvas.drawCircle(c, r * 0.55, core);
    }
  }

  @override
  bool shouldRepaint(covariant _BloomSparklePainter old) => old.bloom != bloom;
}

/// One side-twig carrying a leaf cluster. Built ONCE, never derived from
/// `grown`, so nothing reshuffles as the growth front crosses a threshold.
/// A clean vertical "fill bar" that climbs toward the daily goal (mirrors the
/// amount slider on the right). The capsule fills bottom-up with a glowing
/// green gradient as `fill` (the eased displayed progress) rises, and a subtle
/// etched vine is revealed inside the liquid — a tasteful nod to the "branch
/// growing" without a busy rendered tree. Repaints only while the transient
/// growth / bloom controllers run; no blur, no per-frame shader storm.
class _GoalBarPainter extends CustomPainter {
  final double fill; // 0..1 : how full toward the goal (eased displayed prog)
  final double bloom; // 0..1 : goal-reached celebration (transient)
  final double shimmer; // 0..1 : continuous, drives the traveling light + glow

  _GoalBarPainter({
    required this.fill,
    required this.bloom,
    required this.shimmer,
  });

  // Fill gradient is cached (size is stable) so the continuous shimmer repaint
  // never recreates a shader per frame.
  static Paint? _fillPaint;
  static Rect? _fillPaintRect;
  Paint _fillPaintFor(Rect bar) {
    if (_fillPaint == null || _fillPaintRect != bar) {
      _fillPaintRect = bar;
      _fillPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_fillTop, _fillMid, _fillBot],
          stops: [0.0, 0.5, 1.0],
        ).createShader(bar);
    }
    return _fillPaint!;
  }

  // Palette from the user's mockup (brighter, more vivid greens).
  static const Color _trackBg = Color(0xD9071A12); // dark glassy track
  static const Color _border = Color(0xFF7CFF8B); // bright green rim
  static const Color _fillTop = Color(0xFF9BFF6E); // bright lime (surface)
  static const Color _fillMid = Color(0xFF5AE06A);
  static const Color _fillBot = Color(0xFF22B14C); // green (base)
  static const Color _gloss = Color(0xFFFFFFFF); // glossy highlight
  static const Color _meniscus = Color(0xFFE6FFC9); // bright liquid surface
  static const Color _glow = Color(0xFF5AE06A); // outer halo
  static const Color _vine = Color(0xFFE6FFE8); // etched vine motif

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double f = fill.clamp(0.0, 1.0);
    final double burst = math.sin(bloom * math.pi); // 0..1..0

    final double barW = (size.width * 0.66).clamp(18.0, 30.0);
    final double cx = size.width / 2;
    const double pad = 6.0;
    final Rect bar = Rect.fromLTWH(
      cx - barW / 2,
      pad,
      barW,
      size.height - pad * 2,
    );
    final double r = barW / 2;
    final RRect track = RRect.fromRectAndRadius(bar, Radius.circular(r));

    // Continuous breathing glow.
    final double glowPulse = 0.5 + 0.5 * math.sin(shimmer * 2 * math.pi);

    // 1) Soft outer halo (stepped, no blur) — grows with fill + bloom + breath.
    final Paint glowP = Paint()..style = PaintingStyle.fill;
    final double glowA = 0.04 + 0.09 * f + 0.16 * burst + 0.05 * glowPulse * f;
    for (int i = 4; i >= 1; i--) {
      glowP.color = _glow.withValues(alpha: glowA * (i == 1 ? 1.0 : 0.45));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          bar.inflate(i * 5.0),
          Radius.circular(r + i * 5.0),
        ),
        glowP,
      );
    }

    // 2) Track.
    canvas.drawRRect(track, Paint()..color = _trackBg);

    // 3) Fill + gloss + vine, clipped to the capsule.
    canvas.save();
    canvas.clipRRect(track);

    final double fillTop = bar.bottom - bar.height * f;
    final Rect fillRect = Rect.fromLTRB(
      bar.left,
      fillTop,
      bar.right,
      bar.bottom,
    );
    if (f > 0.001) {
      // Gradient spans the FULL bar so colour is height-consistent as it fills.
      canvas.drawRect(fillRect, _fillPaintFor(bar));

      // Glossy vertical highlight near the left edge.
      final Rect glossRect = Rect.fromLTWH(
        bar.left + barW * 0.18,
        fillTop + 3,
        barW * 0.15,
        math.max(0.0, bar.bottom - fillTop - 6),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(glossRect, Radius.circular(barW * 0.08)),
        Paint()..color = _gloss.withValues(alpha: 0.14),
      );

      // Etched vine motif + a soft light that travels UP the liquid, both
      // revealed only within the filled region.
      canvas.save();
      canvas.clipRect(fillRect);
      _drawVine(canvas, bar, burst);
      _drawShimmer(canvas, fillRect);
      canvas.restore();
    }

    canvas.restore(); // release the capsule clip

    // 4) Bright meniscus line at the liquid surface (while partly full).
    if (f > 0.015 && f < 0.995) {
      canvas.drawLine(
        Offset(bar.left + 6, fillTop),
        Offset(bar.right - 6, fillTop),
        Paint()
          ..color = _meniscus.withValues(alpha: 0.22)
          ..strokeWidth = 6.0
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        Offset(bar.left + 4, fillTop),
        Offset(bar.right - 4, fillTop),
        Paint()
          ..color = _meniscus.withValues(alpha: 0.92)
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round,
      );
    }

    // 5) Capsule rim.
    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = _border.withValues(alpha: 0.85 + 0.15 * burst),
    );
  }

  // A clean etched vine climbing the bar centerline (drawn over the full bar,
  // clipped by the caller to the filled liquid so it "grows" as the bar fills).
  void _drawVine(Canvas canvas, Rect bar, double burst) {
    final double cx = bar.center.dx;
    final double bottom = bar.bottom;
    final double h = bar.height;
    final double amp = bar.width * 0.18;

    Offset pt(double v) {
      final double y = bottom - v * h;
      final double x = cx + math.sin(v * 5.0 + 0.4) * amp * (0.3 + 0.7 * v);
      return Offset(x, y);
    }

    final Path stem = Path()..moveTo(pt(0).dx, pt(0).dy);
    const int segs = 40;
    for (int i = 1; i <= segs; i++) {
      final Offset p = pt(i / segs);
      stem.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      stem,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = _vine.withValues(alpha: 0.34 + 0.12 * burst),
    );

    final Paint leaf = Paint()..style = PaintingStyle.fill;
    for (int i = 1; i <= 9; i++) {
      final double v = i / 10.0;
      final Offset p = pt(v);
      final double side = i.isEven ? 1.0 : -1.0;
      final double ll = bar.width * 0.26;
      final double lw = ll * 0.5;
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(side * 0.9);
      leaf.color = _vine.withValues(alpha: 0.27 + 0.12 * burst);
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..quadraticBezierTo(lw, -ll * 0.45, 0, -ll)
          ..quadraticBezierTo(-lw, -ll * 0.45, 0, 0)
          ..close(),
        leaf,
      );
      canvas.restore();
    }
  }

  // A soft horizontal light band that rises through the liquid and loops —
  // the "alive" shimmer. Stacked translucent rrects (no blur, no shader).
  void _drawShimmer(Canvas canvas, Rect fillRect) {
    if (fillRect.height < 6) return;
    // Travel from just below the surface down... up: bottom -> top, looping.
    final double bandY =
        fillRect.bottom - shimmer * (fillRect.height + 60.0) + 30.0;
    if (bandY < fillRect.top - 20 || bandY > fillRect.bottom + 20) return;
    final double cx = fillRect.center.dx;
    final Paint p = Paint()..style = PaintingStyle.fill;
    for (int i = 3; i >= 1; i--) {
      final double hh = 5.0 * i;
      p.color = _gloss.withValues(alpha: 0.12 / i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, bandY),
            width: fillRect.width,
            height: hh,
          ),
          Radius.circular(hh / 2),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GoalBarPainter old) =>
      // Growth/bloom react instantly; the continuous shimmer is gated to ~30fps
      // on the kiosk (2.6s loop -> 30 * 2.6 ~= 78 buckets).
      old.fill != fill ||
      old.bloom != bloom ||
      decorRepaint(old.shimmer, shimmer, 78);
}

/// ----------------- NEW DESIGN WIDGETS -----------------

/// Glowing-tree background image with a blur + dark scrim for legibility.
/// Falls back to a deep-green gradient until the image exists on disk.
class _SadaqahBackground extends StatelessWidget {
  static const String assetPath = 'assets/background/tree_bg.png';

  /// Background brightness, from 0.0 (hidden) to 1.0 (full / brightest).
  /// Examples: 0.35 = dim, 0.5 = balanced, 0.7 = brighter, 1.0 = full.
  /// The value is clamped to 0.0–1.0, so anything higher (e.g. 5) is just
  /// treated as 1.0 and will NOT crash.
  static const double backgroundOpacity = 0.2;

  const _SadaqahBackground();

  @override
  Widget build(BuildContext context) {
    // Decode the large (1024x1536) source down to roughly the screen's pixel
    // width instead of full resolution — a big resident-bitmap memory saving on
    // 4GB hardware. cover crops the rest; the background is dim so this is
    // visually identical.
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double w = MediaQuery.sizeOf(context).width;
    final int cacheW = math.min(1024, math.max(1, (w * dpr).round()));

    return Stack(
      fit: StackFit.expand,
      children: [
        // Deep green-black base (also the fallback before the image is added).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.35),
              radius: 1.1,
              colors: [Color(0xFF12351F), Color(0xFF081109), Color(0xFF04070A)],
              stops: [0.0, 0.6, 1.0],
            ),
          ),
        ),
        // Tree image dimmed toward the dark base so the foreground stands out.
        // The dim is baked into the image via a modulate colour filter (alpha in
        // the white tint) rather than an Opacity wrapper — same look, but no
        // full-screen saveLayer to allocate on every (re)paint.
        Image.asset(
          assetPath,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: cacheW,
          color: const Color(
            0xFFFFFFFF,
          ).withValues(alpha: backgroundOpacity.clamp(0.0, 1.0)),
          colorBlendMode: BlendMode.modulate,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Frosted-glass stat card used in the top corners (Today / Trees Planted).
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String topLabel;
  final String value;
  final String bottomLabel;
  final double width;
  final TextDirection? textDirection; // rtl for the Arabic box

  const _StatCard({
    required this.icon,
    required this.topLabel,
    required this.value,
    required this.bottomLabel,
    required this.width,
    this.textDirection,
  });

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1EF17F);

    // Solid translucent panel — no BackdropFilter (the blur re-ran every frame
    // under the animations and caused jank).
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1F12).withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: green.withValues(alpha: 0.45), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: green.withValues(alpha: 0.12),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: green, size: 24),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              topLabel,
              maxLines: 1,
              softWrap: false,
              textDirection: textDirection,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              bottomLabel,
              maxLines: 1,
              softWrap: false,
              textDirection: textDirection,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom footer bar: Jumu'ah Blessings · Powered by Mithqal · Rewards Await You.
class _SadaqahFooterBar extends StatelessWidget {
  const _SadaqahFooterBar();

  @override
  Widget build(BuildContext context) {
    // Solid translucent bar — no BackdropFilter (blur was a per-frame cost).
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          children: [
            Image.asset(
              'assets/sponsors/sirajlogo.png',
              height: 34,
              fit: BoxFit.contain,
            ),
            const Spacer(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Powered by',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Image.asset(
                  'assets/brand/mithqallogo.png',
                  height: 22,
                  fit: BoxFit.contain,
                ),
              ],
            ),
            const Spacer(),
            Image.asset(
              'assets/sponsors/omansteel.png',
              height: 34,
              fit: BoxFit.contain,
            ),
          ],
        ),
      ),
    );
  }
}
