import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Mach3CloneApp());
}

class Mach3CloneApp extends StatelessWidget {
  const Mach3CloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 CNC Controller',
      theme: ThemeData(
        brightness: Brightness.dark,
        // Mach3 classic industrial dark gray/blue palette
        scaffoldBackgroundColor: const Color(0xFF0F141C),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1E293B),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF131A24),
        ),
        useMaterial3: false, // Disabling Material3 to give raw classic HMI look
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
  const GPoint(this.x, this.y, this.z, this.rapid);
}

class GCodeResult {
  final List<GPoint> points;
  final int lines;
  final int movements;
  final double distance;
  const GCodeResult({required this.points, required this.lines, required this.movements, required this.distance});
}

class GCodeParser {
  static GCodeResult parse(String source) {
    final points = <GPoint>[];
    double x = 0, y = 0, z = 0;
    double scale = 1;
    bool absolute = true;
    bool rapid = false;
    double distance = 0;
    int movements = 0;

    final lines = source.split(RegExp(r'\r?\n'));
    for (final original in lines) {
      String line = original.toUpperCase();
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
        points.add(GPoint(x, y, z, rapid));
      }
    }
    return GCodeResult(points: points, lines: lines.length, movements: movements, distance: distance);
  }
}

class Mach3MainScreen extends StatefulWidget {
  const Mach3MainScreen({super.key});

  @override
  State<Mach3MainScreen> createState() => _Mach3MainScreenState();
}

class _Mach3MainScreenState extends State<Mach3MainScreen> {
  int currentTab = 0; // 0: Program Run / Main, 1: Offsets, 2: Tool Table, 3: Diagnostics, 4: Settings
  String fileName = 'No loaded file';
  String gcode = '';
  GCodeResult? result;

  // Connection & Live DRO
  bool connected = false;
  Socket? pcSocket;
  String pcIp = '192.168.1.100';
  int pcPort = 50002;

  double droX = 0.0000;
  double droY = 0.0000;
  double droZ = 0.0000;
  bool estop = false;

