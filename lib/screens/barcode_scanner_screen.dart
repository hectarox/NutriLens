part of '../main.dart';

class _BarcodeScannerScreen extends StatefulWidget {
  const _BarcodeScannerScreen();

  @override
  State<_BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<_BarcodeScannerScreen> {
  bool _locked = false;

  @override
  Widget build(BuildContext context) {
    // Check if we're in mock mode (web or mock flavor)
    const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'production');
    final isMockMode = flavor == 'mock' || kIsWeb;

    if (isMockMode) {
      // Mock scanner implementation
      return Scaffold(
        appBar: AppBar(title: Text(S.of(context).scanBarcodeTitle)),
        body: _MockScannerWidget(
          onBarcodeDetected: (barcode) {
            if (_locked) return;
            _locked = true;
            Navigator.pop(context, barcode);
          },
        ),
      );
    } else {
      // Real scanner implementation
      return Scaffold(
        appBar: AppBar(title: Text(S.of(context).scanBarcodeTitle)),
        body: MobileScanner(
          onDetect: (capture) {
            if (_locked) return;
            final barcodes = capture.barcodes;
            if (barcodes.isEmpty) return;
            final value = barcodes.first.rawValue;
            if (value != null && value.isNotEmpty) {
              _locked = true;
              Navigator.pop(context, value);
            }
          },
        ),
      );
    }
  }
}

// Mock scanner widget that looks identical to the real scanner
class _MockScannerWidget extends StatefulWidget {
  final Function(String) onBarcodeDetected;

  const _MockScannerWidget({required this.onBarcodeDetected});

  @override
  State<_MockScannerWidget> createState() => _MockScannerWidgetState();
}

class _MockScannerWidgetState extends State<_MockScannerWidget> {
  String? _detectingProduct;
  bool _showDetectionText = false;

  @override
  void initState() {
    super.initState();
    // Simulate barcode detection after 800ms-1200ms (more realistic)
    final delay = 800 + (DateTime.now().millisecondsSinceEpoch % 400);

    // Show detection text 300ms before actual detection
    Future.delayed(Duration(milliseconds: delay - 300), () {
      if (mounted) {
        setState(() {
          _showDetectionText = true;
          // Select the product that will be detected
          final mockProducts = [
            'Mock Chocolate Bar',
            'Mock Apple',
            'Mock Bread Slice',
            'Mock Banana',
            'Mock Yogurt',
          ];
          _detectingProduct = mockProducts[DateTime.now().millisecondsSinceEpoch % mockProducts.length];
        });
      }
    });

    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted) {
        // Occasionally simulate "no barcode found" (10% chance)
        if (DateTime.now().millisecondsSinceEpoch % 10 == 0) {
          // Simulate failed detection by not calling onBarcodeDetected
          // This will keep the scanner running, mimicking real-world failures
          setState(() {
            _showDetectionText = false;
            _detectingProduct = null;
          });
          // Try again after a short delay
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() => _showDetectionText = true);
            }
          });
          return;
        }

        // Generate the corresponding barcode
        final mockBarcodes = [
          '3017620422003', // Mock chocolate bar
          '3274080005003', // Mock apple
          '7613031234567', // Mock bread slice
          '8076809513192', // Mock banana
          '7613287002434', // Mock yogurt
        ];
        final randomBarcode = mockBarcodes[DateTime.now().millisecondsSinceEpoch % mockBarcodes.length];
        widget.onBarcodeDetected(randomBarcode);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          // Mock camera view - just a dark background
          Container(
            color: Colors.black87,
            child: const Center(
              child: Icon(
                Icons.camera_alt,
                color: Colors.white38,
                size: 64,
              ),
            ),
          ),
          // Scanner overlay (same as real scanner)
          CustomPaint(
            painter: _ScannerOverlayPainter(),
            child: Container(),
          ),
          // Scanning animation
          const _ScanningAnimation(),
          // Detection feedback (only shown briefly before detection)
          if (_showDetectionText && _detectingProduct != null)
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                margin: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: Text(
                  'Detecting: $_detectingProduct',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Scanner overlay painter (same as real scanner)
class _ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Draw corner brackets for the scanning area
    final scanAreaWidth = size.width * 0.8;
    final scanAreaHeight = size.height * 0.4;
    final left = (size.width - scanAreaWidth) / 2;
    final top = (size.height - scanAreaHeight) / 2;
    final right = left + scanAreaWidth;
    final bottom = top + scanAreaHeight;

    // Top-left corner
    canvas.drawLine(Offset(left, top + 20), Offset(left, top), paint);
    canvas.drawLine(Offset(left, top), Offset(left + 20, top), paint);

    // Top-right corner
    canvas.drawLine(Offset(right - 20, top), Offset(right, top), paint);
    canvas.drawLine(Offset(right, top), Offset(right, top + 20), paint);

    // Bottom-left corner
    canvas.drawLine(Offset(left, bottom - 20), Offset(left, bottom), paint);
    canvas.drawLine(Offset(left, bottom), Offset(left + 20, bottom), paint);

    // Bottom-right corner
    canvas.drawLine(Offset(right - 20, bottom), Offset(right, bottom), paint);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - 20), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Scanning animation (same as real scanner)
class _ScanningAnimation extends StatefulWidget {
  const _ScanningAnimation();

  @override
  State<_ScanningAnimation> createState() => _ScanningAnimationState();
}

class _ScanningAnimationState extends State<_ScanningAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.2, end: 0.8).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Positioned(
          left: MediaQuery.of(context).size.width * 0.1,
          right: MediaQuery.of(context).size.width * 0.1,
          top: MediaQuery.of(context).size.height * _animation.value,
          child: Container(
            height: 2,
            color: Colors.red.withOpacity(0.8),
          ),
        );
      },
    );
  }
}
