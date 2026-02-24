import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:tflite_v2/tflite_v2.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

// --- 1. STATE MANAGEMENT ---
class AppStateProvider extends ChangeNotifier {
  Locale _locale = const Locale('English');
  String _userName = "Farmer";
  String _cropType = "General Crops";
  String _landSize = "";
  String _soilType = "Alluvial";

  Locale get locale => _locale;
  String get userName => _userName;
  String get cropType => _cropType;
  String get landSize => _landSize;
  String get soilType => _soilType;

  AppStateProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _userName = prefs.getString('user_name') ?? "Farmer";
    _cropType = prefs.getString('crop_type') ?? "General Crops";
    _landSize = prefs.getString('land_size') ?? "";
    _soilType = prefs.getString('soil_type') ?? "Alluvial";
    _locale = Locale(prefs.getString('language_code') ?? 'English');
    notifyListeners();
  }

  Future<void> updateProfile(
    String name,
    String crop,
    String land,
    String soil,
  ) async {
    _userName = name;
    _cropType = crop;
    _landSize = land;
    _soilType = soil;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    await prefs.setString('crop_type', crop);
    await prefs.setString('land_size', land);
    await prefs.setString('soil_type', soil);
    notifyListeners();
  }

  Future<void> setLocale(String code) async {
    _locale = Locale(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', code);
    notifyListeners();
  }
}

// --- 2. WEATHER SERVICE ---
class WeatherService {
  static Future<String> getLiveWeather() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        await Geolocator.requestPermission();
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );
      final weatherKey = dotenv.env['OPENWEATHER_API_KEY'] ?? "";
      final url =
          'https://api.openweathermap.org/data/2.5/weather?lat=${pos.latitude}&lon=${pos.longitude}&appid=$weatherKey&units=metric';
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return "${data['weather'][0]['description']}, ${data['main']['temp']}°C";
      }
      return "Weather data unavailable";
    } catch (e) {
      return "Location not accessible";
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase init failed: $e");
  }
  await dotenv.load(fileName: ".env");
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppStateProvider(),
      child: const FarmDoctorApp(),
    ),
  );
}

class FarmDoctorApp extends StatelessWidget {
  const FarmDoctorApp({super.key});
  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppStateProvider>(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: state.locale,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B7B4C)),
      ),
      home: const PlantDiseaseScreen(),
    );
  }
}

// --- 3. MAIN SCREEN ---
class PlantDiseaseScreen extends StatefulWidget {
  const PlantDiseaseScreen({super.key});
  @override
  State<PlantDiseaseScreen> createState() => _PlantDiseaseScreenState();
}

