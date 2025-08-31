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
