import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

// ==========================================
// 1. CONSTANTS & THEME
// ==========================================

class AppColors {
  static const Color background = Color(0xFF0F172A); 
  static const Color surface = Color(0xFF1E293B);    
  static const Color surfaceLight = Color(0xFF334155); 
  static const Color textMain = Color(0xFFF1F5F9);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color accent = Color(0xFFF59E0B);      
  static const Color accentHover = Color(0xFFD97706);
  static const Color error = Color(0xFFEF4444);
}

// ==========================================
// 2. MODELS
// ==========================================

enum WeldingProcess {
  MMA,
  MIG_MAG,
  TIG,
  SAW,
  FCAW,
}

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
  final DateTime timestamp;
  final WeldingProcess process;
  final double current;
  final double voltage;
  final double length;
  final double time;
  final double heatInput;
  final double kFactor;

  WeldingPass({
    required this.id,
    required this.timestamp,
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
// 3. STATE MANAGEMENT (PROVIDER)
// ==========================================

class WeldingState extends ChangeNotifier {
  // Parameters
  WeldingProcess _process = WeldingProcess.MIG_MAG;
  double _voltage = 0.0;
  double _current = 0.0;
  double _length = 0.0;
  
  // --- NOUVELLE LOGIQUE SIMPLE ---
  // On abandonne le Stopwatch complexe. On fait un compteur simple.
  Timer? _timer;
  double _time = 0.0; 
  bool _isRunning = false;

  // Getters
  WeldingProcess get process => _process;
  double get voltage => _voltage;
  double get current => _current;
  double get length => _length;
  double get time => _time;
  bool get isRunning => _isRunning;
  
  // History & AI
  final List<WeldingPass> _passes = [];
  String? _aiAnalysis;
  bool _isAnalyzing = false;
  List<WeldingPass> get passes => _passes;
  String? get aiAnalysis => _aiAnalysis;
  bool get isAnalyzing => _isAnalyzing;

  // Derived Values
  double? get heatInput {
    if (_time > 0 && _length > 0) {
      return (_process.efficiency * _voltage * _current * _time) / (_length * 1000);
    }
    return null;
  }

  double? get power => _voltage * _current; 
  double? get travelSpeed => (_time > 0) ? _length / _time : null; 

  // Setters
  void setProcess(WeldingProcess p) { _process = p; notifyListeners(); }
  void setVoltage(double v) { _voltage = v; notifyListeners(); }
  void setCurrent(double c) { _current = c; notifyListeners(); }
  void setLength(double l) { _length = l; notifyListeners(); }
  
  // --- LOGIQUE CHRONO SIMPLIFIÉE ---
  void toggleTimer() {
    if (_isRunning) {
      _stopTimer();
    } else {
      _startTimer();
    }
  }

  void _startTimer() {
    _isRunning = true;
    // Ajoute 0.1 seconde toutes les 100ms. Impossible de se tromper.
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _time += 0.1; 
      notifyListeners();
    });
    notifyListeners();
  }

  void _stopTimer() {
    _timer?.cancel();
    _isRunning = false;
    // On NE touche PAS à la variable _time ici. Elle reste telle quelle.
    notifyListeners();
  }

  void resetTimer() {
    _stopTimer(); // Arrête d'abord
    _time = 0.0;  // Puis remet à 0
    notifyListeners();
  }

  void manualUpdateTime(double newTime) {
    if (!_isRunning) {
      _time = newTime;
      notifyListeners();
    }
  }
  // ---------------------------------

  // History Methods
  void savePass() {
    if (heatInput == null) return;
    
    final pass = WeldingPass(
      id: const Uuid().v4(),
      timestamp: DateTime.now(),
      process: _process,
      current: _current,
      voltage: _voltage,
      length: _length,
      time: _time,
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

  // AI Analysis
  Future<void> analyzeWeld(String apiKey) async {
    if (heatInput == null) return;

    _isAnalyzing = true;
    _aiAnalysis = null;
    notifyListeners();

    try {
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: apiKey,
      );

      final prompt = '''
        Agis comme un expert ingénieur en soudage certifié IWE.
        Analyse ces paramètres:
        Procédé: ${_process.label}
        Tension: $_voltage V
        Courant: $_current A
        Longueur: $_length mm
        Temps: ${_time.toStringAsFixed(1)} s
        
        RÉSULTATS:
        Énergie: ${heatInput!.toStringAsFixed(3)} kJ/mm
        Vitesse: ${(travelSpeed! * 60 / 10).toStringAsFixed(1)} cm/min
        
        Analyse concise (max 200 mots) en Français Markdown:
        1. Pertinence pour acier carbone S355.
        2. Stabilité de l'arc.
        3. Sécurité.
      ''';

      final content = [Content.text(prompt)];
      final response = await model.generateContent(content);
      
      _aiAnalysis = response.text;
    } catch (e) {
      _aiAnalysis = "Erreur: Impossible de contacter Gemini. Vérifiez votre clé API.\n${e.toString()}";
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }
}

// ==========================================
// 4. UI COMPONENTS
// ==========================================

void main() {
  runApp(const WeldMasterApp());
}

class WeldMasterApp extends StatelessWidget {
  const WeldMasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WeldingState()),
      ],
      child: MaterialApp(
        title: 'WeldMaster V4',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: AppColors.background,
          fontFamily: 'Roboto',
          colorScheme: const ColorScheme.dark(
            primary: AppColors.accent,
            surface: AppColors.surface,
            background: AppColors.background,
          ),
          useMaterial3: true,
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.surfaceLight),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.surfaceLight),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.accent),
            ),
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
        backgroundColor: AppColors.background.withOpacity(0.9),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.accent, Colors.redAccent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.local_fire_department, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'WeldMaster V4', // CHANGEMENT DU NOM POUR VÉRIFIER
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                Text(
                  'Assistant de Soudage',
                  style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              StopwatchCard(),
              SizedBox(height: 24),
              InputsCard(),
              SizedBox(height: 24),
              ResultCard(),
              SizedBox(height: 24),
              ActionsSection(),
              SizedBox(height: 24),
              HistorySection(),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class ResultCard extends StatelessWidget {
  const ResultCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(
      builder: (context, state, child) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.surface, Color(0xFF0F172A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.surfaceLight),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 15,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ÉNERGIE DE SOUDAGE',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    state.heatInput != null ? state.heatInput!.toStringAsFixed(3) : '---',
                    style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  const Text('kJ/mm', style: TextStyle(fontSize: 20, color: AppColors.textMuted)),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _MiniStat(
                      label: 'Facteur k',
                      value: state.process.efficiency.toString(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MiniStat(
                      label: 'Puissance',
                      value: state.power != null ? '${(state.power! / 1000).toStringAsFixed(1)} kW' : '-',
                    ),
                  ),
                ],
              )
            ],
          ),
        );
      },
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: AppColors.textMain, fontSize: 16, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class StopwatchCard extends StatefulWidget {
  const StopwatchCard({super.key});

  @override
  State<StopwatchCard> createState() => _StopwatchCardState();
}

