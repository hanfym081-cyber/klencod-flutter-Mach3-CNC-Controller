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
  final bool rapid;
  final int lineIndex;
  const GPoint(this.x, this.y, this.z, this.rapid, this.lineIndex);
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
    double x = 0, y = 0, z = 0;
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

      if (values.containsKey('X') || values.containsKey('Y') || values.containsKey('Z')) {
        final oldX = x, oldY = y, oldZ = z;
        if (values.containsKey('X')) x = absolute ? (values['X']! * scale) : x + (values['X']! * scale);
        if (values.containsKey('Y')) y = absolute ? (values['Y']! * scale) : y + (values['Y']! * scale);
        if (values.containsKey('Z')) z = absolute ? (values['Z']! * scale) : z + (values['Z']! * scale);

        distance += math.sqrt(math.pow(x - oldX, 2) + math.pow(y - oldY, 2) + math.pow(z - oldZ, 2));
        movements++;
        points.add(GPoint(x, y, z, rapid, i));
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

  // Network & State
  bool connected = false;
  Socket? pcSocket;
  String pcIp = '192.168.1.100';
  int pcPort = 50002;

  // Live DROs & Machine Parameters
  double droX = 0.0000;
  double droY = 0.0000;
  double droZ = 0.0000;
  bool machineCoords = false;
  bool estop = true; 
  bool spindleOn = false;
  int spindleRpm = 12000;
  int feedOverride = 100;
  int rapidOverride = 100; // نسبة السرعة السريعة الجديدة
  bool optionalStop = false; // زر التوقف الاختياري الجديد
  bool blockDelete = false; // زر حذف الأسطر الجديد
  int currentTool = 1;
  double jogStep = 1.0;

  // Simulator State & Active Line Tracking
  Timer? simulatorTimer;
  int simulatorIndex = 0;
  int activeLineIndex = -1;
  bool isSimulating = false;
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
      });
    } else if (cmd == 'ZERO:X') setState(() => droX = 0.0);
    else if (cmd == 'ZERO:Y') setState(() => droY = 0.0);
    else if (cmd == 'ZERO:Z') setState(() => droZ = 0.0);
    else if (cmd == 'JOG:X+') setState(() => droX += jogStep);
    else if (cmd == 'JOG:X-') setState(() => droX -= jogStep);
    else if (cmd == 'JOG:Y+') setState(() => droY += jogStep);
    else if (cmd == 'JOG:Y-') setState(() => droY -= jogStep);
    else if (cmd == 'JOG:Z+') setState(() => droZ += jogStep);
    else if (cmd == 'JOG:Z-') setState(() => droZ -= jogStep);
    else if (cmd == 'GOTO_ZERO') setState(() { droX = 0; droY = 0; droZ = 0; });
    else if (cmd == 'SPINDLE_TOGGLE') setState(() => spindleOn = !spindleOn);
  }

  void startSimulation() {
    if (result == null || result!.points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No G-Code file loaded for simulation!')));
      return;
    }
    if (isSimulating) return;

    setState(() => isSimulating = true);
    int interval = (100 / (feedOverride == 0 ? 100 : feedOverride) * 100).round();

    simulatorTimer = Timer.periodic(Duration(milliseconds: math.max(20, interval)), (timer) {
      if (simulatorIndex >= result!.points.length) {
        stopSimulation();
        return;
      }
      final pt = result!.points[simulatorIndex];
      setState(() {
        droX = pt.x;
        droY = pt.y;
        droZ = pt.z;
        activeLineIndex = pt.lineIndex;
        simulatorIndex++;
      });

      if (gcodeScrollController.hasClients && activeLineIndex >= 0) {
        double offset = activeLineIndex * 18.0;
        if (offset < gcodeScrollController.position.maxScrollExtent) {
          gcodeScrollController.jumpTo(offset);
        }
      }
    });
  }

  void stopSimulation() {
    simulatorTimer?.cancel();
    setState(() => isSimulating = false);
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
            Container(
              height: 34,
              color: const Color(0xFF2B303B),
              child: Row(
                children: [
                  machTab(0, 'Program Run (Alt-1)'),
                  machTab(1, 'MDI (Alt-2)'),
                  machTab(2, 'ToolPath (Alt-4)'),
                  machTab(3, 'Offsets (Alt-5)'),
                  machTab(4, 'Settings (Alt-6)'),
                  machTab(5, 'Diagnostics (Alt-7)'),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    margin: const EdgeInsets.only(right: 6),
                    color: isSimulating ? Colors.amber.shade800 : (connected ? Colors.green.shade800 : Colors.blueGrey.shade800),
                    child: Text(
                      isSimulating ? 'SIMULATING...' : (connected ? 'PC LINK: ON' : 'SIMULATION MODE'),
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
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
            Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xFF111318),
              child: Row(
                children: [
                  const Text('Status: ', style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
                  Expanded(
                    child: Text(
                      estop ? 'Emergency Mode Active - Press RESET' : (isSimulating ? 'Running active line: $activeLineIndex' : 'Ready - Simulation Mode Active'),
                      style: TextStyle(color: estop ? Colors.redAccent : (isSimulating ? Colors.amberAccent : Colors.white70), fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  Text('File: $fileName', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget machTab(int index, String label) {
    bool isSelected = currentTab == index;
    return InkWell(
      onTap: () => setState(() => currentTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
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
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.amberAccent : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget buildProgramRunTab() {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        children: [
          // Column 1: G-Code Window & Cycle Buttons + Optional Stop / Block Delete
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0C10),
                      border: Border.all(color: Colors.grey.shade700, width: 1.5),
                    ),
                    child: result == null || result!.rawLines.isEmpty
                        ? const Center(child: Text('N10 G21 G90 G54\nN20 M3 S12000\n(Load G-Code file...)', style: TextStyle(color: Colors.white54, fontSize: 11)))
                        : ListView.builder(
                            controller: gcodeScrollController,
                            itemCount: result!.rawLines.length,
                            itemBuilder: (context, index) {
                              bool isActive = index == activeLineIndex;
                              return Container(
                                color: isActive ? Colors.blue.shade900 : Colors.transparent,
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 35,
                                      child: Text(
                                        '${index + 1}',
                                        style: TextStyle(fontSize: 10, color: isActive ? Colors.yellow : Colors.grey),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        result!.rawLines[index],
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          color: isActive ? Colors.white : Colors.lightGreenAccent,
                                          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                // Optional Stop & Block Delete Toggles
                Row(
                  children: [
                    Expanded(
                      child: classicMachBtn(
                        optionalStop ? 'Opt. Stop (ON)' : 'Opt. Stop (OFF)',
                        optionalStop ? Colors.amber.shade800 : const Color(0xFF333B48),
                        () => setState(() => optionalStop = !optionalStop),
                        height: 28,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: classicMachBtn(
                        blockDelete ? 'Block Del (ON)' : 'Block Del (OFF)',
                        blockDelete ? Colors.amber.shade800 : const Color(0xFF333B48),
                        () => setState(() => blockDelete = !blockDelete),
                        height: 28,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(child: classicMachBtn('Cycle Start\n<Alt-R>', Colors.green.shade800, () => sendCommand('CYCLE_START'))),
                    const SizedBox(width: 3),
                    Expanded(child: classicMachBtn('Feed Hold\n<Space>', Colors.amber.shade800, () => sendCommand('FEED_HOLD'))),
                    const SizedBox(width: 3),
                    Expanded(child: classicMachBtn('Stop\n<Alt-S>', Colors.red.shade900, () => sendCommand('STOP'))),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(child: classicMachBtn('Load G-Code', const Color(0xFF333B48), openFile)),
                    const SizedBox(width: 3),
                    Expanded(child: classicMachBtn('Rewind', const Color(0xFF333B48), () => sendCommand('REWIND'))),
                    const SizedBox(width: 3),
                    Expanded(child: classicMachBtn('Single BLK', const Color(0xFF333B48), () => sendCommand('SINGLE_BLK'))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),

          // Column 2: DROs, Home, Feed & Spindle & Rapid Overrides
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: const Color(0xFF232731),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: () => sendCommand('RESET'),
                          child: Container(
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: estop ? Colors.red.shade700 : Colors.green.shade700,
                              border: Border.all(color: estop ? Colors.amber : Colors.greenAccent, width: 2),
                            ),
                            child: Text(
                              estop ? 'RESET (E-STOP)' : 'RESET (ACTIVE)',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: classicMachBtn(
                          machineCoords ? 'Machine\nCoords' : 'Work\nCoords',
                          machineCoords ? Colors.red.shade800 : const Color(0xFF333B48),
                          () => setState(() => machineCoords = !machineCoords),
                          height: 36,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  droAxisRow('X', droX, () => sendCommand('ZERO:X')),
                  const SizedBox(height: 4),
                  droAxisRow('Y', droY, () => sendCommand('ZERO:Y')),
                  const SizedBox(height: 4),
                  droAxisRow('Z', droZ, () => sendCommand('ZERO:Z')),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(child: classicMachBtn('REF ALL HOME', Colors.teal.shade800, () => sendCommand('REF_ALL_HOME'), height: 32)),
                      const SizedBox(width: 4),
                      Expanded(child: classicMachBtn('Go To Zero', const Color(0xFF333B48), () => sendCommand('GOTO_ZERO'), height: 32)),
                    ],
                  ),
                  const Spacer(),

                  // Feed Rate, Rapid Override & Spindle Controls Panel
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161920),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      children: [
                        // Feed Rate Row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Feed FRO: $feedOverride%', style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                smallBtn('50%', () => setState(() => feedOverride = 50)),
                                smallBtn('100%', () => setState(() => feedOverride = 100)),
                                smallBtn('200%', () => setState(() => feedOverride = 200)),
                                smallBtn('+', () => setState(() => feedOverride = math.min(300, feedOverride + 10))),
                                smallBtn('-', () => setState(() => feedOverride = math.max(10, feedOverride - 10))),
                              ],
                            ),
                          ],
                        ),
                        const Divider(height: 4, color: Colors.white12),
                        // Rapid Override Row (جديد)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Rapid: $rapidOverride%', style: const TextStyle(fontSize: 10, color: Colors.cyanAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                smallBtn('25%', () => setState(() => rapidOverride = 25)),
                                smallBtn('50%', () => setState(() => rapidOverride = 50)),
                                smallBtn('100%', () => setState(() => rapidOverride = 100)),
                              ],
                            ),
                          ],
                        ),
                        const Divider(height: 4, color: Colors.white12),
                        // Spindle RPM Row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Spindle: $spindleRpm RPM', style: const TextStyle(fontSize: 10, color: Colors.amberAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                smallBtn('12k', () => setState(() => spindleRpm = 12000)),
                                smallBtn('+1k', () => setState(() => spindleRpm += 1000)),
                                smallBtn('-1k', () => setState(() => spindleRpm = math.max(0, spindleRpm - 1000))),
                                const SizedBox(width: 2),
                                classicMachBtn(
                                  spindleOn ? 'SPN ON' : 'SPN OFF',
                                  spindleOn ? Colors.amber.shade800 : const Color(0xFF333B48),
                                  () => sendCommand('SPINDLE_TOGGLE'),
                                  height: 22,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),

          // Column 3: Toolpath & Jog Controls
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.grey.shade700, width: 1.5),
                    ),
                    child: Stack(
                      children: [
                        result == null
                            ? const Center(child: Text('Toolpath Display', style: TextStyle(color: Colors.white24, fontSize: 11)))
                            : CustomPaint(painter: Mach3ToolpathPainter(result!.points), child: const SizedBox.expand()),
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Text('Tool #$currentTool', style: const TextStyle(color: Colors.amber, fontSize: 10, fontFamily: 'monospace')),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  flex: 4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232731),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Step: ${jogStep}mm', style: const TextStyle(fontSize: 10, color: Colors.cyanAccent)),
                            InkWell(
                              onTap: () => setState(() => jogStep = jogStep == 1.0 ? 0.1 : (jogStep == 0.1 ? 10.0 : 1.0)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                color: Colors.blueGrey.shade700,
                                child: const Text('Cycle Step', style: TextStyle(fontSize: 9)),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('Y+', () => sendCommand('JOG:Y+')),
                            const SizedBox(width: 16),
                            jogKey('Z+', () => sendCommand('JOG:Z+'), Colors.amber),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('X-', () => sendCommand('JOG:X-')),
                            const SizedBox(width: 4),
                            jogKey('X+', () => sendCommand('JOG:X+')),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('Y-', () => sendCommand('JOG:Y-')),
                            const SizedBox(width: 16),
                            jogKey('Z-', () => sendCommand('JOG:Z-'), Colors.amber),
                          ],
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget droAxisRow(String axis, double value, VoidCallback onZero) {
    return Row(
      children: [
        SizedBox(
          width: 58,
          height: 36,
          child: ElevatedButton(
            onPressed: onZero,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF333B48),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
            ),
            child: Text('Zero $axis', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: machineCoords ? Colors.redAccent : Colors.grey.shade600, width: 1.5),
            ),
            child: Text(
              value.toStringAsFixed(4),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: machineCoords ? Colors.redAccent : const Color(0xFF00FF41),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget classicMachBtn(String text, Color bg, VoidCallback onTap, {double height = 38}) {
    return SizedBox(
      height: height,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
    );
  }

  Widget smallBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFF333B48), border: Border.all(color: Colors.white24)),
        child: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget jogKey(String label, VoidCallback onTap, [Color color = Colors.cyanAccent]) {
    return SizedBox(
      width: 42,
      height: 26,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF161920),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: BorderSide(color: color.withOpacity(0.5))),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
      ),
    );
  }

  Widget buildMdiTab() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MDI - MANUAL DATA INPUT', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: mdiController,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 16, color: Color(0xFF00FF41)),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Colors.black,
                    hintText: 'Input G-Code command (e.g. G0 X50 Y50)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (val) {
                    sendCommand('MDI:$val');
                    mdiController.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              classicMachBtn('EXECUTE', Colors.green.shade800, () {
                sendCommand('MDI:${mdiController.text}');
                mdiController.clear();
              }, height: 54),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildFullToolpathTab() {
    return Container(
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: Colors.black, border: Border.all(color: Colors.grey.shade700, width: 2)),
      child: Stack(
        children: [
          result == null
              ? const Center(child: Text('No G-Code Program Loaded', style: TextStyle(color: Colors.white38)))
              : CustomPaint(painter: Mach3ToolpathPainter(result!.points), child: const SizedBox.expand()),
        ],
      ),
    );
  }

  Widget buildOffsetsTab() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ACTIVE WORK OFFSET (G54 - G59)', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var g in ['G54', 'G55', 'G56', 'G57', 'G58', 'G59'])
                      classicMachBtn(g, const Color(0xFF333B48), () => sendCommand('FIXTURE:$g')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSettingsTab() {
    final ipCtrl = TextEditingController(text: pcIp);
    final portCtrl = TextEditingController(text: pcPort.toString());

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PC WIFI CONNECTION SETTINGS', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                TextField(
                  controller: ipCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(labelText: 'PC IP Address', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: portCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(labelText: 'TCP Port', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    classicMachBtn('Save Config', const Color(0xFF333B48), () {
                      setState(() {
                        pcIp = ipCtrl.text.trim();
                        pcPort = int.tryParse(portCtrl.text.trim()) ?? 50002;
                      });
                      savePreferences();
                    }),
                    const SizedBox(width: 8),
                    classicMachBtn(
                      connected ? 'Disconnect PC' : 'Connect to PC',
                      connected ? Colors.red.shade800 : Colors.green.shade800,
                      connected ? disconnect : connectToPC,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildDiagnosticsTab() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('INPUT SIGNALS & DIAGNOSTICS LEDs', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              ledIndicator('E-Stop Signal', estop),
              ledIndicator('Simulation Mode', !connected),
            ],
          ),
        ],
      ),
    );
  }

  Widget ledIndicator(String label, bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: active ? Colors.redAccent : const Color(0xFF1A3320),
            border: Border.all(color: Colors.white38),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
      ],
    );
  }
}

class Mach3ToolpathPainter extends CustomPainter {
  final List<GPoint> points;
  Mach3ToolpathPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = Colors.white12..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), gridPaint);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), gridPaint);

    if (points.isEmpty) return;

    double minX = points.map((p) => p.x).reduce(math.min);
    double maxX = points.map((p) => p.x).reduce(math.max);
    double minY = points.map((p) => p.y).reduce(math.min);
    double maxY = points.map((p) => p.y).reduce(math.max);

    final dx = maxX - minX;
    final dy = maxY - minY;
    final scale = math.min((size.width - 20) / (dx == 0 ? 1.0 : dx), (size.height - 20) / (dy == 0 ? 1.0 : dy));

    Offset mapPoint(GPoint p) => Offset(10 + (p.x - minX) * scale, size.height - 10 - (p.y - minY) * scale);

    for (int i = 1; i < points.length; i++) {
      final a = mapPoint(points[i - 1]);
      final b = mapPoint(points[i]);
      final paint = Paint()
        ..color = points[i].rapid ? Colors.redAccent : const Color(0xFF00FF41)
        ..strokeWidth = 1.5;
      canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant Mach3ToolpathPainter oldDelegate) => oldDelegate.points != points;
}
