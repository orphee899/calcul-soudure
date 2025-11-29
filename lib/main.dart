import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
// ICI C'EST LA CORRECTION : On cache "Border" de Excel pour éviter le conflit
import 'package:excel/excel.dart' hide Border; 

// ==========================================
// 1. CONFIGURATION
// ==========================================

class AppColors {
  static const Color background = Color(0xFF0F172A); 
  static const Color surface = Color(0xFF1E293B);    
  static const Color surfaceLight = Color(0xFF334155); 
  static const Color textMain = Color(0xFFF1F5F9);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color accent = Color(0xFFF59E0B);      
  static const Color success = Color(0xFF22C55E); 
  static const Color error = Color(0xFFEF4444);
}

// ==========================================
// 2. MODÈLES
// ==========================================

enum WeldingProcess { MMA, MIG_MAG, TIG, SAW, FCAW }

extension WeldingProcessExtension on WeldingProcess {
  String get label {
    switch (this) {
      case WeldingProcess.MMA: return 'MMA (111)';
      case WeldingProcess.MIG_MAG: return 'MIG/MAG (131/135)';
      case WeldingProcess.TIG: return 'TIG (141)';
      case WeldingProcess.SAW: return 'SAW (121)';
      case WeldingProcess.FCAW: return 'FCAW (136)';
    }
  }

  double get efficiency {
    switch (this) {
      case WeldingProcess.MMA: return 0.8;
      case WeldingProcess.MIG_MAG: return 0.8;
      case WeldingProcess.TIG: return 0.6;
      case WeldingProcess.SAW: return 1.0;
      case WeldingProcess.FCAW: return 0.8;
    }
  }
}

class WeldingPass {
  final String id;
  final DateTime date;
  final WeldingProcess process;
  final double current;
  final double voltage;
  final double length;
  final double time;
  final double heatInput;
  final double kFactor;

  WeldingPass({
    required this.id,
    required this.date,
    required this.process,
    required this.current,
    required this.voltage,
    required this.length,
    required this.time,
    required this.heatInput,
    required this.kFactor,
  });
}

// ==========================================
// 3. LOGIQUE (STATE)
// ==========================================

class WeldingState extends ChangeNotifier {
  // Paramètres
  WeldingProcess _process = WeldingProcess.MIG_MAG;
  double _voltage = 0.0;
  double _current = 0.0;
  double _length = 0.0;
  
  // Chrono
  Timer? _uiTimer;
  double _savedTime = 0.0; 
  DateTime? _startTime;    

  // Getters
  WeldingProcess get process => _process;
  double get voltage => _voltage;
  double get current => _current;
  double get length => _length;
  bool get isRunning => _startTime != null;
  
  double get time {
    if (_startTime == null) {
      return _savedTime;
    } else {
      final now = DateTime.now();
      final diff = now.difference(_startTime!).inMilliseconds / 1000.0;
      return _savedTime + diff;
    }
  }

  // Setters
  void setProcess(WeldingProcess p) { _process = p; notifyListeners(); }
  void setVoltage(double v) { _voltage = v; notifyListeners(); }
  void setCurrent(double c) { _current = c; notifyListeners(); }
  void setLength(double l) { _length = l; notifyListeners(); }
  
  // Actions Chrono
  void toggleTimer() {
    if (isRunning) _stopTimer();
    else _startTimer();
  }

