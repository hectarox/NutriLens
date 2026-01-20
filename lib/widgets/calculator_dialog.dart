part of '../main.dart';

class TDEECalculatorDialog extends StatefulWidget {
  final int currentLimit;
  const TDEECalculatorDialog({super.key, required this.currentLimit});

  @override
  State<TDEECalculatorDialog> createState() => _TDEECalculatorDialogState();
}

class _TDEECalculatorDialogState extends State<TDEECalculatorDialog> {
  final _formKey = GlobalKey<FormState>();
  
  // Defaults
  int _age = 25;
  double _weight = 70;
  double _height = 175;
  bool _isMale = true;
  double _activityFactor = 1.2; // Sedentary
  int _goalAdjustment = 0; // Maintain

  int? _calculatedResult;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    
    return AlertDialog(
      title: Text(s.calculatorTitle),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Gender
              Row(
                children: [
                  Expanded(
                    child: RadioListTile<bool>(
                      title: Text(s.male),
                      value: true,
                      groupValue: _isMale,
                      onChanged: (v) => setState(() => _isMale = v!),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<bool>(
                      title: Text(s.female),
                      value: false,
                      groupValue: _isMale,
                      onChanged: (v) => setState(() => _isMale = v!),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
              const Divider(),
              
              // Age, Weight, Height
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _age.toString(),
                      decoration: InputDecoration(labelText: s.age),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _age = int.tryParse(v) ?? _age,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      initialValue: _weight.toString(),
                      decoration: InputDecoration(labelText: s.bodyWeight),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (v) => _weight = double.tryParse(v.replaceAll(',', '.')) ?? _weight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: _height.toString(),
                decoration: InputDecoration(labelText: s.height),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) => _height = double.tryParse(v.replaceAll(',', '.')) ?? _height,
              ),
              
              const SizedBox(height: 16),
              // Activity Level
              DropdownButtonFormField<double>(
                value: _activityFactor,
                decoration: InputDecoration(labelText: s.activityLevel),
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: 1.2, child: Text(s.sedentary)),
                  DropdownMenuItem(value: 1.375, child: Text(s.lightlyActive)),
                  DropdownMenuItem(value: 1.55, child: Text(s.moderatelyActive)),
                  DropdownMenuItem(value: 1.725, child: Text(s.veryActive)),
                  DropdownMenuItem(value: 1.9, child: Text(s.extraActive)),
                ],
                onChanged: (v) => setState(() => _activityFactor = v!),
              ),
              
              const SizedBox(height: 16),
              // Goal
              DropdownButtonFormField<int>(
                value: _goalAdjustment,
                decoration: InputDecoration(labelText: s.goal),
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: -500, child: Text(s.loseWeight)), // -500 kcal
                  DropdownMenuItem(value: -1000, child: Text(s.loseWeightFast, style: const TextStyle(color: Colors.red))), // -1000 kcal
                  DropdownMenuItem(value: 0, child: Text(s.maintainWeight)),
                  DropdownMenuItem(value: 500, child: Text(s.gainWeight)), // +500 kcal
                ],
                onChanged: (v) => setState(() => _goalAdjustment = v!),
              ),
              
              const SizedBox(height: 24),
              
              Center(
                child: ElevatedButton(
                  onPressed: _calculate,
                  child: Text(s.calculate),
                ),
              ),
              
              if (_calculatedResult != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green),
                  ),
                  child: Column(
                    children: [
                      Text(s.dailyNeedsResult, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        '$_calculatedResult kcal',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        if (_calculatedResult != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, _calculatedResult),
            child: Text(s.useThisTarget),
          ),
      ],
    );
  }

  void _calculate() {
    // Mifflin-St Jeor Equation
    // Men: (10 × weight in kg) + (6.25 × height in cm) - (5 × age in years) + 5
    // Women: (10 × weight in kg) + (6.25 × height in cm) - (5 × age in years) - 161
    
    double bmr;
    if (_isMale) {
      bmr = (10 * _weight) + (6.25 * _height) - (5 * _age) + 5;
    } else {
      bmr = (10 * _weight) + (6.25 * _height) - (5 * _age) - 161;
    }
    
    double tdee = bmr * _activityFactor;
    
    // Apply goal
    double target = tdee + _goalAdjustment;
    
    setState(() {
      _calculatedResult = target.round();
    });
  }
}
