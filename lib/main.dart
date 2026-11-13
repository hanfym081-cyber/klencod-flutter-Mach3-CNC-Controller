import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const Mach3CloneApp());
}

class Mach3CloneApp extends StatelessWidget {
  const Mach3CloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 CNC Mill',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1A1D24),
        useMaterial3: false,
      ),
      home: const Mach3MainScreen(),
    );
  }
}

class GPoint {
  final double x;
  final double y;
  final double z;
  final double a;
  final bool rapid;
  final int lineIndex;
  final double feed;
  final double spindle;
  const GPoint(this.x, this.y, this.z, this.a, this.rapid, this.lineIndex, this.feed, this.spindle);
}

class GCodeResult {
  final List<GPoint> points;
  final List<String> rawLines;
  final int lines;
  final int movements;
  final double distance;
  const GCodeResult({
    required this.points,
    required this.rawLines,
    required this.lines,
    required this.movements,
    required this.distance,
  });
}

class GCodeParser {
  static GCodeResult parse(String source) {
    final points = <GPoint>[];
    final rawLines = source.split(RegExp(r'\r?\n'));
    double x = 0, y = 0, z = 0, a = 0;
    double currentFeed = 100.0;
    double currentSpindle = 12000.0;
    double scale = 1;
    bool absolute = true;
    bool rapid = false;
    double distance = 0;
    int movements = 0;

    for (int i = 0; i < rawLines.length; i++) {
      String line = rawLines[i].toUpperCase();
      line = line.replaceAll(RegExp(r'\([^)]*\)'), '');
      line = line.split(';').first;
      line = line.replaceAll(RegExp(r'\s+'), '');
      if (line.isEmpty) continue;

      final words = RegExp(r'([A-Z])([-+]?\d*\.?\d+)').allMatches(line);
      final values = <String, double>{};
      for (final match in words) {
        values[match.group(1)!] = double.tryParse(match.group(2)!) ?? 0;
      }

      if (values.containsKey('G')) {
        final g = values['G']!;
        if (g == 20) scale = 25.4;
        if (g == 21) scale = 1;
        if (g == 90) absolute = true;
        if (g == 91) absolute = false;
        if (g == 0) rapid = true;
        if (g == 1) rapid = false;
      }

      if (values.containsKey('F')) currentFeed = values['F']!;
      if (values.containsKey('S')) currentSpindle = values['S']!;

      if (values.containsKey('X') || values.containsKey('Y') || values.containsKey('Z') || values.containsKey('A')) {
        final oldX = x, oldY = y, oldZ = z;
        if (values.containsKey('X')) x = absolute ? (values['X']! * scale) : x + (values['X']! * scale);
        if (values.containsKey('Y')) y = absolute ? (values['Y']! * scale) : y + (values['Y']! * scale);
        if (values.containsKey('Z')) z = absolute ? (values['Z']! * scale) : z + (values['Z']! * scale);
        if (values.containsKey('A')) a = absolute ? values['A']! : a + values['A']!;

        distance += math.sqrt(math.pow(x - oldX, 2) + math.pow(y - oldY, 2) + math.pow(z - oldZ, 2));
        movements++;
        points.add(GPoint(x, y, z, a, rapid, i, currentFeed, currentSpindle));
      }
    }
    return GCodeResult(
      points: points,
      rawLines: rawLines,
      lines: rawLines.length,
      movements: movements,
      distance: distance,
    );
  }
}

class Mach3MainScreen extends StatefulWidget {
  const Mach3MainScreen({super.key});

  @override
  State<Mach3MainScreen> createState() => _Mach3MainScreenState();
}

class _Mach3MainScreenState extends State<Mach3MainScreen> {
  int currentTab = 0;
  String fileName = 'No File Loaded';
  String gcode = '';
  GCodeResult? result;

  bool connected = false;
  Socket? pcSocket;
  String pcIp = '192.168.1.100';
  int pcPort = 50002;