class _StopwatchCardState extends State<StopwatchCard> {
  late TextEditingController _manualTimeController;

  @override
  void initState() {
    super.initState();
    _manualTimeController = TextEditingController();
  }

  @override
  void dispose() {
    _manualTimeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(
      builder: (context, state, child) {
        // Sync controller with state when stopped and not editing
        if (!state.isRunning && _manualTimeController.text != state.time.toStringAsFixed(1)) {
             if (!FocusScope.of(context).hasFocus) {
                 _manualTimeController.text = state.time.toStringAsFixed(1);
             }
        }

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.surfaceLight),
          ),
          child: Column(
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.timer_outlined, color: AppColors.textMuted, size: 16),
                  SizedBox(width: 8),
                  Text('CHRONOMÈTRE', style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ],
              ),
              const SizedBox(height: 16),
              
              // Time Display / Input
              state.isRunning
                  ? Text(
                      state.time.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: AppColors.accent, fontFamily: 'monospace'),
                    )
                  : IntrinsicWidth(
                      child: TextField(
                        controller: _manualTimeController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: "0.0",
                          hintStyle: TextStyle(color: AppColors.surfaceLight),
                          enabledBorder: InputBorder.none,
                          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
                        ),
                        onChanged: (val) {
                          final newVal = double.tryParse(val.replaceAll(',', '.'));
                          if (newVal != null) state.manualUpdateTime(newVal);
                        },
                      ),
                    ),
              
              Text(
                state.isRunning ? 'Mesure en cours...' : 'Touchez le temps pour corriger',
                style: TextStyle(color: state.isRunning ? Colors.redAccent : AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: (state.isRunning && state.time > 0) ? null : state.resetTimer,
                    icon: const Icon(Icons.refresh),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.surfaceLight,
                      foregroundColor: AppColors.textMuted,
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: state.toggleTimer,
                      icon: Icon(state.isRunning ? Icons.pause : Icons.play_arrow),
                      label: Text(state.isRunning ? "ARRÊTER" : (state.time > 0 ? "REPRENDRE" : "SOUDER")),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: state.isRunning ? Colors.redAccent : AppColors.accent,
                        foregroundColor: state.isRunning ? Colors.white : AppColors.background,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(50)),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              )
            ],
          ),
        );
      },
    );
  }
}