  @override
  void initState() {
    super.initState();
    loadPreferences();
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
    if (!connected || pcSocket == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Offline: Not connected to PC')));
      return;
    }
    pcSocket!.write('$cmd\n');
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
      });
      if (connected) sendCommand('LOAD_FILE:${file.name}');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(42),
        child: AppBar(
          backgroundColor: const Color(0xFF1B222D),
          elevation: 2,
          title: Text(
            'MACH3 CNC MILLING - [ $fileName ]',
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: Colors.amberAccent),
          ),
          actions: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  connected ? 'LINKED' : 'OFFLINE',
                  style: TextStyle(color: connected ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Top Mach3 Tab Navigation Bar (Exact classic buttons layout)
          Container(
            color: const Color(0xFF131922),
            height: 44,
            child: Row(
              children: [
                tabButton(0, 'Program Run'),
                tabButton(1, 'Offsets (G54)'),
                tabButton(2, 'Tool Table'),
                tabButton(3, 'Diagnostics'),
                tabButton(4, 'Config/Set'),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black),
          // Main Body View based on active Tab
          Expanded(
            child: IndexedStack(
              index: currentTab,
              children: [
                buildProgramRunScreen(),
                const Mach3OffsetsView(),
                const Mach3ToolTableView(),
                buildDiagnosticsScreen(),
                buildSettingsScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget tabButton(int index, String title) {
    bool active = currentTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => currentTab = index),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF222D3D) : const Color(0xFF131922),
            border: Border(
              bottom: BorderSide(color: active ? Colors.cyanAccent : Colors.transparent, width: 3),
              right: const BorderSide(color: Color(0xFF0A0E14), width: 1),
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // TAB 0: Program Run & Main Mach3 Screen (DRO + Toolpath + Jog)
  // ==========================================
  Widget buildProgramRunScreen() {
    return Row(
      children: [
        // Left Column: DROs & Emergency & Cycle Control
        Expanded(
          flex: 4,
          child: Container(
            color: const Color(0xFF0A0E13),
            padding: const EdgeInsets.all(6),
            child: Column(
              children: [
                // DRO Readouts (Mach3 Style Black Box with Green/Red/Cyan texts)
                droCard('X AXIS', droX, Colors.cyanAccent),
                const SizedBox(height: 4),
                droCard('Y AXIS', droY, Colors.greenAccent),
                const SizedBox(height: 4),
                droCard('Z AXIS', droZ, Colors.orangeAccent),
                const SizedBox(height: 8),

                // Mach3 Control Buttons Panel (Reset, Cycle Start, Feed Hold)
                Row(
                  children: [
                    Expanded(
                      child: machButton(
                        'RESET',
                        estop ? Colors.red : Colors.red.shade900,
                        () => sendCommand('RESET'),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: machButton(
                        'CYCLE START',
                        Colors.green.shade800,
                        () => sendCommand('CYCLE_START'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: machButton(
                        'FEED HOLD',
                        Colors.amber.shade900,
                        () => sendCommand('FEED_HOLD'),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: machButton(
                        'LOAD G-CODE',
                        const Color(0xFF253347),
                        openFile,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Mini Jog Panel
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131922),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('JOG PENDANT', style: TextStyle(fontSize: 10, color: Colors.white54)),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [miniJogBtn('Y+', 'JOG:Y+')],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            miniJogBtn('X-', 'JOG:X-'),
                            const SizedBox(width: 24),
                            miniJogBtn('X+', 'JOG:X+'),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [miniJogBtn('Y-', 'JOG:Y-')],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            miniJogBtn('Z+', 'JOG:Z+', Colors.orange),
                            const SizedBox(width: 10),
                            miniJogBtn('Z-', 'JOG:Z-', Colors.orange),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Right Column: Toolpath Visualizer & G-code Preview box
        Expanded(
          flex: 6,
          child: Column(
            children: [
              // Toolpath Screen Box
              Expanded(
                flex: 6,
                child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Colors.cyan.withOpacity(0.4), width: 1.5),
                  ),
                  child: result == null
                      ? const Center(child: Text('NO TOOLPATH LOADED', style: TextStyle(color: Colors.white30, fontSize: 12)))
                      : CustomPaint(
                          painter: Mach3ToolpathPainter(result!.points),
                          child: const SizedBox.expand(),
                        ),
                ),
              ),
              // G-Code View Box
              Expanded(
                flex: 4,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF080B10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      gcode.isEmpty ? 'G-code window empty...' : gcode,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.lightGreenAccent),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget droCard(String axis, double val, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF020406),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(axis, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
          Text(
            val.toStringAsFixed(4),
            style: TextStyle(color: color, fontSize: 22, fontFamily: 'monospace', fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget machButton(String label, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 38,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          padding: EdgeInsets.zero,
        ),
        child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget miniJogBtn(String label, String cmd, [Color color = Colors.cyan]) {
    return SizedBox(
      width: 44,
      height: 32,
      child: ElevatedButton(
        onPressed: () => sendCommand(cmd),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1B2430),
          side: BorderSide(color: color.withOpacity(0.5)),
          padding: EdgeInsets.zero,
        ),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      ),
    );
  }

  // ==========================================
  // TAB 3: Diagnostics Screen
  // ==========================================
  Widget buildDiagnosticsScreen() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: ListView(
        children: [
          const Text('DIAGNOSTICS & SAFETY INPUTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.cyan)),
          const Divider(color: Colors.white24),
          diagRow('Emergency Stop Status', estop ? 'ACTIVE / TRIGGERED' : 'NORMAL', estop ? Colors.red : Colors.green),
          diagRow('X Home Limit Switch', 'Normal (Open)', Colors.green),
          diagRow('Y Home Limit Switch', 'Normal (Open)', Colors.green),
          diagRow('Z Home Limit Switch', 'Normal (Open)', Colors.green),
          diagRow('Spindle Interlock', 'Ready', Colors.green),
          diagRow('TCP Socket Link', connected ? 'Connected ($pcIp)' : 'Disconnected', connected ? Colors.green : Colors.orange),
        ],
      ),
    );
  }

  Widget diagRow(String name, String status, Color color) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF131922), border: Border.all(color: Colors.white12)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(name, style: const TextStyle(fontSize: 12)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: color.withOpacity(0.2), border: Border.all(color: color)),
            child: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 4: Settings / Config Screen
  // ==========================================
  Widget buildSettingsScreen() {
    final ipCtrl = TextEditingController(text: pcIp);
    final portCtrl = TextEditingController(text: pcPort.toString());

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MACH3 PC NETWORK CONFIG', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.cyan)),
          const SizedBox(height: 10),
          TextField(
            controller: ipCtrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(labelText: 'PC IP Address', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: portCtrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(labelText: 'TCP Port', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 15),
          ElevatedButton(
            onPressed: () {
              setState(() {
                pcIp = ipCtrl.text.trim();
                pcPort = int.tryParse(portCtrl.text.trim()) ?? 50002;
              });
              savePreferences();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configuration saved!')));
            },
            child: const Text('Save Configuration'),
          ),
          const SizedBox(height: 15),
          ElevatedButton(
            onPressed: connected ? disconnect : connectToPC,
            style: ElevatedButton.styleFrom(backgroundColor: connected ? Colors.red.shade800 : Colors.cyan.shade800),
            child: Text(connected ? 'Disconnect PC Link' : 'Connect Link Now'),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// TOOLPATH PAINTER (Mach3 Classic Style)
// ==========================================
class Mach3ToolpathPainter extends CustomPainter {
  final List<GPoint> points;
  Mach3ToolpathPainter(this.points);

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
    final scale = math.min((size.width - 30) / (dx == 0 ? 1.0 : dx), (size.height - 30) / (dy == 0 ? 1.0 : dy));

    Offset mapPoint(GPoint p) => Offset(15 + (p.x - minX) * scale, size.height - 15 - (p.y - minY) * scale);

    for (int i = 1; i < points.length; i++) {
      final a = mapPoint(points[i - 1]);
      final b = mapPoint(points[i]);
      final paint = Paint()
        ..color = points[i].rapid ? Colors.greenAccent : Colors.cyanAccent
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant Mach3ToolpathPainter oldDelegate) => oldDelegate.points != points;
}

// ==========================================
// TAB 1: Offsets View (Mach3 Work Offsets G54-G59)
// ==========================================
class Mach3OffsetsView extends StatelessWidget {
  const Mach3OffsetsView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        const Text('WORK COORDINATE SYSTEMS (G54 - G59)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber)),
        const Divider(color: Colors.white24),
        for (var fixture in ['G54', 'G55', 'G56', 'G57', 'G58', 'G59'])
          Card(
            color: const Color(0xFF131922),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fixture, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan)),
                  const Text('X: 0.0000  Y: 0.0000  Z: 0.0000', style: TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  OutlinedButton(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(minimumSize: const Size(60, 28)),
                    child: const Text('Zero', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ==========================================
// TAB 2: Tool Table View (Mach3 Tool Table)
// ==========================================
class Mach3ToolTableView extends StatelessWidget {
  const Mach3ToolTableView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        const Text('MACH3 TOOL TABLE (TOOL LIBRARY)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber)),
        const Divider(color: Colors.white24),
        for (int i = 1; i <= 8; i++)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: const Color(0xFF131922), border: Border.all(color: Colors.white10)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Tool #$i', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                const Text('Dia: 3.175 mm', style: TextStyle(fontFamily: 'monospace', fontSize: 11)),
                const Text('Offset Z: 0.000', style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white60)),
              ],
            ),
          ),
      ],
    );
  }
}
