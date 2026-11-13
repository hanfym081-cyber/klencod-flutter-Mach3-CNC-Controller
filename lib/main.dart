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
  final double feed;
  final double spindle;
  const GPoint(this.x, this.y, this.z, this.rapid, this.lineIndex, this.feed, this.spindle);
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

      if (values.containsKey('X') || values.containsKey('Y') || values.containsKey('Z')) {
        final oldX = x, oldY = y, oldZ = z;
        if (values.containsKey('X')) x = absolute ? (values['X']! * scale) : x + (values['X']! * scale);
        if (values.containsKey('Y')) y = absolute ? (values['Y']! * scale) : y + (values['Y']! * scale);
        if (values.containsKey('Z')) z = absolute ? (values['Z']! * scale) : z + (values['Z']! * scale);

        distance += math.sqrt(math.pow(x - oldX, 2) + math.pow(y - oldY, 2) + math.pow(z - oldZ, 2));
        movements++;
        points.add(GPoint(x, y, z, rapid, i, currentFeed, currentSpindle));
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
  bool machineCoords = false;
  bool estop = true; 
  bool spindleOn = false;
  
  double currentFeedRate = 100.0;
  double spindleRpm = 12000.0;
  int feedOverride = 100;
  int rapidOverride = 100;
  bool optionalStop = false;
  bool blockDelete = false;
  bool cvMode = true; // وضع الحركة المستمرة (Constant Velocity)
  int currentTool = 1;
  double jogStep = 1.0;

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
        currentFeedRate = 100.0;
        spindleRpm = 12000.0;
      });
    } else if (cmd == 'REF_ALL_HOME') {
      setState(() {
        droX = 0.0;
        droY = 0.0;
        droZ = 0.0;
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
        currentFeedRate = pt.feed;
        spindleRpm = pt.spindle;
        activeLineIndex = pt.lineIndex;
        simulatorIndex++;
      });

      if (gcodeScrollController.hasClients && activeLineIndex >= 0) {
        double estimatedOffset = activeLineIndex * 16.0;
        double maxScroll = gcodeScrollController.position.maxScrollExtent;
        gcodeScrollController.jumpTo(estimatedOffset.clamp(0.0, maxScroll));
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
            // شريط القوائم العلوي المطابق لـ Mach3 مع مؤشرات الـ Modals
            Container(
              height: 32,
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
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('Mill-> G15 G17 G21 G90 G54', style: TextStyle(fontSize: 9, fontFamily: 'monospace', color: Colors.amberAccent)),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    margin: const EdgeInsets.only(right: 6),
                    color: isSimulating ? Colors.amber.shade800 : (connected ? Colors.green.shade800 : Colors.blueGrey.shade800),
                    child: Text(
                      isSimulating ? 'SIMULATING...' : (connected ? 'ONLINE' : 'OFFLINE'),
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
            // شريط الحالة السفلي الأصلي
            Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xFF111318),
              child: Row(
                children: [
                  const Text('Error: ', style: TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
                  const Expanded(child: Text('No alarms or limits active', style: TextStyle(color: Colors.white60, fontSize: 10))),
                  Text('Profile: Mach3Mill | File: $fileName', style: const TextStyle(color: Colors.cyanAccent, fontSize: 10)),
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

  Widget buildProgramRunTab() {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        children: [
          // العمود الأول: نافذة الأكواد وأزرار التحكم مع إضافة Set Next Line ومؤشر السطر
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
                              return Container(
                                color: isActive ? Colors.blue.shade900 : Colors.transparent,
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                child: Text(
                                  result!.rawLines[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    color: isActive ? Colors.white : Colors.lightGreenAccent,
                                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
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
                          Expanded(child: classicMachBtn('Set Next Line', const Color(0xFF333B48), () {}, height: 26)),
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
          // العمود الثاني: الـ DROs وصناديق التغذية والمغزل المطابقة للأصل تماماً
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
                  height: 125,
                  child: Row(
                    children: [
                      // صندوق Feed Rate المطابق تماماً لشاشة 1024.set
                      Expanded(
                        flex: 5,
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
                                      child: Text(cvMode ? 'CV Mode' : 'Exact Stop', style: const TextStyle(fontSize: 8)),
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 2, color: Colors.white24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('FRO: $feedOverride%', style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                                  Row(
                                    children: [
                                      smallBtn('50%', () => setState(() => feedOverride = 50)),
                                      smallBtn('100%', () => setState(() => feedOverride = 100)),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text('F: ${currentFeedRate.toStringAsFixed(1)}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white, fontWeight: FontWeight.bold)),
                              const Text('Units/Min', style: TextStyle(fontSize: 9, color: Colors.white60)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      // صندوق Spindle Speed المطابق تماماً لشاشة 1024.set
                      Expanded(
                        flex: 5,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232731),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Spindle Speed', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber)),
                              const Divider(height: 2, color: Colors.white24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('RPM: ${spindleRpm.toInt()}', style: const TextStyle(fontSize: 10, color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                                  classicMachBtn(
                                    spindleOn ? 'ON' : 'OFF',
                                    spindleOn ? Colors.amber.shade800 : const Color(0xFF333B48),
                                    () => sendCommand('SPINDLE_TOGGLE'),
                                    height: 20,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text('S: ${spindleRpm.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white, fontWeight: FontWeight.bold)),
                              const Text('Spindle CW F5', style: TextStyle(fontSize: 9, color: Colors.white60)),
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
          const SizedBox(width: 4),
          // العمود الثالث: نافذة التول باث والـ Jog
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
                            ? const Center(child: Text('Toolpath Window', style: TextStyle(color: Colors.white24, fontSize: 11)))
                            : CustomPaint(
                                painter: Mach3ToolpathPainter(result!.points, simulatorIndex),
                                child: const SizedBox.expand(),
                              ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Text('Tool:#$currentTool', style: const TextStyle(fontSize: 9, color: Colors.amber, fontFamily: 'monospace')),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 3),
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
                            Text('Step: ${jogStep}mm', style: const TextStyle(fontSize: 9, color: Colors.cyanAccent)),
                            InkWell(
                              onTap: () => setState(() => jogStep = jogStep == 1.0 ? 0.1 : 10.0),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                color: Colors.blueGrey.shade700,
                                child: const Text('Jog Step', style: TextStyle(fontSize: 8)),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            jogKey('Y+', () => sendCommand('JOG:Y+')),
                            const SizedBox(width: 12),
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
                            const SizedBox(width: 12),
                            jogKey('Z-', () => sendCommand('Z-'), Colors.amber),
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

  Widget droBox(String axis, double value, VoidCallback onZero) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: machineCoords ? Colors.redAccent : Colors.grey.shade600, width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: onZero,
            child: Text('Zero $axis', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
          ),
          Text(
            value.toStringAsFixed(4),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: machineCoords ? Colors.redAccent : const Color(0xFF00FF41),
            ),
          ),
        ],
      ),
    );
  }

  Widget classicMachBtn(String text, Color bg, VoidCallback onTap, {double height = 34}) {
    return SizedBox(
      height: height,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: const BorderSide(color: Colors.white24)),
        ),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget smallBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFF333B48), border: Border.all(color: Colors.white24)),
        child: Text(label, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget jogKey(String label, VoidCallback onTap, [Color color = Colors.cyanAccent]) {
    return SizedBox(
      width: 38,
      height: 24,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF161920),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: BorderSide(color: color.withOpacity(0.5))),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      ),
    );
  }

  Widget buildMdiTab() => Padding(padding: const EdgeInsets.all(10), child: TextField(controller: mdiController, decoration: const InputDecoration(labelText: 'MDI Command')));
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