class _PlantDiseaseScreenState extends State<PlantDiseaseScreen> {
  File? _image;
  bool _isLoading = false;
  String _dynamicAdvice = "";
  String _detectedLabel = "Plant";
  final FlutterTts _flutterTts = FlutterTts();
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    Tflite.loadModel(
      model: "assets/plant_model.tflite",
      labels: "assets/labels.txt",
    );
  }

  Future<void> _generatePDF() async {
    if (_dynamicAdvice.isEmpty || _image == null) return;
    final pdf = pw.Document();
    final image = pw.MemoryImage(_image!.readAsBytesSync());
    final String cleanAdvice = _dynamicAdvice
        .replaceAll(RegExp(r'[*#]'), '')
        .trim();

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Header(level: 0, child: pw.Text("Farm Doctor AI Report")),
            pw.SizedBox(height: 10),
            pw.Image(image, height: 200),
            pw.SizedBox(height: 20),
            pw.Text(
              "Diagnosis: $_detectedLabel",
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.Divider(),
            pw.Paragraph(
              text: cleanAdvice,
              style: const pw.TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'Diagnosis_${_detectedLabel.replaceAll(' ', '_')}.pdf',
    );
  }

  Future<void> _speak() async {
    if (_isSpeaking) {
      await _flutterTts.stop();
      setState(() => _isSpeaking = false);
    } else {
      setState(() => _isSpeaking = true);
      await _flutterTts.speak(_dynamicAdvice.replaceAll(RegExp(r'[*#]'), ''));
      _flutterTts.setCompletionHandler(
        () => setState(() => _isSpeaking = false),
      );
    }
  }

  Future<void> _processImage(ImageSource source) async {
    final file = await ImagePicker().pickImage(source: source);
    if (file == null) return;
    setState(() {
      _image = File(file.path);
      _isLoading = true;
      _dynamicAdvice = "";
    });
    var output = await Tflite.runModelOnImage(
      path: _image!.path,
      numResults: 1,
      threshold: 0.5,
    );
    _detectedLabel = output != null && output.isNotEmpty
        ? output[0]['label']
        : "Scanning...";
    _getAIAdvice();
  }

  Future<void> _getAIAdvice() async {
    final state = Provider.of<AppStateProvider>(context, listen: false);
    String weather = await WeatherService.getLiveWeather();
    try {
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: dotenv.env['GEMINI_API_KEY']!,
      );
      final imagePart = DataPart('image/jpeg', await _image!.readAsBytes());
      final promptText =
          'Expert Agronomist Analysis for ${state.userName}. Weather: $weather. Crop: ${state.cropType}. Soil: ${state.soilType}. CRITICAL: Strictly identify the plant species. Start response with # Plant Identified: [Name]. Provide Summary, Immediate Action, and Cure. Language: ${state.locale.languageCode}.';
      final response = await model.generateContent([
        Content.multi([TextPart(promptText), imagePart]),
      ]);
      String advice = response.text ?? "Error: No data";
      if (advice.contains("# Plant Identified:")) {
        setState(
          () => _detectedLabel = advice
              .split('\n')[0]
              .replaceAll('# Plant Identified:', '')
              .trim(),
        );
      }
      setState(() {
        _isLoading = false;
        _dynamicAdvice = advice;
      });
      final prefs = await SharedPreferences.getInstance();
      List<String> history = prefs.getStringList('scan_history') ?? [];
      history.insert(
        0,
        "${DateTime.now().toString().split('.')[0]}|$_detectedLabel|$advice",
      );
      await prefs.setStringList('scan_history', history);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _dynamicAdvice = "AI Error: $e";
      });
    }
  }

  Widget _buildActionBtn(IconData icon, VoidCallback onPressed) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.5),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: const Color(0xFF1B5E20), size: 20),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCreativeBtn(
    String label,
    IconData icon,
    VoidCallback onTap,
    bool isPrimary,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFF1B7B4C) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: isPrimary ? Colors.green.withOpacity(0.3) : Colors.black12,
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
          border: isPrimary ? null : Border.all(color: Colors.green.shade100),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isPrimary ? Colors.white : Colors.green,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isPrimary ? Colors.white : Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "FARM DOCTOR AI",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF1B5E20),
          ),
        ),
        actions: [
          _buildActionBtn(
            Icons.history,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const HistoryScreen()),
            ),
          ),
          _buildActionBtn(
            Icons.groups,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const CommunityFeedScreen()),
            ),
          ),
          _buildActionBtn(
            Icons.settings,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (c) => const ProfileScreen()),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.green.shade100, Colors.white, Colors.white],
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: kToolbarHeight + 40),
              Consumer<AppStateProvider>(
                builder: (context, state, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Hello, ${state.userName}!",
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B5E20),
                            ),
                          ),
                          const Text(
                            "Let's diagnose your crops.",
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                      const CircleAvatar(
                        radius: 25,
                        backgroundColor: Colors.green,
                        child: Icon(Icons.person, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                margin: const EdgeInsets.all(20),
                height: _image == null ? 200 : 350,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(30),
                  image: _image != null
                      ? DecorationImage(
                          image: FileImage(_image!),
                          fit: BoxFit.cover,
                        )
                      : null,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: _image == null
                    ? Center(
                        child: Icon(
                          Icons.eco_outlined,
                          size: 80,
                          color: Colors.green.withOpacity(0.2),
                        ),
                      )
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildCreativeBtn(
                        "Scan",
                        Icons.camera_alt,
                        () => _processImage(ImageSource.camera),
                        true,
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: _buildCreativeBtn(
                        "Gallery",
                        Icons.image,
                        () => _processImage(ImageSource.gallery),
                        false,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                )
              else if (_dynamicAdvice.isNotEmpty)
                Container(
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.1),
                        blurRadius: 20,
                      ),
                    ],
                    border: Border.all(color: Colors.green.shade50, width: 2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Label Chip
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                _detectedLabel,
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Voice Button
                          IconButton(
                            icon: Icon(
                              _isSpeaking
                                  ? Icons.stop_circle
                                  : Icons.play_circle_filled,
                              color: Colors.green,
                              size: 28,
                            ),
                            onPressed: _speak,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 10),
                          // PDF Button (Unified)
                          IconButton(
                            icon: const Icon(
                              Icons.picture_as_pdf,
                              color: Colors.redAccent,
                              size: 28,
                            ),
                            onPressed: _generatePDF,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      MarkdownBody(data: _dynamicAdvice),
                    ],
                  ),
                ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 4. HISTORY SCREEN ---
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan History")),
      body: FutureBuilder<SharedPreferences>(
        future: SharedPreferences.getInstance(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          List<String> history =
              snapshot.data!.getStringList('scan_history') ?? [];
          if (history.isEmpty) return const Center(child: Text("No scans yet"));
          return ListView.builder(
            itemCount: history.length,
            itemBuilder: (context, i) {
              var parts = history[i].split('|');
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE8F5E9),
                    child: Icon(Icons.eco, color: Colors.green),
                  ),
                  title: Text(
                    parts[1],
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(parts[0]),
                  onTap: () => showDialog(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(parts[1]),
                      content: SizedBox(
                        width: double.maxFinite,
                        child: SingleChildScrollView(
                          child: MarkdownBody(data: parts[2]),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text("Close"),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// --- 5. COMMUNITY FEED ---
class CommunityFeedScreen extends StatelessWidget {
  const CommunityFeedScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Community Feed")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('community_posts')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          return ListView.builder(
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, i) {
              var post = snapshot.data!.docs[i];
              return Card(
                margin: const EdgeInsets.all(12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(
                        post['farmer'],
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text("Diagnosed: ${post['crop']}"),
                    ),
                    Image.network(
                      post['imageUrl'],
                      height: 250,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) =>
                          const Icon(Icons.broken_image, size: 50),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(15),
                      child: MarkdownBody(data: post['advice']),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// --- 6. PROFILE SCREEN ---
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _n, _c, _l;
  String _soil = "Alluvial";
  @override
  void initState() {
    super.initState();
    final s = Provider.of<AppStateProvider>(context, listen: false);
    _n = TextEditingController(text: s.userName);
    _c = TextEditingController(text: s.cropType);
    _l = TextEditingController(text: s.landSize);
    _soil = s.soilType;
  }

  @override
  Widget build(BuildContext context) {
    final s = Provider.of<AppStateProvider>(context);
    return Scaffold(
      appBar: AppBar(title: const Text("Farmer Settings")),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _n,
            decoration: const InputDecoration(
              labelText: "Name",
              prefixIcon: Icon(Icons.person),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c,
            decoration: const InputDecoration(
              labelText: "Main Crop",
              prefixIcon: Icon(Icons.agriculture),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _l,
            decoration: const InputDecoration(
              labelText: "Acres",
              prefixIcon: Icon(Icons.landscape),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "Soil Type",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          DropdownButton<String>(
            isExpanded: true,
            value: _soil,
            items: [
              'Alluvial',
              'Black',
              'Red',
              'Laterite',
            ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => setState(() => _soil = v!),
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7B4C),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
            ),
            onPressed: () {
              s.updateProfile(_n.text, _c.text, _l.text, _soil);
              Navigator.pop(context);
            },
            child: const Text("Save Profile"),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(),
          ),
          const Text(
            "Select Language",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Wrap(
            spacing: 10,
            children:
                [
                      'English',
                      'हिन्दी',
                      'தமிழ்',
                      'తెలుగు',
                      'मराठी',
                      'বাঙালি',
                      'മലയലം',
                      'ಕನ್ನಡಾ',
                    ]
                    .map(
                      (l) => ActionChip(
                        label: Text(l),
                        onPressed: () => s.setLocale(l),
                      ),
                    )
                    .toList(),
          ),
        ],
      ),
    );
  }
}
