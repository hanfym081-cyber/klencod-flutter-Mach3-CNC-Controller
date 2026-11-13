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

  // إحداثيات المحاور
  double droX = 0.0000;
  double droY = 0.0000;
  double droZ = 0.0000;
  double droA = 0.0000;

  // خصائص شاشة MDI الإضافية
  double scaleX = 1.0000;
  double scaleY = 1.0000;
  double scaleZ = 1.0000;
  bool showToGo = false;
  bool jogEnabled = true;
  double localRotationDeg = 0.0;
  int workOffsetNum = 1; // 1 = G54, 2 = G55...
  bool isTeaching = false;
  final List<String> taughtLines = [];
  double varX = 0.0, varY = 0.0, varZ = 0.0, varA = 0.0;
  bool absoluteMode = true;
  String statusMessage = 'No alarms or limits active';

  bool machineCoords = false;
  bool estop = true;
  bool spindleOn = false;

  double currentFeedRate = 100.0;
  double spindleRpm = 12000.0;
  int feedOverride = 100;
  int rapidOverride = 100;
  int spindleOverride = 100;

  bool optionalStop = false;
  bool blockDelete = false;
  bool cvMode = true;

  int currentTool = 0;
  double jogStep = 1.0;

  Timer? simulatorTimer;
  int simulatorIndex = 0;
  int activeLineIndex = -1;
  int selectedLineIndex = 0;

  final ScrollController gcodeScrollController = ScrollController();
  final TextEditingController mdiController = TextEditingController();
  final List<String> mdiHistory = [];

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
    mdiController.dispose();
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

  // تنفيذ أوامر MDI اليدوية وتحديث المحاور فعلياً
  void executeMdiGCode(String rawCmd) {
    final cmd = rawCmd.trim().toUpperCase();
    if (cmd.isEmpty) return;

    setState(() {
      mdiHistory.insert(0, cmd);
      statusMessage = 'MDI Executed: $cmd';
    });

    if (connected && pcSocket != null) {
      pcSocket!.write('MDI:$cmd\n');
    }

    if (estop) {
      setState(() => statusMessage = 'Error: E-Stop Active! Press RESET first.');
      return;
    }

    final words = RegExp(r'([A-Z])([-+]?\d*\.?\d+)').allMatches(cmd);
    final values = <String, double>{};
    for (final m in words) {
      values[m.group(1)!] = double.tryParse(m.group(2)!) ?? 0;
    }

    setState(() {
      if (values.containsKey('G')) {
        final g = values['G']!;
        if (g == 90) absoluteMode = true;
        if (g == 91) absoluteMode = false;
        if (g == 28) {
          droX = 0;
          droY = 0;
          droZ = 0;
          droA = 0;
        }
        if (g >= 54 && g <= 59) {
          workOffsetNum = (g - 53).toInt();
        }
      }

      if (values.containsKey('M')) {
        final m = values['M']!;
        if (m == 3 || m == 4) spindleOn = true;
        if (m == 5) spindleOn = false;
      }

      if (values.containsKey('F')) currentFeedRate = values['F']!;
      if (values.containsKey('S')) spindleRpm = values['S']!;
      if (values.containsKey('T')) currentTool = values['T']!.toInt();

      if (values.containsKey('X')) {
        droX = absoluteMode ? values['X']! * scaleX : droX + (values['X']! * scaleX);
      }
      if (values.containsKey('Y')) {
        droY = absoluteMode ? values['Y']! * scaleY : droY + (values['Y']! * scaleY);
      }
      if (values.containsKey('Z')) {
        droZ = absoluteMode ? values['Z']! * scaleZ : droZ + (values['Z']! * scaleZ);
      }
      if (values.containsKey('A')) {
        droA = absoluteMode ? values['A']! : droA + values['A']!;
      }

      if (isTeaching) {
        taughtLines.add(cmd);
      }
    });
  }

  void sendCommand(String cmd) {
    if (connected && pcSocket != null) {
      pcSocket!.write('$cmd\n');
    }

    if (cmd == 'RESET') {
      setState(() {
        estop = !estop;
        statusMessage = estop ? 'Emergency Mode Active' : 'System Ready';
        if (estop) stopSimulation();
      });
      return;
    }

    if (estop) {
      setState(() => statusMessage = 'E-Stop is Active! Press RESET to enable motion.');
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
        statusMessage = 'All Axes Referenced to Home';
      });
    } else if (cmd == 'ZERO_ALL') {
      setState(() {
        droX = 0.0;
        droY = 0.0;
        droZ = 0.0;
        droA = 0.0;
        statusMessage = 'All Work Coordinates Zeroed';
      });
    } else if (cmd == 'ZERO:X') {
      setState(() => droX = 0.0);
    } else if (cmd == 'ZERO:Y') {
      setState(() => droY = 0.0);
    } else if (cmd == 'ZERO:Z') {
      setState(() => droZ = 0.0);
    } else if (cmd == 'ZERO:A') {
      setState(() => droA = 0.0);
    } else if (cmd.startsWith('JOG:')) {
      if (!jogEnabled) {
        setState(() => statusMessage = 'Jog is OFF! Enable Jog ON/OFF first.');
        return;
      }
      setState(() {
        if (cmd == 'JOG:X+') droX += jogStep;
        if (cmd == 'JOG:X-') droX -= jogStep;
        if (cmd == 'JOG:Y+') droY += jogStep;
        if (cmd == 'JOG:Y-') droY -= jogStep;
        if (cmd == 'JOG:Z+') droZ += jogStep;
        if (cmd == 'JOG:Z-') droZ -= jogStep;
        if (cmd == 'JOG:A+') droA += jogStep;
        if (cmd == 'JOG:A-') droA -= jogStep;
        if (isTeaching) {
          taughtLines.add('G1 X${droX.toStringAsFixed(3)} Y${droY.toStringAsFixed(3)} Z${droZ.toStringAsFixed(3)} A${droA.toStringAsFixed(3)}');
        }
      });
    } else if (cmd == 'SPINDLE_TOGGLE') {
      setState(() => spindleOn = !spindleOn);
    }
  }

  bool get isSimulating => simulatorTimer?.isActive ?? false;

  void startSimulation() {
    if (result == null || result!.points.isEmpty) {
      setState(() => statusMessage = 'No G-Code file loaded for simulation!');
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
        currentFeedRate = pt.feed * (feedOverride / 100.0);
        spindleRpm = pt.spindle * (spindleOverride / 100.0);
        activeLineIndex = pt.lineIndex;
        simulatorIndex++;
      });

      if (gcodeScrollController.hasClients && activeLineIndex >= 0) {
        double targetScroll = (activeLineIndex * 18.0) - 80.0;
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
          if (p.startsWith('A=')) droA = double.parse(p.substring(2));
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
        selectedLineIndex = 0;
        statusMessage = 'Loaded: ${file.name}';
      });
      if (connected) sendCommand('LOAD_FILE:${file.name}');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    String gModal = 'Mill-> G15 G17 G21 ${absoluteMode ? "G90" : "G91"} G${53 + workOffsetNum}';
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // شريط التبويبات العلوي
            Container(
              height: 30,
              color: const Color(0xFF2B303B),
              child: Row(
                children: [
                  machTab(0, 'Program Run Alt-1'),
                  machTab(1, 'MDI Alt-2'),
                  machTab(2, 'ToolPath Alt-4'),
                  machTab(3, 'Offsets Alt-5'),
                  machTab(4, 'Settings Alt-6'),
                  machTab(5, 'Diagnostics Alt-7'),
                  const VerticalDivider(color: Colors.white24, width: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(gModal, style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.amberAccent)),
                  ),
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
            // محتوى الشاشات
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
            // شريط الحالة السفلي
            Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xFF111318),
              child: Row(
                children: [
                  const Text('Status: ', style: TextStyle(color: Colors.amber, fontSize: 9.5, fontWeight: FontWeight.bold)),
                  Expanded(child: Text(statusMessage, style: const TextStyle(color: Colors.white70, fontSize: 9.5))),
                  Text('Profile: Mach3Mill | File: $fileName', style: const TextStyle(color: Colors.cyanAccent, fontSize: 9.5)),
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
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.amberAccent : Colors.white70,
          ),
        ),
      ),
    );
  }

  // ==================== الشاشة الأولى: Program Run Alt-1 ====================
  Widget buildProgramRunTab() {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        children: [
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
                        ? const Center(child: Text('No G-Code Loaded\nUse Load G-Code button below', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 11)))
                        : ListView.builder(
                            controller: gcodeScrollController,
                            itemCount: result!.rawLines.length,
                            itemBuilder: (context, index) {
                              bool isActive = index == activeLineIndex;
                              bool isSelected = index == selectedLineIndex;
                              return InkWell(
                                onTap: () => setState(() => selectedLineIndex = index),
                                child: Container(
                                  height: 18,
                                  color: isActive ? Colors.blue.shade900 : (isSelected ? Colors.grey.shade800 : Colors.transparent),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    result!.rawLines[index],
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10,
                                      color: isActive ? Colors.white : Colors.lightGreenAccent,
                                      fontWeight: isActive || isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232731),
                    border: Border.all(color: Colors.grey.shade700),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: classicMachBtn('Cycle Start\n<Alt-R>', Colors.green.shade800, () => sendCommand('CYCLE_START'), height: 34)),
                          const SizedBox(width: 2),
                          Expanded(child: classicMachBtn('Feed Hold\n<Spc>', Colors.amber.shade800, () => sendCommand('FEED_HOLD'), height: 34)),
                          const SizedBox(width: 2),
                          Expanded(child: classicMachBtn('Stop\n<Alt-S>', Colors.red.shade900, () => sendCommand('STOP'), height: 34)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(child: classicMachBtn('Load G-Code', const Color(0xFF333B48), openFile, height: 26)),
                          const SizedBox(width: 2),
                          Expanded(child: classicMachBtn('Rewind', const Color(0xFF333B48), () => sendCommand('REWIND'), height: 26)),
                          const SizedBox(width: 2),
                          Expanded(
                            child: classicMachBtn('Set Next Line', Colors.blueGrey.shade700, () {
                              setState(() {
                                simulatorIndex = selectedLineIndex;
                                activeLineIndex = selectedLineIndex;
                              });
                            }, height: 26),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: CheckboxListTile(
                              title: const Text('Block Delete', style: TextStyle(fontSize: 9)),
                              value: blockDelete,
                              onChanged: (v) => setState(() => blockDelete = v ?? false),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                          ),
                          Expanded(
                            child: CheckboxListTile(
                              title: const Text('M1 Optional Stop', style: TextStyle(fontSize: 9)),
                              value: optionalStop,
                              onChanged: (v) => setState(() => optionalStop = v ?? false),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
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
          const SizedBox(width: 4),
          Expanded(
            flex: 4,
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 38,
                        child: classicMachBtn('R\nE\nF', Colors.teal.shade800, () => sendCommand('REF_ALL_HOME'), height: double.infinity),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Column(
                          children: [
                            droBox('X', droX, () => sendCommand('ZERO:X')),
                            const SizedBox(height: 2),
                            droBox('Y', droY, () => sendCommand('ZERO:Y')),
                            const SizedBox(height: 2),
                            droBox('Z', droZ, () => sendCommand('ZERO:Z')),
                            const SizedBox(height: 2),
                            droBox('A', droA, () => sendCommand('ZERO:A')),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: GestureDetector(
                                    onTap: () => sendCommand('RESET'),
                                    child: Container(
                                      height: 32,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: estop ? Colors.red.shade700 : Colors.green.shade700,
                                        border: Border.all(color: estop ? Colors.amber : Colors.greenAccent),
                                      ),
                                      child: Text(estop ? 'Reset' : 'Active', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: classicMachBtn(machineCoords ? 'Mach Coords' : 'Work Coords', machineCoords ? Colors.red.shade900 : const Color(0xFF333B48), () => setState(() => machineCoords = !machineCoords), height: 32),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 124,
                  child: buildFeedAndSpindleRow(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  flex: 4,
                  child: buildToolpathBox(),
                ),
                const SizedBox(height: 3),
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
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
                            Text('Step: ${jogStep}mm', style: const TextStyle(fontSize: 8, color: Colors.cyanAccent)),
                            InkWell(
                              onTap: () => setState(() => jogStep = jogStep == 1.0 ? 0.1 : (jogStep == 0.1 ? 10.0 : 1.0)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                color: Colors.blueGrey.shade700,
                                child: const Text('Jog Step', style: TextStyle(fontSize: 7.5)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('Y+', () => sendCommand('JOG:Y+')),
                            const SizedBox(width: 4),
                            jogKey('Z+', () => sendCommand('JOG:Z+'), Colors.amber),
                            const SizedBox(width: 4),
                            jogKey('A+', () => sendCommand('JOG:A+'), Colors.purpleAccent),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('X-', () => sendCommand('JOG:X-')),
                            const SizedBox(width: 4),
                            jogKey('X+', () => sendCommand('JOG:X+')),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('Y-', () => sendCommand('JOG:Y-')),
                            const SizedBox(width: 4),
                            jogKey('Z-', () => sendCommand('JOG:Z-'), Colors.amber),
                            const SizedBox(width: 4),
                            jogKey('A-', () => sendCommand('JOG:A-'), Colors.purpleAccent),
                          ],
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
    );
  }

  // ==================== الشاشة الثانية: MDI Alt-2 (مطابقة للصورة وبخصائص كاملة) ====================
  Widget buildMdiTab() {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Column(
        children: [
          // الجزء العلوي (3 أعمدة مطابقة للصورة تماماً)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // العمود الأيسر: REF ALL HOME + DROs + Scale + أزرار المحاور + Rotation & Tool/Offset
                Expanded(
                  flex: 38,
                  child: Column(
                    children: [
                      // بلوك الـ DROs مع زر REF ALL HOME الطولي
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 108,
                            child: classicMachBtn('R\nE\nF\n\nA\nL\nL', Colors.teal.shade800, () => sendCommand('REF_ALL_HOME'), height: 108),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Column(
                              children: [
                                mdiDroRow('X', droX, scaleX, () => sendCommand('ZERO:X'), () {
                                  setState(() => scaleX = scaleX == 1.0 ? 0.5 : 1.0);
                                }),
                                const SizedBox(height: 2),
                                mdiDroRow('Y', droY, scaleY, () => sendCommand('ZERO:Y'), () {
                                  setState(() => scaleY = scaleY == 1.0 ? 0.5 : 1.0);
                                }),
                                const SizedBox(height: 2),
                                mdiDroRow('Z', droZ, scaleZ, () => sendCommand('ZERO:Z'), () {
                                  setState(() => scaleZ = scaleZ == 1.0 ? 0.5 : 1.0);
                                }),
                                const SizedBox(height: 2),
                                // محور A + زر Radius Correct
                                Row(
                                  children: [
                                    Expanded(flex: 7, child: droBox('A', droA, () => sendCommand('ZERO:A'), height: 25)),
                                    const SizedBox(width: 2),
                                    Expanded(
                                      flex: 3,
                                      child: classicMachBtn('Radius\nCorrect', const Color(0xFF333B48), () {
                                        setState(() => statusMessage = 'Tool Radius Compensation Toggled');
                                      }, height: 25, fontSize: 6.5),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // صف الأزرار أسفل المحاور: De-Ref | Zero All | To Go | Mach Coords | Verify
                      Row(
                        children: [
                          Expanded(child: classicMachBtn('De-Ref\nAll Axes', const Color(0xFF333B48), () => setState(() => statusMessage = 'All Axes De-Referenced'), height: 24, fontSize: 6.5)),
                          const SizedBox(width: 2),
                          Expanded(child: classicMachBtn('Zero\nAll', const Color(0xFF333B48), () => sendCommand('ZERO_ALL'), height: 24, fontSize: 7)),
                          const SizedBox(width: 2),
                          Expanded(
                            child: classicMachBtn(
                              'To Go',
                              showToGo ? Colors.amber.shade800 : const Color(0xFF333B48),
                              () => setState(() {
                                showToGo = !showToGo;
                                statusMessage = showToGo ? 'Showing Distance-To-Go' : 'Showing Work Coordinates';
                              }),
                              height: 24,
                              fontSize: 7.5,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: classicMachBtn(
                              'Machine\nCoord\'s',
                              machineCoords ? Colors.red.shade900 : const Color(0xFF333B48),
                              () => setState(() => machineCoords = !machineCoords),
                              height: 24,
                              fontSize: 6.5,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: classicMachBtn('Verify', const Color(0xFF333B48), () {
                              setState(() => statusMessage = 'Position Verified: No Lost Steps');
                            }, height: 24, fontSize: 7.5),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // الجزء السفلي من العمود الأيسر: Local System Rotated + TOOL + Work Offset + Jog ON/OFF
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Row(
                            children: [
                              // Local System Rotated
                              Expanded(
                                flex: 4,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('Local System\nRotated', textAlign: TextAlign.center, style: TextStyle(fontSize: 7.5, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                                    Container(
                                      height: 20,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      alignment: Alignment.centerRight,
                                      decoration: BoxDecoration(color: Colors.black, border: Border.all(color: Colors.grey.shade600)),
                                      child: Text('${localRotationDeg >= 0 ? "+" : ""}${localRotationDeg.toStringAsFixed(1)}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF00FF41))),
                                    ),
                                    Row(
                                      children: [
                                        Expanded(child: smallBtn('-15°', () => setState(() => localRotationDeg -= 15))),
                                        const SizedBox(width: 2),
                                        Expanded(child: smallBtn('0°', () => setState(() => localRotationDeg = 0))),
                                        const SizedBox(width: 2),
                                        Expanded(child: smallBtn('+15°', () => setState(() => localRotationDeg += 15))),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              // TOOL & Work Offset & Jog ON/OFF
                              Expanded(
                                flex: 6,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    // TOOL
                                    Row(
                                      children: [
                                        const Expanded(child: Text('TOOL', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.amber))),
                                        mediumBtn('-', () => setState(() => currentTool = math.max(0, currentTool - 1))),
                                        Container(
                                          width: 32,
                                          height: 18,
                                          margin: const EdgeInsets.symmetric(horizontal: 3),
                                          alignment: Alignment.center,
                                          color: Colors.black,
                                          child: Text('$currentTool', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                                        ),
                                        mediumBtn('+', () => setState(() => currentTool = math.min(99, currentTool + 1))),
                                      ],
                                    ),
                                    // Work Offset #
                                    Row(
                                      children: [
                                        Expanded(child: Text('Offset # (G${53 + workOffsetNum})', style: const TextStyle(fontSize: 7.5, color: Colors.white70))),
                                        mediumBtn('-', () => setState(() => workOffsetNum = math.max(1, workOffsetNum - 1))),
                                        Container(
                                          width: 32,
                                          height: 18,
                                          margin: const EdgeInsets.symmetric(horizontal: 3),
                                          alignment: Alignment.center,
                                          color: Colors.black,
                                          child: Text('$workOffsetNum', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                                        ),
                                        mediumBtn('+', () => setState(() => workOffsetNum = math.min(6, workOffsetNum + 1))),
                                      ],
                                    ),
                                    // Jog ON/OFF
                                    InkWell(
                                      onTap: () => setState(() => jogEnabled = !jogEnabled),
                                      child: Container(
                                        height: 20,
                                        width: double.infinity,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: jogEnabled ? Colors.green.shade800 : Colors.grey.shade800,
                                          border: Border.all(color: jogEnabled ? Colors.greenAccent : Colors.white24),
                                        ),
                                        child: Text(
                                          jogEnabled ? 'Jog ON/OFF Ctrl-Alt-J [ON]' : 'Jog ON/OFF Ctrl-Alt-J [OFF]',
                                          style: const TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),

                // العمود الأوسط: شريط SCALING + أزرار Teach/Variable + مربعي Feed Rate و Spindle Speed
                Expanded(
                  flex: 34,
                  child: Column(
                    children: [
                      // الجزء العلوي: شريط عمودي + 6 أزرار (2x3)
                      Expanded(
                        child: Row(
                          children: [
                            // شريط SCALING OFF G50 العمودي
                            Container(
                              width: 18,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: (scaleX != 1.0 || scaleY != 1.0 || scaleZ != 1.0) ? Colors.amber.shade900 : const Color(0xFF2B303B),
                                border: Border.all(color: Colors.grey.shade700),
                              ),
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Text(
                                  (scaleX != 1.0 || scaleY != 1.0 || scaleZ != 1.0) ? 'SCALING ON' : 'SCALING OFF G50',
                                  style: const TextStyle(fontSize: 7, fontWeight: FontWeight.bold, color: Colors.white70),
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            // شبكة الأزرار (2 أعمدة × 3 صفوف)
                            Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(child: classicMachBtn('Stop\n(Esc)', Colors.red.shade900, () => sendCommand('STOP'), height: double.infinity, fontSize: 8.5)),
                                        const SizedBox(width: 3),
                                        Expanded(child: classicMachBtn('Load / Edit', const Color(0xFF333B48), openFile, height: double.infinity, fontSize: 8.5)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: classicMachBtn(
                                            isTeaching ? 'Teaching...' : 'Start\nTeach',
                                            isTeaching ? Colors.green.shade600 : Colors.green.shade900,
                                            () => setState(() {
                                              isTeaching = true;
                                              taughtLines.clear();
                                              statusMessage = 'Teach Mode Started: Recording MDI & Jog moves';
                                            }),
                                            height: double.infinity,
                                            fontSize: 8.5,
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        Expanded(
                                          child: classicMachBtn(
                                            'Stop\nTeach',
                                            Colors.amber.shade900,
                                            () => setState(() {
                                              isTeaching = false;
                                              if (taughtLines.isNotEmpty) {
                                                final content = taughtLines.join('\n');
                                                gcode = content;
                                                result = GCodeParser.parse(content);
                                                fileName = 'MDI_Taught.nc';
                                                statusMessage = 'Teach Stopped: ${taughtLines.length} lines loaded to Program Run';
                                              } else {
                                                statusMessage = 'Teach Stopped (No moves recorded)';
                                              }
                                            }),
                                            height: double.infinity,
                                            fontSize: 8.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: classicMachBtn(
                                            'Set Variable\nPosition',
                                            Colors.blueGrey.shade700,
                                            () => setState(() {
                                              varX = droX;
                                              varY = droY;
                                              varZ = droZ;
                                              varA = droA;
                                              statusMessage = 'Variable Pos Saved: X${varX.toStringAsFixed(2)} Y${varY.toStringAsFixed(2)} Z${varZ.toStringAsFixed(2)}';
                                            }),
                                            height: double.infinity,
                                            fontSize: 8,
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        Expanded(
                                          child: classicMachBtn(
                                            'Goto Variable\nPosition',
                                            Colors.blueGrey.shade700,
                                            () {
                                              if (estop) {
                                                setState(() => statusMessage = 'Error: E-Stop Active!');
                                                return;
                                              }
                                              setState(() {
                                                droX = varX;
                                                droY = varY;
                                                droZ = varZ;
                                                droA = varA;
                                                statusMessage = 'Moved to Saved Variable Position';
                                              });
                                            },
                                            height: double.infinity,
                                            fontSize: 8,
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
                      ),
                      const SizedBox(height: 3),
                      // مربعا Feed Rate و Spindle Speed
                      SizedBox(
                        height: 112,
                        child: buildFeedAndSpindleRow(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),

                // العمود الأيمن: شاشة Toolpath السوداء
                Expanded(
                  flex: 28,
                  child: buildToolpathBox(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),

          // شريط Input العريض لكتابة أوامر MDI
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF232731),
              border: Border.all(color: Colors.grey.shade600),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  color: const Color(0xFF3B4252),
                  child: const Text('Input', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: mdiController,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFF00FF41), fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: 'Type G-Code (e.g. G0 X25 Y10, M3 S15000, G28) and press Enter...',
                      hintStyle: TextStyle(color: Colors.white30, fontSize: 10),
                      filled: true,
                      fillColor: Colors.black,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    ),
                    onSubmitted: (val) {
                      executeMdiGCode(val);
                      mdiController.clear();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                classicMachBtn('Send', Colors.teal.shade800, () {
                  executeMdiGCode(mdiController.text);
                  mdiController.clear();
                }, height: 24, width: 55, fontSize: 9.5),
              ],
            ),
          ),
          const SizedBox(height: 3),

          // الشريط السفلي في شاشة MDI: زر Reset الأحمر + G-Codes / M-Codes + History / Clear
          SizedBox(
            height: 34,
            child: Row(
              children: [
                // زر Reset الأحمر الكبير
                GestureDetector(
                  onTap: () => sendCommand('RESET'),
                  child: Container(
                    width: 110,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: estop ? Colors.red.shade700 : Colors.green.shade700,
                      border: Border.all(color: estop ? Colors.amber : Colors.greenAccent, width: 1.5),
                    ),
                    child: Text(estop ? 'Reset' : 'Active', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 6),
                // أزرار G-Codes و M-Codes
                classicMachBtn('G-Codes', const Color(0xFF333B48), () => showCodesDialog(true), height: 30, width: 65, fontSize: 8.5),
                const SizedBox(width: 3),
                classicMachBtn('M-Codes', const Color(0xFF333B48), () => showCodesDialog(false), height: 30, width: 65, fontSize: 8.5),
                const SizedBox(width: 8),
                // عرض آخر أمر منفذ
                Expanded(
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(color: Colors.black, border: Border.all(color: Colors.white24)),
                    child: Text(
                      mdiHistory.isEmpty ? 'Last MDI: None' : 'Last MDI: ${mdiHistory.first}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.lightGreenAccent),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // أزرار History و Clear
                classicMachBtn('History', Colors.blueGrey.shade700, showHistoryDialog, height: 30, width: 60, fontSize: 8.5),
                const SizedBox(width: 3),
                classicMachBtn('Clear', const Color(0xFF333B48), () => setState(() => mdiHistory.clear()), height: 30, width: 50, fontSize: 8.5),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // صف DRO مع خانة Scale الخاصة بشاشة MDI
  Widget mdiDroRow(String axis, double value, double scaleVal, VoidCallback onZero, VoidCallback onScaleToggle) {
    double displayVal = showToGo ? 0.0 : value;
    return SizedBox(
      height: 25,
      child: Row(
        children: [
          Expanded(
            flex: 7,
            child: droBox(axis, displayVal, onZero, height: 25),
          ),
          const SizedBox(width: 2),
          Expanded(
            flex: 3,
            child: InkWell(
              onTap: onScaleToggle,
              child: Container(
                height: 25,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.centerRight,
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: scaleVal != 1.0 ? Colors.amber : Colors.grey.shade700),
                ),
                child: Text(
                  scaleVal.toStringAsFixed(3),
                  style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: scaleVal != 1.0 ? Colors.amber : Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // مربعا Feed Rate و Spindle Speed المشتركان بين الشاشتين
  Widget buildFeedAndSpindleRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF232731),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Feed Rate', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                    InkWell(
                      onTap: () => setState(() => cvMode = !cvMode),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        color: cvMode ? Colors.green.shade800 : Colors.blueGrey.shade800,
                        child: Text(cvMode ? 'CV Mode' : 'Exact', style: const TextStyle(fontSize: 6.5)),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('FRO %', style: TextStyle(fontSize: 7.5, color: Colors.white60)),
                    Text('$feedOverride%', style: const TextStyle(fontSize: 8.5, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Override', style: TextStyle(fontSize: 7.5, color: Colors.white60)),
                    Row(
                      children: [
                        mediumBtn('-', () => setState(() => feedOverride = math.max(10, feedOverride - 10))),
                        const SizedBox(width: 2),
                        mediumBtn('+', () => setState(() => feedOverride = math.min(200, feedOverride + 10))),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: smallBtn('100%', () => setState(() => feedOverride = 100))),
                    const SizedBox(width: 2),
                    Expanded(child: smallBtn('Reset', () => setState(() => feedOverride = 100))),
                  ],
                ),
                Text('Feed: ${currentFeedRate.toStringAsFixed(1)}', style: const TextStyle(fontSize: 8, fontFamily: 'monospace', color: Colors.cyanAccent)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 3),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF232731),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Spindle Speed', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.amber)),
                    Text('SRO $spindleOverride%', style: const TextStyle(fontSize: 7.5, color: Colors.greenAccent)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Spindle F5', style: TextStyle(fontSize: 7.5, color: Colors.white70)),
                    classicMachBtn(
                      spindleOn ? 'ON' : 'OFF',
                      spindleOn ? Colors.amber.shade800 : const Color(0xFF333B48),
                      () => sendCommand('SPINDLE_TOGGLE'),
                      height: 15,
                      width: 34,
                      fontSize: 7,
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('RPM Ctrl', style: TextStyle(fontSize: 7.5, color: Colors.white60)),
                    Row(
                      children: [
                        mediumBtn('-', () => setState(() => spindleOverride = math.max(10, spindleOverride - 10))),
                        const SizedBox(width: 2),
                        mediumBtn('+', () => setState(() => spindleOverride = math.min(200, spindleOverride + 10))),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: smallBtn('Reset RPM', () => setState(() => spindleOverride = 100))),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('RPM', style: TextStyle(fontSize: 7.5)),
                    Text('${spindleRpm.toInt()}', style: const TextStyle(fontSize: 8, fontFamily: 'monospace', color: Colors.cyanAccent)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildToolpathBox() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.grey.shade700, width: 1.5),
      ),
      child: Stack(
        children: [
          result == null
              ? const Center(child: Text('Toolpath Window', style: TextStyle(color: Colors.white24, fontSize: 10)))
              : CustomPaint(
                  painter: Mach3ToolpathPainter(result!.points, simulatorIndex),
                  child: const SizedBox.expand(),
                ),
          Positioned(
            top: 2,
            right: 4,
            child: Text('Tool:#$currentTool', style: const TextStyle(fontSize: 8, color: Colors.amber, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  void showHistoryDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF232731),
        title: const Text('MDI Command History', style: TextStyle(fontSize: 13, color: Colors.cyanAccent)),
        content: SizedBox(
          width: 320,
          height: 180,
          child: mdiHistory.isEmpty
              ? const Center(child: Text('No commands executed yet.'))
              : ListView.builder(
                  itemCount: mdiHistory.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    title: Text(mdiHistory[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.lightGreenAccent)),
                    onTap: () {
                      mdiController.text = mdiHistory[i];
                      Navigator.pop(context);
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  void showCodesDialog(bool isGCode) {
    final items = isGCode
        ? [
            'G00 - Rapid Positioning',
            'G01 - Linear Interpolation',
            'G02 / G03 - Circular Interpolation (CW/CCW)',
            'G20 / G21 - Inch / Millimeter Units',
            'G28 - Return to Home Position',
            'G54..G59 - Work Coordinate Offsets',
            'G90 / G91 - Absolute / Incremental Mode',
          ]
        : [
            'M00 - Program Stop',
            'M01 - Optional Program Stop',
            'M03 / M04 - Spindle ON (CW / CCW)',
            'M05 - Spindle Stop',
            'M06 - Tool Change',
            'M08 / M09 - Coolant ON / OFF',
            'M30 - Program End & Rewind',
          ];

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF232731),
        title: Text(isGCode ? 'Standard G-Codes' : 'Standard M-Codes', style: const TextStyle(fontSize: 13, color: Colors.amber)),
        content: SizedBox(
          width: 340,
          height: 200,
          child: ListView(
            children: items.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(e, style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: Colors.white)),
            )).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget droBox(String axis, double value, VoidCallback onZero, {double height = 26}) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: machineCoords ? Colors.redAccent : Colors.grey.shade600, width: 1.2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: onZero,
            child: Text('Zero $axis', style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
          ),
          Text(
            '${value >= 0 ? "+" : ""}${value.toStringAsFixed(4)}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: showToGo ? Colors.amber : (machineCoords ? Colors.redAccent : const Color(0xFF00FF41)),
            ),
          ),
        ],
      ),
    );
  }

  Widget classicMachBtn(String text, Color bg, VoidCallback onTap, {double height = 28, double? width, double fontSize = 8}) {
    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
        ),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget mediumBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0xFF434C5E),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(label, style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget smallBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFF333B48), border: Border.all(color: Colors.white24)),
        child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget jogKey(String label, VoidCallback onTap, [Color color = Colors.cyanAccent]) {
    return SizedBox(
      width: 32,
      height: 20,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF161920),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: BorderSide(color: color.withOpacity(0.5))),
        ),
        child: Text(label, style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: color)),
      ),
    );
  }

  Widget buildFullToolpathTab() => const Center(child: Text('Full Toolpath View'));
  Widget buildOffsetsTab() => const Center(child: Text('Offsets View'));
  Widget buildSettingsTab() => const Center(child: Text('Settings View'));
  Widget buildDiagnosticsTab() => const Center(child: Text('Diagnostics View'));
}

class Mach3ToolpathPainter extends CustomPainter {
  final List<GPoint> points;
  final int currentIndex;
  Mach3ToolpathPainter(this.points, this.currentIndex);

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = Colors.white10..strokeWidth = 1;
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

    final fullPaint = Paint()..color = Colors.white24..strokeWidth = 1;
    for (int i = 1; i < points.length; i++) {
      canvas.drawLine(mapPoint(points[i - 1]), mapPoint(points[i]), fullPaint);
    }

    int limit = math.min(currentIndex, points.length);
    final activePaint = Paint()..color = const Color(0xFF00FF41)..strokeWidth = 1.5;
    for (int i = 1; i < limit; i++) {
      canvas.drawLine(mapPoint(points[i - 1]), mapPoint(points[i]), activePaint);
    }

    if (limit > 0) {
      final currentPt = mapPoint(points[limit - 1]);
      final toolPaint = Paint()..color = Colors.amber..style = PaintingStyle.fill;
      canvas.drawCircle(currentPt, 3.5, toolPaint);
    }
  }

  @override
  bool shouldRepaint(covariant Mach3ToolpathPainter oldDelegate) => oldDelegate.currentIndex != currentIndex || oldDelegate.points != points;
}
