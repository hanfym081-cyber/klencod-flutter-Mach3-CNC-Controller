import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CncApp());
}

class CncApp extends StatelessWidget {
  const CncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 Android Remote',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF10151D),
        useMaterial3: true,
      ),
      home: const MainScreen(),
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

  const GCodeResult({
    required this.points,
    required this.lines,
    required this.movements,
    required this.distance,
  });
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

      final words = RegExp(r'([A-Z])([-+]?\d*\.?\d+)')
          .allMatches(line);

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

      if (values.containsKey('X') ||
          values.containsKey('Y') ||
          values.containsKey('Z')) {
        final oldX = x, oldY = y, oldZ = z;

        if (values.containsKey('X')) {
          final value = values['X']! * scale;
          x = absolute ? value : x + value;
        }
        if (values.containsKey('Y')) {
          final value = values['Y']! * scale;
          y = absolute ? value : y + value;
        }
        if (values.containsKey('Z')) {
          final value = values['Z']! * scale;
          z = absolute ? value : z + value;
        }

        distance += math.sqrt(
          math.pow(x - oldX, 2) +
          math.pow(y - oldY, 2) +
          math.pow(z - oldZ, 2),
        );

        movements++;
        points.add(GPoint(x, y, z, rapid));
      }
    }

    return GCodeResult(
      points: points,
      lines: lines.length,
      movements: movements,
      distance: distance,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int page = 0;
  String fileName = 'No file selected';
  String gcode = '';
  GCodeResult? result;

  // Network Connection State
  bool connected = false;
  Socket? pcSocket;
  String pcIp = '192.168.1.100';
  int pcPort = 50002;
  
  // Live DRO (Digital Readouts) from PC
  double droX = 0.0;
  double droY = 0.0;
  double droZ = 0.0;
  bool estop = false;
  bool limitHit = false;

  final pages = const [
    'Dashboard',
    'Program Run',
    'Toolpath',
    'MDI & Control',
    'Jog Controller',
    'Work Offsets',
    'Tool Table',
    'Fixtures (G54-G59)',
    'Diagnostics & Limits',
    'Settings',
  ];

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

  // Connect to PC via TCP/IP Wi-Fi
  Future<void> connectToPC() async {
    try {
      showMessage('Connecting to $pcIp:$pcPort...');
      pcSocket = await Socket.connect(pcIp, pcPort, timeout: const Duration(seconds: 5));
      setState(() => connected = true);
      showMessage('Connected to PC successfully!');

      pcSocket!.listen(
        (data) {
          final message = utf8.decode(data);
          parsePcData(message);
        },
        onDone: () {
          disconnectFromPC();
          showMessage('Connection closed by PC');
        },
        onError: (error) {
          disconnectFromPC();
          showMessage('Connection error: $error');
        },
      );
    } catch (e) {
      disconnectFromPC();
      showMessage('Failed to connect: $e');
    }
  }

  void disconnectFromPC() {
    pcSocket?.destroy();
    pcSocket = null;
    setState(() => connected = false);
  }

  void sendCommand(String cmd) {
    if (!connected || pcSocket == null) {
      showMessage('Not connected to PC!');
      return;
    }
    pcSocket!.write('$cmd\n');
  }

  void parsePcData(String data) {
    // Expected format from PC script: DRO:X=10.5,Y=20.0,Z=-2.1;ESTOP=0
    try {
      if (data.startsWith('DRO:')) {
        final parts = data.substring(4).trim().split(';');
        for (var part in parts) {
          if (part.startsWith('X=')) droX = double.parse(part.substring(2));
          if (part.startsWith('Y=')) droY = double.parse(part.substring(2));
          if (part.startsWith('Z=')) droZ = double.parse(part.substring(2));
          if (part.startsWith('ESTOP=')) estop = part.substring(6) == '1';
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

      if (bytes == null) {
        showMessage('Could not read file');
        return;
      }

      final content = String.fromCharCodes(bytes);
      final parsed = GCodeParser.parse(content);

      setState(() {
        fileName = file.name;
        gcode = content;
        result = parsed;
      });

      // Send file content or path to PC if connected
      if (connected) {
        sendCommand('LOAD_FILE:${file.name}');
      }

      showMessage('G-code loaded successfully');
    } catch (e) {
      showMessage('File error: $e');
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget buildPage() {
    switch (page) {
      case 0: return dashboard();
      case 1: return programPage();
      case 2: return toolpathPage();
      case 3: return mdiPage();
      case 4: return jogPage();
      case 5: return offsetsPage();
      case 6: return toolsPage();
      case 7: return fixturesPage();
      case 8: return diagnosticsPage();
      case 9: return settingsPage();
      default: return dashboard();
    }
  }

  Widget panel(String title, Widget child) {
    return Card(
      color: const Color(0xFF1B2430),
      margin: const EdgeInsets.symmetric(vertical: 7),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget stat(String title, String value, IconData icon) {
    return Card(
      color: const Color(0xFF1B2430),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.cyan, size: 25),
            const SizedBox(height: 9),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(color: Colors.white60)),
          ],
        ),
      ),
    );
  }

  // --- 1. Dashboard Page ---
  Widget dashboard() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Text('MACH3 WIFI CONTROL CENTER', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        const Text('Remote Android Companion for Mach3 PC', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 15),
        
        // Connection Panel
        panel(
          'PC Wi-Fi Connection',
          Column(
            children: [
              Row(
                children: [
                  Icon(connected ? Icons.check_circle : Icons.link_off, color: connected ? Colors.green : Colors.orange),
                  const SizedBox(width: 10),
                  Expanded(child: Text(connected ? 'Connected to $pcIp' : 'Disconnected from PC')),
                  FilledButton.icon(
                    onPressed: connected ? disconnectFromPC : connectToPC,
                    icon: Icon(connected ? Icons.logout : Icons.login),
                    label: Text(connected ? 'Disconnect' : 'Connect'),
                    style: FilledButton.styleFrom(backgroundColor: connected ? Colors.red : Colors.cyan),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Live DRO View
        panel(
          'Live DRO (Digital Readouts)',
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              droBox('X', droX, Colors.cyan),
              droBox('Y', droY, Colors.green),
              droBox('Z', droZ, Colors.orange),
            ],
          ),
        ),

        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 1.55,
          children: [
            stat('G-code lines', '${result?.lines ?? 0}', Icons.description),
            stat('Movements', '${result?.movements ?? 0}', Icons.timeline),
            stat('Distance', '${(result?.distance ?? 0).toStringAsFixed(2)} mm', Icons.straighten),
            stat('Loaded file', fileName.length > 15 ? '${fileName.substring(0, 12)}...' : fileName, Icons.folder_open),
          ],
        ),
      ],
    );
  }

  Widget droBox(String axis, double val, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1017),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Text(axis, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          Text(val.toStringAsFixed(3), style: const TextStyle(fontSize: 22, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // --- 2. Program Run Page ---
  Widget programPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel(
          'G-code Control',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: openFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open File'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => sendCommand('CYCLE_START'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Cycle Start'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => sendCommand('FEED_HOLD'),
                    icon: const Icon(Icons.pause),
                    label: const Text('Feed Hold'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                  ),
                ],
              ),
            ],
          ),
        ),
        panel(
          'G-code Preview',
          SizedBox(
            height: 300,
            child: SingleChildScrollView(
              child: SelectableText(
                gcode.isEmpty ? 'No program loaded' : gcode,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- 3. Toolpath Page ---
  Widget toolpathPage() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Expanded(child: Text('Toolpath 3D/2D View', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
              Text('${result?.points.length ?? 0} points'),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF080D13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: result == null
                ? const Center(child: Text('Load a G-code file first'))
                : CustomPaint(
                    painter: ToolpathPainter(result!.points),
                    child: const SizedBox.expand(),
                  ),
          ),
        ),
      ],
    );
  }

  // --- 4. MDI & Control ---
  Widget mdiPage() {
    final mdiController = TextEditingController();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel(
          'MDI (Manual Data Input)',
          Column(
            children: [
              TextField(
                controller: mdiController,
                decoration: const InputDecoration(
                  labelText: 'Enter G-code (e.g. G0 X0 Y0)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  sendCommand('MDI:${mdiController.text}');
                  showMessage('Sent MDI: ${mdiController.text}');
                  mdiController.clear();
                },
                icon: const Icon(Icons.send),
                label: const Text('Send Command'),
              ),
            ],
          ),
        ),
        panel(
          'Mach3 Quick Macros',
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ActionChip(label: const Text('Home All (G28)'), onPressed: () => sendCommand('MACRO:HOME')),
              ActionChip(label: const Text('Spindle On'), onPressed: () => sendCommand('M3 S12000')),
              ActionChip(label: const Text('Spindle Off'), onPressed: () => sendCommand('M5')),
              ActionChip(label: const Text('Reset Mach3'), onPressed: () => sendCommand('RESET')),
            ],
          ),
        ),
      ],
    );
  }

  // --- 5. Jog Controller ---
  Widget jogPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel(
          'Manual Axis Jogging',
          Column(
            children: [
              const Text('Continuous / Step Jog', style: TextStyle(color: Colors.white60)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  jogButton('Y+', () => sendCommand('JOG:Y+')),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  jogButton('X-', () => sendCommand('JOG:X-')),
                  const SizedBox(width: 40),
                  jogButton('X+', () => sendCommand('JOG:X+')),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  jogButton('Y-', () => sendCommand('JOG:Y-')),
                ],
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  jogButton('Z+', () => sendCommand('JOG:Z+'), color: Colors.orange),
                  const SizedBox(width: 20),
                  jogButton('Z-', () => sendCommand('JOG:Z-'), color: Colors.orange),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget jogButton(String label, VoidCallback onPressed, {Color color = Colors.cyan}) {
    return SizedBox(
      width: 80,
      height: 80,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(backgroundColor: color.withOpacity(0.2), side: BorderSide(color: color)),
        child: Text(label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
      ),
    );
  }

  // --- 6. Work Offsets (G54 - G59) ---
  Widget offsetsPage() => const OffsetPage();

  // --- 7. Tool Table ---
  Widget toolsPage() => const ToolTablePage();

  // --- 8. Fixtures Page ---
  Widget fixturesPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel('Coordinate Systems (Fixtures)', Column(
          children: [
            for (var g in ['G54', 'G55', 'G56', 'G57', 'G58', 'G59'])
              ListTile(
                title: Text('Work Coordinate System: $g'),
                trailing: FilledButton(
                  onPressed: () => sendCommand('FIXTURE:$g'),
                  child: const Text('Select'),
                ),
              ),
          ],
        )),
      ],
    );
  }

  // --- 9. Diagnostics ---
  Widget diagnosticsPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel('Mach3 Status & Diagnostics', Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('E-Stop Status: ${estop ? "TRIGGERED (ACTIVE)" : "OK"}', style: TextStyle(color: estop ? Colors.red : Colors.green)),
            const SizedBox(height: 10),
            Text('Limit Switches: ${limitHit ? "TRIGGERED" : "Normal"}'),
            const SizedBox(height: 10),
            Text('Network Socket: ${connected ? "Active ($pcIp)" : "Offline"}'),
          ],
        )),
      ],
    );
  }

  // --- 10. Settings ---
  Widget settingsPage() {
    final ipController = TextEditingController(text: pcIp);
    final portController = TextEditingController(text: pcPort.toString());

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel('PC Network Settings', Column(
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: 'Computer IP Address (e.g. 192.168.1.100)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port (default 50002)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() {
                  pcIp = ipController.text.trim();
                  pcPort = int.tryParse(portController.text.trim()) ?? 50002;
                });
                savePreferences();
                showMessage('Settings saved!');
              },
              child: const Text('Save Settings'),
            ),
          ],
        )),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pages[page]),
        backgroundColor: const Color(0xFF151E29),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFF172C3B)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.precision_manufacturing, size: 45, color: Colors.cyan),
                  SizedBox(height: 10),
                  Text('Mach3 Remote', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  Text('Full Milling Control Suite'),
                ],
              ),
            ),
            for (int i = 0; i < pages.length; i++)
              ListTile(
                selected: page == i,
                leading: Icon(_pageIcon(i)),
                title: Text(pages[i]),
                onTap: () {
                  setState(() => page = i);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
      body: buildPage(),
    );
  }

  IconData _pageIcon(int i) {
    const icons = [
      Icons.dashboard,
      Icons.play_circle_outline,
      Icons.route,
      Icons.terminal,
      Icons.gamepad,
      Icons.tune,
      Icons.build,
      Icons.grid_view,
      Icons.monitor_heart,
      Icons.settings,
    ];
    return icons[i];
  }
}

