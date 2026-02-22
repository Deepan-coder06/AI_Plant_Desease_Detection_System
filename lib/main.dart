import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:tflite_v2/tflite_v2.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // Security added

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the environment variables before starting the app
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Warning: .env file not found. Ensure your API key is set.");
  }
  runApp(const LeafGuardApp());
}

class LeafGuardApp extends StatelessWidget {
  const LeafGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Farm Doctor AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F7F4),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2EA57B),
          primary: const Color(0xFF1B7B4C),
          secondary: const Color(0xFF819A20),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1B7B4C),
          foregroundColor: Colors.white,
          centerTitle: true,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            backgroundColor: const Color(0xFF2EA57B),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ),
      home: const PlantDiseaseScreen(),
    );
  }
}

class PlantDiseaseScreen extends StatefulWidget {
  const PlantDiseaseScreen({super.key});

  @override
  State<PlantDiseaseScreen> createState() => _PlantDiseaseScreenState();
}

class _PlantDiseaseScreenState extends State<PlantDiseaseScreen> {
  File? _image;
  List? _results;
  bool _isLoading = false;
  String _dynamicAdvice = "";
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _textController = TextEditingController();
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;

  // Retrieve API Key from .env file for security
  final String _apiKey = dotenv.env['GEMINI_API_KEY'] ?? "";

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    await Tflite.loadModel(
      model: "assets/plant_model.tflite",
      labels: "assets/labels.txt",
    );
  }

  void _listen() async {
    if (!_isListening) {
      bool available = await _speechToText.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speechToText.listen(
          onResult: (val) => setState(() {
            _textController.text = val.recognizedWords;
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speechToText.stop();
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final pickedFile = await _picker.pickImage(source: source);
    if (pickedFile == null) return;

    setState(() {
      _isLoading = true;
      _image = File(pickedFile.path);
      _dynamicAdvice = "";
    });

    _classifyImage(_image!);
  }

  Future<void> _classifyImage(File image) async {
    var output = await Tflite.runModelOnImage(
      path: image.path,
      numResults: 1,
      threshold: 0.5,
      imageMean: 0.0,
      imageStd: 255.0,
    );

    setState(() => _results = output);

    String localGuess = (_results != null && _results!.isNotEmpty)
        ? _results![0]['label']
        : "Unknown";

    _fetchMultimodalGeminiAdvice(localGuess, image);
  }

  Future<void> _fetchMultimodalGeminiAdvice(
    String localGuess,
    File imageFile,
  ) async {
    if (_apiKey.isEmpty) {
      setState(() {
        _isLoading = false;
        _dynamicAdvice =
            "Error: Gemini API Key missing. Please check your .env file.";
      });
      return;
    }

    setState(() => _dynamicAdvice = "AI is visually analyzing the plant...");

    try {
      final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: _apiKey);
      final imageBytes = await imageFile.readAsBytes();
      final imagePart = DataPart('image/jpeg', imageBytes);

      String extraDetails = _textController.text.isNotEmpty
          ? "The farmer also provided these extra details: '${_textController.text}'."
          : "";

      final promptText = TextPart('''
        Act as an expert agronomist. Look directly at this plant image.
        Local AI diagnosis: "$localGuess". 
        $extraDetails
        
        Verify the diagnosis. If wrong, correct it. Provide a step-by-step treatment plan.
        
        ### 🛑 Immediate Action
        [Instructions]
        
        ### 🧪 Chemical Treatment
        * **Agrochemicals:** [Chemical names]
        * **Dosage:** [Step-by-step]
        
        ### 🌿 Organic Cure
        [Step-by-Step natural remedies]
        
        ### 🛡️ Prevention
        [Actionable steps]
      ''');

      final response = await model.generateContent([
        Content.multi([promptText, imagePart]),
      ]);

      setState(() {
        _isLoading = false;
        _dynamicAdvice = response.text ?? "Could not generate advice.";
      });

      _saveScanToHistory(imageFile, localGuess, _dynamicAdvice);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _dynamicAdvice = "Error connecting to AI: $e";
      });
    }
  }

  Future<void> _saveScanToHistory(
    File image,
    String diagnosis,
    String advice,
  ) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final String newImagePath =
          '${directory.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await image.copy(newImagePath);

      SharedPreferences prefs = await SharedPreferences.getInstance();
      List<String> history = prefs.getStringList('scan_history') ?? [];
      Map<String, dynamic> newScan = {
        'imagePath': newImagePath,
        'diagnosis': diagnosis,
        'advice': advice,
        'date': DateTime.now().toString().split('.')[0],
      };
      history.add(jsonEncode(newScan));
      await prefs.setStringList('scan_history', history);
    } catch (e) {
      debugPrint("History Save Error: $e");
    }
  }

  @override
  void dispose() {
    Tflite.close();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "FARM DOCTOR AI",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.history_rounded, size: 28),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ScanHistoryScreen()),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_rounded, size: 28),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const UserProfileScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFF1B7B4C),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
              ),
              padding: const EdgeInsets.only(bottom: 30, top: 10),
              child: const Column(
                children: [
                  Text(
                    "Crop Health Scanner",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Identify diseases instantly",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                height: 280,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _image != null
                    ? Image.file(_image!, fit: BoxFit.cover)
                    : Center(
                        child: Icon(
                          Icons.local_florist_rounded,
                          size: 60,
                          color: Colors.green.shade200,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 25),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: "Add symptoms...",
                  prefixIcon: const Icon(
                    Icons.edit_note,
                    color: Color(0xFF819A20),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: _isListening
                          ? Colors.redAccent
                          : const Color(0xFF1B7B4C),
                    ),
                    onPressed: _listen,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 25),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_rounded),
                  label: const Text("Take Photo"),
                ),
                ElevatedButton.icon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF1B7B4C),
                    side: const BorderSide(color: Color(0xFF1B7B4C)),
                  ),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text("Gallery"),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_isLoading)
              const CircularProgressIndicator(color: Color(0xFF2EA57B))
            else if (_dynamicAdvice.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE8F5E9), Color(0xFFF1F8E9)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: MarkdownBody(
                    data: _dynamicAdvice,
                    styleSheet: MarkdownStyleSheet(
                      h3: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B7B4C),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// --- SCAN HISTORY SCREEN ---
class ScanHistoryScreen extends StatefulWidget {
  const ScanHistoryScreen({super.key});
  @override
  State<ScanHistoryScreen> createState() => _ScanHistoryScreenState();
}

class _ScanHistoryScreenState extends State<ScanHistoryScreen> {
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> savedHistory = prefs.getStringList('scan_history') ?? [];
    setState(() {
      _history = savedHistory
          .map((item) => jsonDecode(item) as Map<String, dynamic>)
          .toList()
          .reversed
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan History")),
      body: _history.isEmpty
          ? const Center(child: Text("No scans found."))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final scan = _history[index];
                return Card(
                  child: ListTile(
                    leading: Image.file(
                      File(scan['imagePath']),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                    title: Text(
                      scan['diagnosis'],
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(scan['date']),
                    trailing: IconButton(
                      icon: const Icon(Icons.share, color: Color(0xFF2EA57B)),
                      onPressed: () => Share.share(
                        "Scan: ${scan['diagnosis']}\nAdvice: ${scan['advice']}",
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// --- USER PROFILE SCREEN ---
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});
  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _farmController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _nameController.text = prefs.getString('user_name') ?? "";
      _farmController.text = prefs.getString('farm_name') ?? "";
    });
  }

  Future<void> _saveProfile() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', _nameController.text);
    await prefs.setString('farm_name', _farmController.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Farmer Profile")),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: "Your Name"),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _farmController,
              decoration: const InputDecoration(labelText: "Farm Name"),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _saveProfile,
              child: const Text("Save Profile"),
            ),
          ],
        ),
      ),
    );
  }
}
