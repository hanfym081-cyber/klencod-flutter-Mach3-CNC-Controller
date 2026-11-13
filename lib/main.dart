
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
      title: 'CNC Controller',
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
  bool connected = false;

  final pages = const [
    'Dashboard',
    'Program Run',
    'Toolpath',
    'MDI',
    'Jog',
    'Offsets',
    'Tool Table',
    'Diagnostics',
    'Settings',
  ];

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
      case 0:
        return dashboard();
      case 1:
        return programPage();
      case 2:
        return toolpathPage();
      case 3:
        return mdiPage();
      case 4:
        return jogPage();
      case 5:
        return offsetsPage();
      case 6:
        return toolsPage();
      case 7:
        return diagnosticsPage();
      case 8:
        return settingsPage();
      default:
        return dashboard();
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
            Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
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
            Text(value,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(color: Colors.white60)),
          ],
        ),
      ),
    );
  }

  Widget dashboard() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Text('CNC CONTROL CENTER',
            style: TextStyle(
                fontSize: 21, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        const Text('Android CNC interface',
            style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 15),
        panel(
          'Machine Connection',
          Row(
            children: [
              Icon(
                connected ? Icons.check_circle : Icons.link_off,
                color: connected ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  connected ? 'Connected' : 'Not connected',
                ),
              ),
              const Chip(label: Text('OFFLINE')),
            ],
          ),
        ),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 1.55,
          children: [
            stat('G-code lines', '${result?.lines ?? 0}',
                Icons.description),
            stat('Movements', '${result?.movements ?? 0}',
                Icons.timeline),
            stat('Distance', '${(result?.distance ?? 0).toStringAsFixed(2)} mm',
                Icons.straighten),
            stat('Loaded program', result == null ? 'None' : 'Ready',
                Icons.folder_open),
          ],
        ),
        panel(
          'Current Program',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: openFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open G-code file'),
              ),
            ],
          ),
        ),
        panel(
          'System Status',
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Application: Ready'),
              Text('G-code parser: Available'),
              Text('Toolpath viewer: Available'),
              Text('Machine communication: Not configured'),
            ],
          ),
        ),
      ],
    );
  }

  Widget programPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel(
          'Program',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: openFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open G-code'),
              ),
            ],
          ),
        ),
        panel(
          'Program Information',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lines: ${result?.lines ?? 0}'),
              Text('Movements: ${result?.movements ?? 0}'),
              Text(
                'Distance: ${(result?.distance ?? 0).toStringAsFixed(3)} mm',
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
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
        const Text(
          'Run and machine-control commands are disabled until a real connection is implemented.',
          style: TextStyle(color: Colors.orange),
        ),
      ],
    );
  }

  Widget toolpathPage() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Expanded(
                child: Text('Toolpath Preview',
                    style: TextStyle(
                        fontSize: 19, fontWeight: FontWeight.bold)),
              ),
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
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Green: rapid movement | Cyan: cutting movement'),
        ),
      ],
    );
  }

  Widget disabledPage(String title, String description) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline,
                size: 55, color: Colors.orange),
            const SizedBox(height: 18),
            Text(title,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(description,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 15),
            const Chip(label: Text('NOT CONNECTED')),
          ],
        ),
      ),
    );
  }

  Widget mdiPage() => disabledPage(
        'MDI',
        'Manual G-code commands will be enabled after implementing and testing the machine connection.',
      );

  Widget jogPage() => disabledPage(
        'JOG CONTROL',
        'Axis movement is disabled until a verified machine connection and safety controls are available.',
      );

  Widget offsetsPage() => const OffsetPage();

  Widget toolsPage() => const ToolTablePage();

  Widget diagnosticsPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel('Application', const Text('Running')),
        panel('G-code Parser',
            Text(result == null ? 'Waiting for program' : 'Ready')),
        panel('Toolpath Engine',
            Text(result == null ? 'Waiting for program' : 'Ready')),
        panel('Machine Connection',
            const Text('Not implemented')),
        panel('Safety',
            const Text('Machine commands are locked')),
      ],
    );
  }

  Widget settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        panel('Application Settings', const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Application: CNC Controller'),
            Text('Platform: Android'),
            Text('Interface: Flutter'),
          ],
        )),
        panel('Connection Settings',
            const Text('Connection setup will be implemented after selecting the communication hardware.')),
        panel('About',
            const Text('CNC Controller - Initial Android version')),
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
                  Icon(Icons.precision_manufacturing,
                      size: 45, color: Colors.cyan),
                  SizedBox(height: 10),
                  Text('CNC Controller',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  Text('Mach3 Android Interface'),
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
    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        axisPaint);
    canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        axisPaint);

    if (points.isEmpty) return;

    double minX = points.map((p) => p.x).reduce(math.min);
    double maxX = points.map((p) => p.x).reduce(math.max);
    double minY = points.map((p) => p.y).reduce(math.min);
    double maxY = points.map((p) => p.y).reduce(math.max);

    final dx = maxX - minX;
    final dy = maxY - minY;
    final rangeX = dx == 0 ? 1.0 : dx;
    final rangeY = dy == 0 ? 1.0 : dy;

    final scale = math.min(
      (size.width - 40) / rangeX,
      (size.height - 40) / rangeY,
    );

    Offset mapPoint(GPoint p) {
      return Offset(
        20 + (p.x - minX) * scale,
        size.height - 20 - (p.y - minY) * scale,
      );
    }

    for (int i = 1; i < points.length; i++) {
      final a = mapPoint(points[i - 1]);
      final b = mapPoint(points[i]);

      final paint = Paint()
        ..color = points[i].rapid ? Colors.green : Colors.cyan
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(a, b, paint);
    }

    final startPaint = Paint()..color = Colors.orange;
    final endPaint = Paint()..color = Colors.red;

    canvas.drawCircle(mapPoint(points.first), 5, startPaint);
    canvas.drawCircle(mapPoint(points.last), 5, endPaint);
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}