  double droX = 0.0000;
  double droY = 0.0000;
  double droZ = 0.0000;
  double droA = 0.0000;
  
  bool machineCoords = false;
  bool estop = true; 
  bool spindleOn = false;
  bool offline = false;
  bool softLimits = false;
  
  double currentFeedRate = 100.0;
  double spindleRpm = 12000.0;
  int feedOverride = 100;
  int rapidOverride = 100;
  
  bool optionalStop = false;
  bool blockDelete = false;
  bool cvMode = true;
  bool floodCtrl = false;
  bool dwell = false;
  
  int currentTool = 0;
  double jogStep = 1.0;
  int targetLineNumber = 0;

  Timer? simulatorTimer;
  int simulatorIndex = 0;
  int activeLineIndex = -1;
  final ScrollController gcodeScrollController = ScrollController();
  final TextEditingController mdiController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadPreferences();
  }

  @override
  void dispose() {
    simulatorTimer?.cancel();
    pcSocket?.destroy();
    gcodeScrollController.dispose();
    super.dispose();
  }

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      pcIp = prefs.getString('pc_ip') ?? '192.168.1.100';
      pcPort = prefs.getInt('pc_port') ?? 50002;
    });
  }

  Future<void> savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pc_ip', pcIp);
    await prefs.setInt('pc_port', pcPort);
  }

  Future<void> connectToPC() async {
    try {
      pcSocket = await Socket.connect(pcIp, pcPort, timeout: const Duration(seconds: 4));
      setState(() => connected = true);
      pcSocket!.listen((data) {
        parsePcData(utf8.decode(data));
      }, onDone: () => disconnect(), onError: (_) => disconnect());
    } catch (_) {
      disconnect();
    }
  }

  void disconnect() {
    pcSocket?.destroy();
    pcSocket = null;
    setState(() => connected = false);
  }

  void sendCommand(String cmd) {
    if (connected && pcSocket != null) {
      pcSocket!.write('$cmd\n');
      return;
    }

    if (cmd == 'RESET') {
      setState(() {
        estop = !estop;
        if (estop) stopSimulation();
      });
    }

    if (estop && cmd != 'RESET') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('E-Stop is Active! Press RESET to enable motion.')),
      );
      return;
    }

    if (cmd == 'CYCLE_START') {
      startSimulation();
    } else if (cmd == 'FEED_HOLD' || cmd == 'STOP') {
      stopSimulation();
    } else if (cmd == 'REWIND') {
      stopSimulation();
      setState(() {
        simulatorIndex = 0;
        activeLineIndex = -1;
        droX = 0;
        droY = 0;
        droZ = 0;
        droA = 0;
        currentFeedRate = 100.0;
        spindleRpm = 12000.0;
      });
    } else if (cmd == 'REF_ALL_HOME') {
      setState(() {
        droX = 0.0;
        droY = 0.0;
        droZ = 0.0;
        droA = 0.0;
      });
    } else if (cmd == 'ZERO:X') setState(() => droX = 0.0);
    else if (cmd == 'ZERO:Y') setState(() => droY = 0.0);
    else if (cmd == 'ZERO:Z') setState(() => droZ = 0.0);
    else if (cmd == 'ZERO:4') setState(() => droA = 0.0);
    else if (cmd == 'JOG:X+') setState(() => droX += jogStep);
    else if (cmd == 'JOG:X-') setState(() => droX -= jogStep);
    else if (cmd == 'JOG:Y+') setState(() => droY += jogStep);
    else if (cmd == 'JOG:Y-') setState(() => droY -= jogStep);
    else if (cmd == 'JOG:Z+') setState(() => droZ += jogStep);
    else if (cmd == 'JOG:Z-') setState(() => droZ -= jogStep);
    else if (cmd == 'GOTO_ZERO') setState(() { droX = 0; droY = 0; droZ = 0; droA = 0; });
    else if (cmd == 'SPINDLE_TOGGLE') setState(() => spindleOn = !spindleOn);
  }

  bool get isSimulating => simulatorTimer?.isActive ?? false;

  void startSimulation() {
    if (result == null || result!.points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No G-Code file loaded for simulation!')));
      return;
    }
    if (isSimulating) return;

    int interval = (100 / (feedOverride == 0 ? 100 : feedOverride) * 80).round();

    simulatorTimer = Timer.periodic(Duration(milliseconds: math.max(15, interval)), (timer) {
      if (simulatorIndex >= result!.points.length) {
        stopSimulation();
        return;
      }
      final pt = result!.points[simulatorIndex];
      setState(() {
        droX = pt.x;
        droY = pt.y;
        droZ = pt.z;
        droA = pt.a;
        currentFeedRate = pt.feed;
        spindleRpm = pt.spindle;
        activeLineIndex = pt.lineIndex;
        simulatorIndex++;
      });

      // --- تمرير مستقر وثابت تماماً لمنع هروب المؤشر للأعلى ---
      if (gcodeScrollController.hasClients && activeLineIndex >= 0) {
        double targetScroll = (activeLineIndex * 18.0) - 70.0;
        if (targetScroll < 0) targetScroll = 0;
        if (targetScroll > gcodeScrollController.position.maxScrollExtent) {
          targetScroll = gcodeScrollController.position.maxScrollExtent;
        }
        gcodeScrollController.jumpTo(targetScroll);
      }
    });
    setState(() {});
  }

  void stopSimulation() {
    simulatorTimer?.cancel();
    setState(() {});
  }

  void parsePcData(String data) {
    try {
      if (data.startsWith('DRO:')) {
        final parts = data.substring(4).trim().split(';');
        for (var p in parts) {
          if (p.startsWith('X=')) droX = double.parse(p.substring(2));
          if (p.startsWith('Y=')) droY = double.parse(p.substring(2));
          if (p.startsWith('Z=')) droZ = double.parse(p.substring(2));
          if (p.startsWith('ESTOP=')) estop = p.substring(6) == '1';
        }
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> openFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['nc', 'tap', 'txt', 'gcode', 'cnc'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;

      final content = String.fromCharCodes(bytes);
      final parsed = GCodeParser.parse(content);
      setState(() {
        fileName = file.name;
        gcode = content;
        result = parsed;
        simulatorIndex = 0;
        activeLineIndex = -1;
      });
      if (connected) sendCommand('LOAD_FILE:${file.name}');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // --- شريط القوائم العلوي المطابق للصورة تماماً ---
            Container(
              height: 24,
              color: const Color(0xFF2B303B),
              child: Row(
                children: [
                  menuLabel('File'),
                  menuLabel('Config'),
                  menuLabel('Function Cfg\'s'),
                  menuLabel('View'),
                  menuLabel('Wizards'),
                  menuLabel('Operator'),
                  menuLabel('Plugin Control'),
                  menuLabel('Help'),
                  const Spacer(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('Mill->G15 G80 G17 G40 G20 G90 G94 G54 G49 G99 G64 G97', style: TextStyle(fontSize: 8, fontFamily: 'monospace', color: Colors.amberAccent)),
                  ),
                ],
              ),
            ),
            // --- شريط التبويبات (Tabs) والـ Modals ---
            Container(
              height: 28,
              color: const Color(0xFF232731),
              child: Row(
                children: [
                  machTab(0, 'Program Run (Alt-1)'),
                  machTab(1, 'MDI (Alt-2)'),
                  machTab(2, 'Tool Path (Alt-4)'),
                  machTab(3, 'Offsets (Alt-5)'),
                  machTab(4, 'Settings (Alt-6)'),
                  machTab(5, 'Diagnostics (Alt-7)'),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    margin: const EdgeInsets.only(right: 6),
                    color: isSimulating ? Colors.amber.shade800 : (connected ? Colors.green.shade800 : Colors.blueGrey.shade800),
                    child: Text(
                      isSimulating ? 'SIMULATING...' : (connected ? 'ONLINE' : 'OFFLINE'),
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: currentTab,
                children: [
                  buildProgramRunTab(),
                  buildMdiTab(),
                  buildFullToolpathTab(),
                  buildOffsetsTab(),
                  buildSettingsTab(),
                  buildDiagnosticsTab(),
                ],
              ),
            ),
            // --- شريط الحالة السفلي المطابق ---
            Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              color: const Color(0xFF111318),
              child: Row(
                children: [
                  smallBtn('History', () {}),
                  const SizedBox(width: 4),
                  smallBtn('Clear', () {}),
                  const SizedBox(width: 8),
                  const Text('Status: ', style: TextStyle(color: Colors.amber, fontSize: 9, fontWeight: FontWeight.bold)),
                  const Expanded(child: Text('ReConfiguration Estop.', style: TextStyle(color: Colors.white60, fontSize: 9))),
                  Text('Profile: Kickstarter CNC', style: TextStyle(color: Colors.cyanAccent, fontSize: 9)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget menuLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(text, style: const TextStyle(fontSize: 9, color: Colors.white70)),
    );
  }

  Widget machTab(int index, String label) {
    bool isSelected = currentTab == index;
    return InkWell(
      onTap: () => setState(() => currentTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF434C5E) : const Color(0xFF2B303B),
          border: Border(
            right: const BorderSide(color: Colors.black54, width: 1),
            top: BorderSide(color: isSelected ? Colors.amber : Colors.transparent, width: 2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.amberAccent : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget buildProgramRunTab() {
    return Padding(
      padding: const EdgeInsets.all(3.0),
      child: Row(
        children: [
          // ==================== العمود الأيسر: شاشة الأكواد وأزرار التشغيل ====================
          Expanded(
            flex: 35,
            child: Column(
              children: [
                Container(
                  height: 18,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  color: const Color(0xFF2B303B),
                  child: Text('File: $fileName', style: const TextStyle(fontSize: 9, color: Colors.amberAccent)),
                ),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0C10),
                      border: Border.all(color: Colors.grey.shade700, width: 1),
                    ),
                    child: result == null || result!.rawLines.isEmpty
                        ? const Center(child: Text('No G-Code Loaded', style: TextStyle(color: Colors.white54, fontSize: 10)))
                        : ListView.builder(
                            controller: gcodeScrollController,
                            itemCount: result!.rawLines.length,
                            itemBuilder: (context, index) {
                              bool isActive = index == activeLineIndex;
                              return Container(
                                height: 18,
                                color: isActive ? Colors.blue.shade900 : Colors.transparent,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  result!.rawLines[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 9,
                                    color: isActive ? Colors.white : Colors.lightGreenAccent,
                                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 2),
                // لوحة الأزرار اليسرى السفلى المطابقة للصورة تماماً
                Container(
                  height: 145,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232731),
                    border: Border.all(color: Colors.grey.shade700),
                  ),
                  child: Row(
                    children: [
                      // أزرار Cycle Start / Feed Hold / Stop الكبيرة
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: [
                            Expanded(child: classicMachBtn('Cycle Start\n<Alt-R>', Colors.green.shade800, () => sendCommand('CYCLE_START'))),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Feed Hold\n<Spc>', Colors.amber.shade800, () => sendCommand('FEED_HOLD'))),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Stop\n<Alt-S>', Colors.red.shade900, () => sendCommand('STOP'))),
                          ],
                        ),
                      ),
                      const SizedBox(width: 3),
                      // أزرار تحرير ومعالجة الملف
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            Expanded(child: classicMachBtn('Edit G-Code', const Color(0xFF333B48), () {})),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Recent File', const Color(0xFF333B48), () {})),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Close G-Code', const Color(0xFF333B48), () {})),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Load G-Code', const Color(0xFF333B48), openFile)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 3),
                      // أزرار التراجع والخطوط
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            Expanded(child: classicMachBtn('Rewind Ctrl-W', const Color(0xFF333B48), () => sendCommand('REWIND'))),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Single BLK Alt-N', const Color(0xFF333B48), () {})),
                            const SizedBox(height: 2),
                            Expanded(child: classicMachBtn('Reverse Run', const Color(0xFF333B48), () {})),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Text('Line ', style: TextStyle(fontSize: 8)),
                                Expanded(
                                  child: Container(
                                    height: 18,
                                    alignment: Alignment.center,
                                    color: Colors.black,
                                    child: Text('$targetLineNumber', style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.cyanAccent)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                // شريط أزرار الطوارئ والفلتر السفلي الأيسر المطابق للصورة
                Container(
                  height: 38,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232731),
                    border: Border.all(color: Colors.grey.shade700),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: GestureDetector(
                          onTap: () => sendCommand('RESET'),
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: estop ? Colors.red.shade700 : Colors.green.shade700,
                              border: Border.all(color: Colors.amber),
                            ),
                            child: Text(estop ? 'Reset' : 'Active', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('Emergency Mode Ac', style: TextStyle(fontSize: 7, color: Colors.white70)),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: const [
                                Text('G-Codes', style: TextStyle(fontSize: 7, color: Colors.cyan)),
                                Text('M-Codes', style: TextStyle(fontSize: 7, color: Colors.cyan)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 3),
          // ==================== العمود الأيمن: الـ DROs والتحكم والأدوات والمغزل ====================
          Expanded(
            flex: 65,
            child: Column(
              children: [
                // الصف العلوي الأيمن: زر REF العمودي + شاشات الـ DROs الأربعة + أزرار التحكم الجانبية
                Expanded(
                  flex: 52,
                  child: Row(
                    children: [
                      // زر REF ALL HOME الرأسي الطويل
                      SizedBox(
                        width: 30,
                        child: classicMachBtn('R\nE\nF\n\nA\nL\nL\n\nH\nO\nM\nE', Colors.teal.shade800, () => sendCommand('REF_ALL_HOME')),
                      ),
                      const SizedBox(width: 3),
                      // شاشات الإحداثيات الأربعة (X, Y, Z, 4) المطابقة للصورة
                      Expanded(
                        flex: 6,
                        child: Column(
                          children: [
                            droBoxWithScale('X', droX, 1.0, () => sendCommand('ZERO:X')),
                            const SizedBox(height: 2),
                            droBoxWithScale('Y', droY, 1.0, () => sendCommand('ZERO:Y')),
                            const SizedBox(height: 2),
                            droBoxWithScale('Z', droZ, 1.0, () => sendCommand('ZERO:Z')),
                            const SizedBox(height: 2),
                            droBoxWithScale('4', droA, 1.0, () => sendCommand('ZERO:4')),
                            const SizedBox(height: 2),
                            // صف أزرار التحكم السفلية تحت الـ DROs
                            Row(
                              children: [
                                Expanded(child: smallMachBtn('OFFLINE', offline ? Colors.red : const Color(0xFF333B48), () => setState(() => offline = !offline))),
                                const SizedBox(width: 2),
                                Expanded(child: smallMachBtn('GOTO ZERO', const Color(0xFF333B48), () => sendCommand('GOTO_ZERO'))),
                                const SizedBox(width: 2),
                                Expanded(child: smallMachBtn('To Go', const Color(0xFF333B48), () {})),
                                const SizedBox(width: 2),
                                Expanded(child: smallMachBtn('Machine Coord\'s', machineCoords ? Colors.red.shade900 : const Color(0xFF333B48), () => setState(() => machineCoords = !machineCoords))),
                                const SizedBox(width: 2),
                                Expanded(child: smallMachBtn('Soft Limits', softLimits ? Colors.green : const Color(0xFF333B48), () => setState(() => softLimits = !softLimits))),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 3),
                      // اللوحة الجانبية اليمنى العليا (Tool:0 وباقي الأزرار)
                      SizedBox(
                        width: 85,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(2),
                                color: Colors.black,
                                child: Text('Tool:$currentTool', style: const TextStyle(fontSize: 10, color: Colors.amberAccent, fontFamily: 'monospace')),
                              ),
                              const Spacer(),
                              classicMachBtn('Load Wizards', const Color(0xFF333B48), () {}, height: 22),
                              const SizedBox(height: 2),
                              classicMachBtn('NFS Wizards', const Color(0xFF333B48), () {}, height: 20),
                              const SizedBox(height: 2),
                              classicMachBtn('Last Wizard', const Color(0xFF333B48), () {}, height: 22),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Expanded(child: smallMachBtn('Regen. Toolpath', const Color(0xFF333B48), () {}, height: 24)),
                                  const SizedBox(width: 2),
                                  Expanded(child: smallMachBtn('Display Mode', const Color(0xFF333B48), () {}, height: 24)),
                                  const SizedBox(width: 2),
                                  Expanded(child: smallMachBtn('Jog Follow', const Color(0xFF333B48), () {}, height: 24)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                // ==================== الصف السفلي الأيمن: Tool Info + Feed Rate + Spindle Speed ====================
                Expanded(
                  flex: 48,
                  child: Row(
                    children: [
                      // 1. صندوق معلومات الأداة (Tool Information)
                      Expanded(
                        flex: 32,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Tool Information', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber)),
                              const Divider(height: 3, color: Colors.white24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Tool  $currentTool', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                  smallBtn('Change Tool', () => setState(() => currentTool = currentTool == 0 ? 1 : 0)),
                                ],
                              ),
                              Text('Dia. +${currentTool == 1 ? '0.1250' : '0.0000'}', style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.cyanAccent)),
                              Text('H  +0.0000', style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.cyanAccent)),
                              const Divider(height: 4, color: Colors.white24),
                              smallBtn('Auto Tool Zero', () {}),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Expanded(child: smallBtn('Remember', () {})),
                                  const SizedBox(width: 2),
                                  Expanded(child: smallBtn('Return', () {})),
                                ],
                              ),
                              const Spacer(),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Elapsed', style: TextStyle(fontSize: 8, color: Colors.white70)),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    color: Colors.black,
                                    child: const Text('00:00', style: TextStyle(fontSize: 9, color: Colors.redAccent, fontFamily: 'monospace')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              smallBtn('Jog ON/OFF Ctrl-Alt-J', () {}),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      // 2. صندوق معدل التغذية (Feed Rate) المطابق للصورة تماماً
                      Expanded(
                        flex: 34,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Feed Rate', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                                  InkWell(
                                    onTap: () => setState(() => cvMode = !cvMode),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                      color: cvMode ? Colors.green.shade800 : Colors.blueGrey.shade800,
                                      child: Text(cvMode ? 'CV Mode' : 'Exact Stop', style: const TextStyle(fontSize: 7)),
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 2, color: Colors.white24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('OverRidden', style: TextStyle(fontSize: 8, color: Colors.white60)),
                                  Text('FRO % $feedOverride', style: const TextStyle(fontSize: 9, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Rapid FRO', style: TextStyle(fontSize: 8, color: Colors.white60)),
                                  Row(
                                    children: [
                                      smallBtn('50%', () => setState(() => feedOverride = 50)),
                                      smallBtn('100%', () => setState(() => feedOverride = 100)),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Expanded(child: smallBtn('FRO 100', () => setState(() => feedOverride = 100))),
                                  const SizedBox(width: 2),
                                  Expanded(child: smallBtn('Reset', () => setState(() => feedOverride = 100))),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text('FRO: ${currentFeedRate.toStringAsFixed(2)}', style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.white)),
                              Text('Feedrate: ${currentFeedRate.toStringAsFixed(2)}', style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.white)),
                              const Divider(height: 3, color: Colors.white12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Units/Min', style: TextStyle(fontSize: 8)),
                                  Text(currentFeedRate.toStringAsFixed(2), style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.cyanAccent)),
                                ],
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Units/Rev', style: TextStyle(fontSize: 8)),
                                  const Text('0.00', style: TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.cyanAccent)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      // 3. صندوق سرعة المغزل (Spindle Speed) المطابق للصورة تماماً
                      Expanded(
                        flex: 34,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Spindle Speed', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber)),
                                  const Text('SRO % 100', style: TextStyle(fontSize: 8, color: Colors.greenAccent)),
                                ],
                              ),
                              const Divider(height: 2, color: Colors.white24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Spindle CW F5', style: TextStyle(fontSize: 8, color: Colors.white70)),
                                  classicMachBtn(
                                    spindleOn ? 'ON' : 'OFF',
                                    spindleOn ? Colors.amber.shade800 : const Color(0xFF333B48),
                                    () => sendCommand('SPINDLE_TOGGLE'),
                                    height: 18,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Expanded(child: smallBtn('Reset', () => setState(() => spindleRpm = 12000))),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Text('RPM  ', style: TextStyle(fontSize: 9, color: Colors.white70)),
                                  Expanded(
                                    child: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      color: Colors.black,
                                      child: Text('${spindleRpm.toInt()}', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.cyanAccent)),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  const Text('S-ov  ', style: TextStyle(fontSize: 9, color: Colors.white70)),
                                  Expanded(
                                    child: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      color: Colors.black,
                                      child: const Text('0', style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.cyanAccent)),
                                    ),
                                  ),
                                ],
                              ),
                              const Spacer(),
                              const Text('Spindle Speed', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                              Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                color: Colors.black,
                                child: Text('${spindleRpm.toInt()}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.cyanAccent)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ودجت شاشة الـ DRO ومعها أزرار الـ Zero والـ Scale المطابقة للصورة
  Widget droBoxWithScale(String axis, double value, double scaleVal, VoidCallback onZero) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: machineCoords ? Colors.redAccent : Colors.grey.shade600, width: 1.2),
      ),
      child: Row(
        children: [
          // زر الـ Zero والاسم
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                onTap: onZero,
                child: Text('Zero', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
              ),
              Text(axis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
          const SizedBox(width: 4),
          // قيمة الـ DRO الرقمية الخضراء الكبيرة
          Expanded(
            child: Text(
              value.toStringAsFixed(4),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: machineCoords ? Colors.redAccent : const Color(0xFF00FF41),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // صندوق الـ Scale الجانبي تماماً مثل الصورة
          SizedBox(
            width: 55,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('Scale', style: TextStyle(fontSize: 7, color: Colors.white54)),
                Text('+${scaleVal.toStringAsFixed(4)}', style: const TextStyle(fontSize: 8, fontFamily: 'monospace', color: Colors.amber)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget classicMachBtn(String text, Color bg, VoidCallback onTap, {double height = double.infinity}) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
        ),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget smallMachBtn(String text, Color bg, VoidCallback onTap, {double height = 22}) {
    return SizedBox(
      height: height,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
        ),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 7, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget smallBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFF333B48), border: Border.all(color: Colors.white24)),
        child: Text(label, style: const TextStyle(fontSize: 7, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget buildMdiTab() => Padding(padding: const EdgeInsets.all(10), child: TextField(controller: mdiController, decoration: const InputDecoration(labelText: 'MDI Command')));
  Widget buildFullToolpathTab() => const Center(child: Text('Full Toolpath View'));
  Widget buildOffsetsTab() => const Center(child: Text('Offsets View'));
  Widget buildSettingsTab() => const Center(child: Text('Settings View'));
  Widget buildDiagnosticsTab() => const Center(child: Text('Diagnostics View'));
}