class ToolpathPainter extends CustomPainter {
  final List<GPoint> points;
  ToolpathPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()..color = Colors.white24..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), axisPaint);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), axisPaint);

    if (points.isEmpty) return;

    double minX = points.map((p) => p.x).reduce(math.min);
    double maxX = points.map((p) => p.x).reduce(math.max);
    double minY = points.map((p) => p.y).reduce(math.min);
    double maxY = points.map((p) => p.y).reduce(math.max);

    final dx = maxX - minX;
    final dy = maxY - minY;
    final scale = math.min((size.width - 40) / (dx == 0 ? 1.0 : dx), (size.height - 40) / (dy == 0 ? 1.0 : dy));

    Offset mapPoint(GPoint p) => Offset(20 + (p.x - minX) * scale, size.height - 20 - (p.y - minY) * scale);

    for (int i = 1; i < points.length; i++) {
      final a = mapPoint(points[i - 1]);
      final b = mapPoint(points[i]);
      final paint = Paint()
        ..color = points[i].rapid ? Colors.green : Colors.cyan
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter oldDelegate) => oldDelegate.points != points;
}

class OffsetPage extends StatelessWidget {
  const OffsetPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Work Offsets (G54 - G59)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        for (var axis in ['X', 'Y', 'Z'])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: InputDecoration(labelText: '$axis Offset (mm)', border: const OutlineInputBorder()),
              ),
            ),
          ),
      ],
    );
  }
}

class ToolTablePage extends StatelessWidget {
  const ToolTablePage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Text('Tool Table (Mach3 Mill)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        for (int i = 1; i <= 5; i++)
          Card(
            child: ListTile(
              leading: const Icon(Icons.build, color: Colors.cyan),
              title: Text('Tool #$i'),
              subtitle: const Text('Diameter: 3.175 mm | Height Offset: 0.00'),
            ),
          ),
      ],
    );
  }
}