  void _startTimer() {
    _startTime = DateTime.now();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => notifyListeners());
    notifyListeners();
  }

  void _stopTimer() {
    _savedTime = time;
    _startTime = null;
    _uiTimer?.cancel();
    notifyListeners();
  }

  void resetTimer() {
    _uiTimer?.cancel();
    _startTime = null;
    _savedTime = 0.0;
    notifyListeners();
  }

  void manualSetTime(double val) {
    if (!isRunning) {
      _savedTime = val;
      notifyListeners();
    }
  }

  // Historique & IA
  final List<WeldingPass> _passes = [];
  String? _aiAnalysis;
  bool _isAnalyzing = false;
  List<WeldingPass> get passes => _passes;
  String? get aiAnalysis => _aiAnalysis;
  bool get isAnalyzing => _isAnalyzing;

  double? get heatInput {
    if (time > 0 && _length > 0) {
      return (_process.efficiency * _voltage * _current * time) / (_length * 1000);
    }
    return null;
  }
  
  void savePass() {
    if (heatInput == null) return;
    final pass = WeldingPass(
      id: const Uuid().v4(),
      date: DateTime.now(),
      process: _process,
      current: _current,
      voltage: _voltage,
      length: _length,
      time: time,
      heatInput: heatInput!,
      kFactor: _process.efficiency,
    );
    _passes.insert(0, pass);
    notifyListeners();
  }

  void deletePass(String id) {
    _passes.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  // EXPORT EXCEL
  Future<void> exportToExcel() async {
    if (_passes.isEmpty) return;

    var excel = Excel.createExcel();
    Sheet sheetObject = excel['Soudures'];
    excel.setDefaultSheet('Soudures');

    List<String> headers = [
      'Date', 'Heure', 'Procédé', 'Tension (V)', 'Intensité (A)', 
      'Longueur (mm)', 'Temps (s)', 'Facteur k', 'Énergie (kJ/mm)'
    ];
    
    for (int i = 0; i < headers.length; i++) {
      var cell = sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = TextCellValue(headers[i]);
      cell.cellStyle = CellStyle(bold: true, horizontalAlign: HorizontalAlign.Center);
    }

    for (int i = 0; i < _passes.length; i++) {
      final p = _passes[i];
      final row = i + 1;
      
      final dateStr = DateFormat('dd/MM/yyyy').format(p.date);
      final hourStr = DateFormat('HH:mm').format(p.date);

      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = TextCellValue(dateStr);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = TextCellValue(hourStr);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = TextCellValue(p.process.label);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = DoubleCellValue(p.voltage);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = DoubleCellValue(p.current);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = DoubleCellValue(p.length);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = DoubleCellValue(double.parse(p.time.toStringAsFixed(1)));
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = DoubleCellValue(p.kFactor);
      sheetObject.cell(CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = DoubleCellValue(double.parse(p.heatInput.toStringAsFixed(3)));
    }

    final fileBytes = excel.save();
    if (fileBytes != null) {
      final blob = html.Blob([fileBytes]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute("download", "Rapport_Soudure_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.xlsx")
        ..click();
      html.Url.revokeObjectUrl(url);
    }
  }

  Future<void> analyzeWeld(String apiKey) async {
    if (heatInput == null) return;
    _isAnalyzing = true;
    _aiAnalysis = null;
    notifyListeners();
    try {
      final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);
      final prompt = 'Analyse soudure: ${_process.label}, $_voltage V, $_current A, $_length mm, ${time.toStringAsFixed(1)} s. Energie: ${heatInput!.toStringAsFixed(3)} kJ/mm. Avis expert court.';
      final response = await model.generateContent([Content.text(prompt)]);
      _aiAnalysis = response.text;
    } catch (e) {
      _aiAnalysis = "Erreur IA: ${e.toString()}";
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }
}

// ==========================================
// 4. UI (INTERFACE)
// ==========================================

void main() {
  runApp(const WeldMasterApp());
}

class WeldMasterApp extends StatelessWidget {
  const WeldMasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => WeldingState())],
      child: MaterialApp(
        title: 'WeldMaster V7',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: AppColors.background,
          fontFamily: 'Roboto',
          colorScheme: const ColorScheme.dark(primary: AppColors.accent, surface: AppColors.surface),
          useMaterial3: true,
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const Text('WeldMaster V7 (Excel)', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              StopwatchCard(),
              SizedBox(height: 20),
              InputsCard(),
              SizedBox(height: 20),
              ResultCard(),
              SizedBox(height: 20),
              ActionsSection(),
              SizedBox(height: 20),
              HistorySection(),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class StopwatchCard extends StatelessWidget {
  const StopwatchCard({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(
      builder: (context, state, child) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.surfaceLight)),
          child: Column(children: [
            const Text('CHRONOMÈTRE', style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(state.time.toStringAsFixed(1), style: const TextStyle(fontSize: 70, fontWeight: FontWeight.bold, color: AppColors.accent, fontFamily: 'monospace')),
              const Padding(padding: EdgeInsets.only(bottom: 12.0, left: 4), child: Text("s", style: TextStyle(fontSize: 24, color: AppColors.textMuted))),
            ]),
            if (!state.isRunning)
              TextButton.icon(onPressed: () => _showEditDialog(context, state), icon: const Icon(Icons.edit, size: 16, color: AppColors.textMuted), label: const Text("Corriger", style: TextStyle(color: AppColors.textMuted))),
            const SizedBox(height: 20),
            Row(children: [
              IconButton(onPressed: (state.isRunning && state.time > 0) ? null : state.resetTimer, icon: const Icon(Icons.refresh), style: IconButton.styleFrom(backgroundColor: AppColors.surfaceLight, padding: const EdgeInsets.all(16))),
              const SizedBox(width: 16),
              Expanded(child: ElevatedButton.icon(onPressed: state.toggleTimer, icon: Icon(state.isRunning ? Icons.pause : Icons.play_arrow), label: Text(state.isRunning ? "ARRÊTER" : "SOUDER"), style: ElevatedButton.styleFrom(backgroundColor: state.isRunning ? Colors.redAccent : AppColors.accent, foregroundColor: state.isRunning ? Colors.white : AppColors.background, padding: const EdgeInsets.symmetric(vertical: 16)))),
            ])
          ]),
        );
      },
    );
  }
  void _showEditDialog(BuildContext context, WeldingState state) {
    final controller = TextEditingController(text: state.time.toStringAsFixed(1));
    showDialog(context: context, builder: (ctx) => AlertDialog(backgroundColor: AppColors.surface, title: const Text("Temps manuel", style: TextStyle(color: Colors.white)), content: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: const TextStyle(color: Colors.white), autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")), ElevatedButton(onPressed: () { final val = double.tryParse(controller.text.replaceAll(',', '.')); if (val != null) state.manualSetTime(val); Navigator.pop(ctx); }, child: const Text("Valider"))]));
  }
}

class InputsCard extends StatelessWidget {
  const InputsCard({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PARAMÈTRES', style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Consumer<WeldingState>(builder: (context, state, _) => DropdownButtonFormField<WeldingProcess>(value: state.process, dropdownColor: AppColors.surface, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "Procédé", border: OutlineInputBorder()), items: WeldingProcess.values.map((p) => DropdownMenuItem(value: p, child: Text(p.label))).toList(), onChanged: (v) => state.setProcess(v!))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _SimpleInput(label: "Intensité (A)", icon: Icons.flash_on, onChanged: (v) => Provider.of<WeldingState>(context, listen: false).setCurrent(v))),
          const SizedBox(width: 16),
          Expanded(child: _SimpleInput(label: "Tension (V)", icon: Icons.electrical_services, onChanged: (v) => Provider.of<WeldingState>(context, listen: false).setVoltage(v))),
        ]),
        const SizedBox(height: 16),
        _SimpleInput(label: "Longueur (mm)", icon: Icons.straighten, onChanged: (v) => Provider.of<WeldingState>(context, listen: false).setLength(v)),
      ]),
    );
  }
}

