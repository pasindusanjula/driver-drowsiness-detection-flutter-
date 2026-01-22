import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';

late List<CameraDescription> cameras;

class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key});

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen> {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isCameraInitialized = false;
  bool alarmPlaying = false;
  int closedEyeCounter = 0;
  String statusText = "Initializing...";
  Color statusColor = Colors.blue;

  // Store context locally
  late BuildContext _context;

  @override
  void initState() {
    super.initState();
    // Use WidgetsBinding to safely access context
    WidgetsBinding.instance.addPostFrameCallback((_) {
      initEverything();
    });
  }

  Future<void> initEverything() async {
    // Store context
    _context = context;

    // Request camera permission
    var status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(_context).showSnackBar(
          const SnackBar(content: Text("Camera permission is required!")),
        );
      }
      return;
    }

    try {
      // Initialize cameras
      cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception("No cameras found");
      }

      // Use front camera if available, otherwise use first camera
      int cameraIndex = cameras.length > 1 ? 1 : 0;

      _cameraController = CameraController(
        cameras[cameraIndex],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      // Load TFLite model
      try {
        _interpreter = await Interpreter.fromAsset(
          'assets/models/mrl_drowsiness_model.tflite',
          options: InterpreterOptions()..threads = 4,
        );

        // Test model
        var inputShape = _interpreter!.getInputTensor(0).shape;
        var outputShape = _interpreter!.getOutputTensor(0).shape;
        print("Model loaded successfully");
        print("Input shape: $inputShape");
        print("Output shape: $outputShape");

      } catch (e) {
        print("Error loading model: $e");
        if (mounted) {
          ScaffoldMessenger.of(_context).showSnackBar(
            SnackBar(content: Text("Model error: $e")),
          );
        }
      }

      // Start camera stream
      await _cameraController!.startImageStream((image) {
        if (mounted && _interpreter != null) {
          processCameraImage(image);
        }
      });

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          statusText = "Monitoring...";
          statusColor = Colors.green;
        });
      }
    } catch (e) {
      print("Initialization error: $e");
      if (mounted) {
        ScaffoldMessenger.of(_context).showSnackBar(
          SnackBar(content: Text("Camera error: $e")),
        );
        setState(() {
          statusText = "Error: $e";
          statusColor = Colors.red;
        });
      }
    }
  }

  void processCameraImage(CameraImage cameraImage) {
    if (_interpreter == null || !mounted) return;

    try {
      // Get Y plane (grayscale)
      final width = cameraImage.width;
      final height = cameraImage.height;
      final yPlane = cameraImage.planes[0].bytes;

      // Create grayscale image
      final grayImage = img.Image(width: width, height: height);

      // Convert YUV to grayscale
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          int index = y * width + x;
          if (index < yPlane.length) {
            int pixel = yPlane[index] & 0xFF;
            grayImage.setPixel(x, y, img.ColorRgb8(pixel, pixel, pixel));
          }
        }
      }

      // Resize to 64x64 for model
      final resized = img.copyResize(grayImage, width: 64, height: 64);

      // Prepare input tensor [1, 64, 64, 1]
      var input = List.generate(
        64,
            (y) => List.generate(
          64,
              (x) {
            var pixel = resized.getPixel(x, y);
            // Convert to grayscale and normalize to [-1, 1]
            double value = ((pixel.r + pixel.g + pixel.b) / 3.0) / 255.0;
            return [value * 2.0 - 1.0]; // Normalize to [-1, 1]
          },
        ),
      );

      // Create output tensor
      var output = List.filled(1 * 2, 0.0).reshape([1, 2]);

      // Run inference
      _interpreter!.run(input.reshape([1, 64, 64, 1]), output);

      // Get predictions
      double closedScore = output[0][0];
      double openScore = output[0][1];
      int predicted = closedScore > openScore ? 0 : 1;

      // Update counter
      if (predicted == 0) {
        closedEyeCounter++;
      } else {
        closedEyeCounter = 0;
        if (alarmPlaying) {
          stopAlarm();
        }
      }

      // Trigger alarm after 15 consecutive closed frames (~0.5 seconds)
      if (closedEyeCounter > 15 && !alarmPlaying) {
        playAlarm();
      }

      // Update status text
      if (mounted) {
        setState(() {
          if (alarmPlaying) {
            statusText = "⚠ DROWSY DETECTED!";
            statusColor = Colors.red;
          } else if (closedEyeCounter > 5) {
            statusText = "Eyes closed ($closedEyeCounter)";
            statusColor = Colors.orange;
          } else {
            statusText = "Monitoring...";
            statusColor = Colors.green;
          }
        });
      }

    } catch (e) {
      print("Processing error: $e");
    }
  }

  Future<void> playAlarm() async {
    if (!alarmPlaying && mounted) {
      try {
        setState(() {
          alarmPlaying = true;
        });

        // Play alarm sound - CORRECT PATH
        await _audioPlayer.play(AssetSource('alarm.wav'));

        // You can also loop the alarm:
        // await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        // await _audioPlayer.play(AssetSource('alarm.wav'));

        print("Alarm started");
      } catch (e) {
        print("Error playing alarm: $e");
        if (mounted) {
          setState(() {
            alarmPlaying = false;
          });
        }
      }
    }
  }

  Future<void> stopAlarm() async {
    if (alarmPlaying && mounted) {
      try {
        await _audioPlayer.stop();
        setState(() {
          alarmPlaying = false;
        });
        print("Alarm stopped");
      } catch (e) {
        print("Error stopping alarm: $e");
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _interpreter?.close();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Drowsiness Detection"),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: _isCameraInitialized && _cameraController != null
          ? Stack(
        children: [
          // Camera preview
          SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: CameraPreview(_cameraController!),
          ),

          // Status overlay
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black.withOpacity(0.5),
              child: Column(
                children: [
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Closed frames: $closedEyeCounter",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Test button for audio (optional - remove in production)
          Positioned(
            bottom: 30,
            right: 20,
            child: FloatingActionButton(
              onPressed: () async {
                // Test audio
                await _audioPlayer.play(AssetSource('alarm.wav'));
              },
              backgroundColor: Colors.blue,
              child: const Icon(Icons.volume_up),
            ),
          ),
        ],
      )
          : Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              statusText,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }
}