class InputsCard extends StatelessWidget {
  const InputsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.settings, color: AppColors.textMuted, size: 16),
              SizedBox(width: 8),
              Text('PARAMÈTRES', style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            ],
          ),
          const SizedBox(height: 24),
          
          // Process Selector
          _buildLabel('Procédé de soudage'),
          Consumer<WeldingState>(
            builder: (context, state, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceLight),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<WeldingProcess>(
                  value: state.process,
                  isExpanded: true,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  onChanged: (val) {
                    if (val != null) state.setProcess(val);
                  },
                  items: WeldingProcess.values.map((p) => DropdownMenuItem(
                    value: p,
                    child: Text(p.label),
                  )).toList(),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _NumberInput(
                label: 'Intensité (A)',
                icon: Icons.flash_on,
                iconColor: Colors.yellow,
                onChanged: (val) => Provider.of<WeldingState>(context, listen: false).setCurrent(val),
              )),
              const SizedBox(width: 16),
              Expanded(child: _NumberInput(
                label: 'Tension (V)',
                icon: Icons.electrical_services,
                iconColor: Colors.blueAccent,
                onChanged: (val) => Provider.of<WeldingState>(context, listen: false).setVoltage(val),
              )),
            ],
          ),
          const SizedBox(height: 16),
          _NumberInput(
            label: 'Longueur Soudée (mm)',
            icon: Icons.straighten,
            iconColor: Colors.greenAccent,
            suffix: 'mm',
            onChanged: (val) => Provider.of<WeldingState>(context, listen: false).setLength(val),
            helperText: "Mesurez après avoir arrêté le chrono",
          ),
        ],
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text, style: const TextStyle(color: AppColors.textMuted, fontSize: 14)),
    );
  }
}

class _NumberInput extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String? suffix;
  final Function(double) onChanged;
  final String? helperText;

  const _NumberInput({
    required this.label,
    required this.icon,
    required this.iconColor,
    this.suffix,
    required this.onChanged,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 14)),
            ],
          ),
        ),
        TextField(
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white, fontSize: 18, fontFamily: 'monospace'),
          onChanged: (val) {
            final num = double.tryParse(val.replaceAll(',', '.'));
            if (num != null) onChanged(num);
          },
          decoration: InputDecoration(
            hintText: "0",
            hintStyle: TextStyle(color: AppColors.surfaceLight.withOpacity(0.5)),
            suffixText: suffix,
            suffixStyle: const TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold),
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
        if (helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(helperText!, style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
          ),
      ],
    );
  }
}

class ActionsSection extends StatelessWidget {
  const ActionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    // La clé API est récupérée des variables d'environnement au moment du build
    const apiKey = String.fromEnvironment('API_KEY');

    return Consumer<WeldingState>(
      builder: (context, state, _) {
        final isValid = state.heatInput != null && state.heatInput! > 0;
        
        if (!isValid) return const SizedBox.shrink();

        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.savePass,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text("ENREGISTRER"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surfaceLight,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.isAnalyzing ? null : () {
                      if (apiKey.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Clé API manquante. Lancez avec --dart-define=API_KEY=..."))
                        );
                        return;
                      }
                      state.analyzeWeld(apiKey);
                    },
                    icon: state.isAnalyzing 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.auto_awesome),
                    label: Text(state.isAnalyzing ? "..." : "ANALYSER IA"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ],
            ),
            if (state.aiAnalysis != null)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.indigo.withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.auto_awesome, color: Colors.indigoAccent, size: 16),
                        SizedBox(width: 8),
                        Text("ANALYSE GEMINI", style: TextStyle(color: Colors.indigoAccent, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const Divider(color: AppColors.surfaceLight),
                    MarkdownBody(
                      data: state.aiAnalysis!,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(color: AppColors.textMain),
                        strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        listBullet: const TextStyle(color: AppColors.accent),
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

class HistorySection extends StatelessWidget {
  const HistorySection({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WeldingState>(
      builder: (context, state, _) {
        if (state.passes.isEmpty) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.surfaceLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.history, color: AppColors.textMuted, size: 16),
                  const SizedBox(width: 8),
                  Text('HISTORIQUE (${state.passes.length})', style: const TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ],
              ),
              const SizedBox(height: 16),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: state.passes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final pass = state.passes[index];
                  final passNumber = state.passes.length - index;
                  return _HistoryCard(pass: pass, number: passNumber, onDelete: () => state.deletePass(pass.id));
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final WeldingPass pass;
  final int number;
  final VoidCallback onDelete;

  const _HistoryCard({required this.pass, required this.number, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("PASSE #$number", style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                  Text(pass.process.label.split('(')[0].trim(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text("${pass.heatInput.toStringAsFixed(3)} kJ/mm", style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 16)),
                  Text("k = ${pass.kFactor}", style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _CompactStat("I", "${pass.current.toInt()} A"),
                _CompactStat("U", "${pass.voltage} V"),
                _CompactStat("L", "${pass.length.toInt()} mm"),
                _CompactStat("t", "${pass.time.toStringAsFixed(1)} s"),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.all(4.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline, size: 14, color: AppColors.error),
                    SizedBox(width: 4),
                    Text("Supprimer", style: TextStyle(color: AppColors.error, fontSize: 12)),
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  final String label;
  final String value;
  const _CompactStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace')),
      ],
    );
  }
}