class _SimpleInput extends StatelessWidget {
  final String label;
  final IconData icon;
  final Function(double) onChanged;
  const _SimpleInput({required this.label, required this.icon, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return TextField(keyboardType: const TextInputType.numberWithOptions(decimal: true), style: const TextStyle(color: Colors.white, fontSize: 18), onChanged: (v) => onChanged(double.tryParse(v.replaceAll(',', '.')) ?? 0), decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, color: AppColors.textMuted), contentPadding: const EdgeInsets.all(16)));
  }
}

class ResultCard extends StatelessWidget {
  const ResultCard({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(builder: (context, state, _) => Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [AppColors.surface, Color(0xFF0F172A)]), borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.surfaceLight)),
      child: Column(children: [
        const Text('ÉNERGIE DE SOUDAGE', style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold)),
        Text(state.heatInput?.toStringAsFixed(3) ?? "---", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
        const Text('kJ/mm', style: TextStyle(color: AppColors.textMuted)),
      ]),
    ));
  }
}

class ActionsSection extends StatelessWidget {
  const ActionsSection({super.key});
  @override
  Widget build(BuildContext context) {
    const apiKey = String.fromEnvironment('API_KEY');
    return Consumer<WeldingState>(builder: (context, state, _) {
      if (state.heatInput == null) return const SizedBox.shrink();
      return Row(children: [
        Expanded(child: ElevatedButton.icon(onPressed: state.savePass, icon: const Icon(Icons.save), label: const Text("SAUVER"), style: ElevatedButton.styleFrom(backgroundColor: AppColors.surfaceLight, foregroundColor: Colors.white, padding: const EdgeInsets.all(16)))),
        const SizedBox(width: 12),
        Expanded(child: ElevatedButton.icon(onPressed: state.isAnalyzing ? null : () => state.analyzeWeld(apiKey), icon: const Icon(Icons.auto_awesome), label: Text(state.isAnalyzing ? "..." : "IA"), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: const EdgeInsets.all(16)))),
      ]);
    });
  }
}

class HistorySection extends StatelessWidget {
  const HistorySection({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(builder: (context, state, _) {
      if (state.passes.isEmpty) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('HISTORIQUE (${state.passes.length})', style: const TextStyle(color: AppColors.textMuted)),
              TextButton.icon(
                onPressed: state.exportToExcel,
                icon: const Icon(Icons.download, size: 18, color: AppColors.success),
                label: const Text("Excel", style: TextStyle(color: AppColors.success, fontWeight: FontWeight.bold)),
                style: TextButton.styleFrom(backgroundColor: AppColors.success.withOpacity(0.1)),
              )
            ],
          ),
          const SizedBox(height: 10),
          ...state.passes.map((p) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text("${p.heatInput.toStringAsFixed(3)} kJ/mm", style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
            subtitle: Text("${p.process.label.split(' ')[0]} - ${DateFormat('HH:mm').format(p.date)}", style: const TextStyle(color: Colors.white)),
            trailing: IconButton(icon: const Icon(Icons.delete, color: AppColors.error), onPressed: () => state.deletePass(p.id)),
          )),
        ]),
      );
    });
  }
}