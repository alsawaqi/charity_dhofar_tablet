import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:charity_dhofar_tablet/main.dart';
import 'package:charity_dhofar_tablet/providers/mosambee_provider.dart';
import 'package:charity_dhofar_tablet/screen/sadaqah_page.dart';
import 'package:charity_dhofar_tablet/screen/setup_number_page.dart';

class _WaitingMosambeeService extends MosambeeService {
  final Completer<String?> paymentResult = Completer<String?>();
  final Completer<void> started = Completer<void>();

  @override
  Future<String?> loginAndPay(double amount) {
    if (!started.isCompleted) {
      started.complete();
    }
    return paymentResult.future;
  }
}

void main() {
  testWidgets('App builds smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CharityApp()));

    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('SetupNumberPage builds', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(home: SetupNumberPage()));

    expect(find.text('Setup Kiosk'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('PaymentLoadingDialog shows bilingual payment loading state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PaymentLoadingDialog())),
      ),
    );

    expect(find.text('Loading to payment'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('SadaqahPage shows payment loading while opening Mosambee', (
    WidgetTester tester,
  ) async {
    final mosambee = _WaitingMosambeeService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mosambeeProvider.overrideWithValue(mosambee)],
        child: const MaterialApp(home: SadaqahPage()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('5.000'));
    await tester.pump();

    expect(find.text('Loading to payment'), findsOneWidget);
    expect(mosambee.started.isCompleted, isTrue);

    await mosambee.started.future;
    mosambee.paymentResult.complete(null);
    await tester.pump();
  });

  testWidgets('DonationResultDialog shows graceful success copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DonationResultDialog(success: true, omrAmount: 5),
          ),
        ),
      ),
    );

    expect(find.text('Sadaqah received'), findsOneWidget);
    expect(
      find.text('May it be accepted and multiplied in goodness.'),
      findsOneWidget,
    );
    expect(find.text('OMR 5.000'), findsOneWidget);
  });

  testWidgets('DonationResultDialog shows gentle failure copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DonationResultDialog(
              success: false,
              omrAmount: 2,
              errorMessage: 'Card declined',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Payment not completed'), findsOneWidget);
    expect(
      find.text('No donation was recorded. Please try again when ready.'),
      findsOneWidget,
    );
    expect(find.text('Card declined'), findsOneWidget);
  });

  testWidgets('SadaqahPage shows a slide-up gesture hint initially', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mosambeeProvider.overrideWithValue(MosambeeService())],
        child: const MaterialApp(home: SadaqahPage()),
      ),
    );
    await tester.pump();

    expect(find.byType(SlideGestureHint), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == slideGestureHintSemanticsLabel,
      ),
      findsOneWidget,
    );
  });

  testWidgets('slide-up gesture starts on the slider circle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mosambeeProvider.overrideWithValue(MosambeeService())],
        child: const MaterialApp(home: SadaqahPage()),
      ),
    );
    await tester.pump();

    final thumbCenter = tester.getCenter(
      find.byKey(const ValueKey('sadaqah-slider-thumb')),
    );
    final hintCenter = tester.getCenter(
      find.byKey(const ValueKey('sadaqah-slide-gesture-hint')),
    );

    expect((hintCenter.dy - thumbCenter.dy).abs(), lessThanOrEqualTo(12));
  });

  testWidgets('gesture hints include motion wave and click feedback', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SlideGestureHint(progress: 0.35),
              TapGestureHint(progress: 0.5),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(SlideGestureMotionWave), findsOneWidget);
    expect(find.byType(TapGestureClickFeedback), findsOneWidget);
  });

  test('slide gesture wave appears while moving and disappears after', () {
    expect(slideGestureWaveOpacity(0.35), greaterThan(0.7));
    expect(slideGestureWaveOpacity(0.92), lessThan(0.05));
  });

  test('thank-you video only plays for successful donation status', () {
    expect(shouldPlayDonationSuccessVideo('SUCCESS'), isTrue);
    expect(shouldPlayDonationSuccessVideo(' success '), isTrue);
    expect(shouldPlayDonationSuccessVideo('FAILED'), isFalse);
    expect(shouldPlayDonationSuccessVideo(null), isFalse);
    expect(donationSuccessVideoAsset, 'assets/videos/boy_thankyou.mp4');
    expect(donationSuccessVideoMuted, isTrue);
    expect(donationSuccessVideoFallbackSize, const Size(1200, 1920));
  });

  test(
    'successful donation remains locked until video and API save finish',
    () {
      expect(
        shouldShowDonationSaveLoading(
          videoFinished: true,
          donationSaveFinished: false,
        ),
        isTrue,
      );
      expect(
        shouldShowDonationSaveLoading(
          videoFinished: false,
          donationSaveFinished: false,
        ),
        isFalse,
      );
      expect(
        isDonationCompletionPending(
          videoFinished: true,
          donationSaveFinished: false,
        ),
        isTrue,
      );
      expect(
        isDonationCompletionPending(
          videoFinished: false,
          donationSaveFinished: true,
        ),
        isTrue,
      );
      expect(
        isDonationCompletionPending(
          videoFinished: true,
          donationSaveFinished: true,
        ),
        isFalse,
      );
    },
  );

  testWidgets('SadaqahPage does not show temporary video test button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mosambeeProvider.overrideWithValue(MosambeeService())],
        child: const MaterialApp(home: SadaqahPage()),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('test-success-video-button')),
      findsNothing,
    );
  });

  testWidgets('SadaqahPage shows a tap gesture hint while slider is held', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mosambeeProvider.overrideWithValue(MosambeeService())],
        child: const MaterialApp(home: SadaqahPage()),
      ),
    );
    await tester.pump();

    final sliderCenter = tester.getCenter(
      find.byKey(const ValueKey('sadaqah-amount-slider')),
    );
    final gesture = await tester.startGesture(sliderCenter);
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(TapGestureHint), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == tapGestureHintSemanticsLabel,
      ),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pump();
  });
}