class OffsetPage extends StatefulWidget {
  const OffsetPage({super.key});

  @override
  State<OffsetPage> createState() => _OffsetPageState();
}

class _OffsetPageState extends State<OffsetPage> {
  final fields = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    for (final axis in ['X', 'Y', 'Z']) {
      fields[axis] = TextEditingController(text: '0.000');
    }
    load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final axis in ['X', 'Y', 'Z']) {
      fields[axis]!.text = prefs.getString('offset_$axis') ?? '0.000';
    }
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    for (final axis in ['X', 'Y', 'Z']) {
      await prefs.setString('offset_$axis', fields[axis]!.text);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offsets saved locally')),
      );
    }
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Work Offsets',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        for (final axis in ['X', 'Y', 'Z'])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: fields[axis],
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: '$axis Offset (mm)',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: save,
          child: const Text('Save Local Values'),
        ),
        const SizedBox(height: 10),
        const Text(
          'These values are stored on this Android device only. They are not sent to Mach3.',
          style: TextStyle(color: Colors.orange),
        ),
      ],
    );
  }
}

class ToolTablePage extends StatefulWidget {
  const ToolTablePage({super.key});

  @override
  State<ToolTablePage> createState() => _ToolTablePageState();
}

class _ToolTablePageState extends State<ToolTablePage> {
  List<String> tools = ['Tool 1', 'Tool 2', 'Tool 3'];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('cnc_tools');
    if (saved != null && mounted) {
      setState(() => tools = saved);
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('cnc_tools', tools);
  }

  Future<void> addTool() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Tool'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Tool name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      setState(() => tools.add(name));
      await save();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: addTool,
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text('Tool Table',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          for (int i = 0; i < tools.length; i++)
            Card(
              child: ListTile(
                leading: const Icon(Icons.build, color: Colors.cyan),
                title: Text(tools[i]),
                subtitle: Text('Tool number: ${i + 1}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    setState(() => tools.removeAt(i));
                    await save();
                  },
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Tool data is stored locally. It is not yet synchronized with Mach3.',
            style: TextStyle(color: Colors.orange),
          ),
        ],
      ),
    );
  }
}
