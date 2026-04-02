import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math';

void main() => runApp(const ASAirApp());

class ASAirApp extends StatefulWidget {
  const ASAirApp({super.key});
  @override
  State<ASAirApp> createState() => _ASAirAppState();
}

class _ASAirAppState extends State<ASAirApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wind Tunnel Control',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF8A2BE2), // Violet
          secondary: Color(0xFFFF8800), // Orange
        ),
        cardColor: Colors.white,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8A2BE2), 
          secondary: Color(0xFFFF8800),
        ),
        cardColor: const Color(0xFF1E1E1E),
      ),
      home: ControlDashboard(toggleTheme: toggleTheme, isDark: _themeMode == ThemeMode.dark),
    );
  }
}

class ControlDashboard extends StatefulWidget {
  final VoidCallback toggleTheme;
  final bool isDark;
  const ControlDashboard({super.key, required this.toggleTheme, required this.isDark});

  @override
  State<ControlDashboard> createState() => _ControlDashboardState();
}

class _ControlDashboardState extends State<ControlDashboard> {
  UsbPort? _port;
  Timer? _pollTimer;
  
  bool _connected = false;
  bool _isSimulated = true; // Default to Ghost Mode on boot
  String _status = "System Offline";
  
  double _currentSlider = 0.0;
  double _actualFlow = 0.0;
  final TextEditingController _targetCtrl = TextEditingController(text: "0.00");
  
  String _selectedGas = 'Air';
  final Map<String, double> kFactors = {
    'N2': 1.000, 'O2': 0.993, 'Air': 1.000,
    'Argon': 1.450, 'CO2': 0.740, 'Helium': 1.454
  };

  List<UsbDevice> _devices = [];
  UsbDevice? _selectedDevice;
  
  List<int> _rxBuffer = [];

  @override
  void initState() {
    super.initState();
    _refreshPorts();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _port?.close();
    _targetCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshPorts() async {
    List<UsbDevice> devices = await UsbSerial.listDevices();
    setState(() {
      _devices = devices;
      // Try to auto-select the last device (usually the serial chip, not the hub)
      if (devices.isNotEmpty) {
        _selectedDevice = devices.last; 
        _isSimulated = false;
      } else {
        _selectedDevice = null;
        _isSimulated = true;
      }
    });
  }

  // --- HARDWARE HANDSHAKE WITH PERMISSION OVERRIDE ---
  Future<void> connectHardware() async {
    setState(() => _status = "Connecting...");

    try {
      if (_isSimulated) {
        _connected = true;
        setState(() => _status = "Online (Ghost Mode)");
        startTelemetry();
        return;
      }

      if (_selectedDevice == null) {
        setState(() => _status = "Error: No FTDI/USB device selected.");
        return;
      }

      setState(() => _status = "Waiting for Android Permission...");
      
      // THE FIX: FORCE THE ANDROID PERMISSION POP-UP
      bool hasPermission = await UsbSerial.requestPermission(_selectedDevice!);
      if (!hasPermission) {
        setState(() => _status = "Error: Android denied USB permission.");
        return;
      }

      _port = await _selectedDevice!.create();
      if (_port == null) {
        setState(() => _status = "Error: Android refused port creation.");
        return;
      }

      bool openResult = await _port!.open();
      if (!openResult) {
        setState(() => _status = "Failed to open port. Check permissions.");
        return;
      }

      await _port!.setDTR(true);
      await _port!.setRTS(true);
      await _port!.setPortParameters(19200, UsbPort.DATABITS_8, UsbPort.STOPBITS_2, UsbPort.PARITY_NONE);

      // Incoming Telemetry Listener
      _port!.inputStream!.listen((Uint8List data) {
        _rxBuffer.addAll(data);
        if (_rxBuffer.length >= 9) { 
          if (_rxBuffer[0] == 0x01 && _rxBuffer[1] == 0x03 && _rxBuffer[2] == 0x04) {
            List<int> payload = _rxBuffer.sublist(3, 7);
            var bdata = ByteData.view(Uint8List.fromList(payload).buffer);
            double rawML = bdata.getFloat32(0, Endian.big);
            double rawSLPM = rawML / 1000.0;
            double kRatio = kFactors['O2']! / kFactors[_selectedGas]!;
            
            if(mounted) {
              setState(() => _actualFlow = rawSLPM / kRatio);
            }
          }
          _rxBuffer.clear(); 
        }
      });

      setState(() {
        _connected = true;
        _status = "Online & Hardware Verified";
      });
      
      startTelemetry();
      
    } catch (e) {
      setState(() => _status = "CRASH: ${e.toString()}");
    }
  }

  // --- 5Hz TELEMETRY LOOP ---
  void startTelemetry() {
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_isSimulated) {
        double noise = _currentSlider > 0 ? (Random().nextDouble() * 0.1 - 0.05) : 0.0;
        setState(() => _actualFlow = max(0.0, _currentSlider + noise));
      } else if (_connected && _port != null) {
        List<int> req = [0x01, 0x03, 0x00, 0x00, 0x00, 0x02];
        int crc = calculateCRC(req);
        req.add(crc & 0xFF);
        req.add((crc >> 8) & 0xFF);
        _port!.write(Uint8List.fromList(req));
      }
    });
  }

  // --- MODBUS CRC-16 CHECK ---
  int calculateCRC(List<int> bytes) {
    int crc = 0xFFFF;
    for (int pos = 0; pos < bytes.length; pos++) {
      crc ^= bytes[pos];
      for (int i = 8; i != 0; i--) {
        if ((crc & 0x0001) != 0) {
          crc >>= 1;
          crc ^= 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc;
  }

  // --- WRITE COMMAND ---
  void sendFlowCommand(double targetSLPM) async {
    if (!_connected || _isSimulated || _port == null) return;

    double kRatio = kFactors['O2']! / kFactors[_selectedGas]!;
    double adjustedML = (targetSLPM * kRatio) * 1000.0;

    var bdata = ByteData(4)..setFloat32(0, adjustedML, Endian.big);
    List<int> floatBytes = bdata.buffer.asUint8List();

    List<int> frame = [
      0x01, 0x10, 0x00, 0x02, 0x00, 0x02, 0x04,
      floatBytes[0], floatBytes[1], floatBytes[2], floatBytes[3]
    ];
    
    int crc = calculateCRC(frame);
    frame.add(crc & 0xFF);         
    frame.add((crc >> 8) & 0xFF);   

    await _port!.write(Uint8List.fromList(frame));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ASAir OTG Control', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        actions: [
          Row(
            children: [
              Icon(widget.isDark ? Icons.dark_mode : Icons.light_mode),
              Switch(
                value: !widget.isDark,
                onChanged: (val) => widget.toggleTheme(),
                activeColor: Theme.of(context).colorScheme.secondary,
              ),
            ],
          )
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600), // Responsive Tablet Lock
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  
                  // --- HARDWARE LINK CARD ---
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Hardware Link", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButton<dynamic>(
                                  isExpanded: true,
                                  value: _isSimulated ? "ghost" : _selectedDevice,
                                  items: [
                                    ..._devices.map((device) {
                                      String name = device.productName ?? "Unknown USB Device";
                                      return DropdownMenuItem<dynamic>(
                                        value: device,
                                        child: Text("$name (VID: ${device.vid})", overflow: TextOverflow.ellipsis),
                                      );
                                    }).toList(),
                                    const DropdownMenuItem<dynamic>(
                                      value: "ghost", 
                                      child: Text("SIMULATION MODE (Ghost)")
                                    ),
                                  ],
                                  onChanged: _connected ? null : (val) {
                                    setState(() {
                                      if (val == "ghost") {
                                        _isSimulated = true;
                                        _selectedDevice = null;
                                      } else {
                                        _isSimulated = false;
                                        _selectedDevice = val as UsbDevice;
                                      }
                                    });
                                  },
                                ),
                              ),
                              IconButton(icon: const Icon(Icons.refresh), onPressed: _connected ? null : _refreshPorts)
                            ],
                          ),
                          const SizedBox(height: 15),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _connected ? Colors.grey : Theme.of(context).colorScheme.secondary,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              minimumSize: const Size(double.infinity, 50),
                            ),
                            onPressed: _connected ? null : connectHardware,
                            child: Text(_connected ? 'System Connected' : 'CONNECT & VERIFY', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 20),

                  // --- KINEMATICS CARD ---
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                           Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text("Flow Control", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                              DropdownButton<String>(
                                value: _selectedGas,
                                items: kFactors.keys.map((String gas) {
                                  return DropdownMenuItem<String>(value: gas, child: Text(gas));
                                }).toList(),
                                onChanged: !_connected ? null : (val) => setState(() => _selectedGas = val!),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          
                          Slider(
                            value: _currentSlider,
                            min: 0.0,
                            max: 20.0,
                            divisions: 80, // 0.25 steps
                            activeColor: Theme.of(context).colorScheme.secondary,
                            inactiveColor: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                            onChanged: !_connected ? null : (val) {
                              setState(() {
                                _currentSlider = val;
                                _targetCtrl.text = val.toStringAsFixed(2);
                              });
                              sendFlowCommand(val);
                            },
                          ),
                          
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _targetCtrl,
                                  enabled: _connected,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: "Target (SLPM)", border: OutlineInputBorder()),
                                ),
                              ),
                              const SizedBox(width: 15),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                                ),
                                onPressed: !_connected ? null : () {
                                  double? val = double.tryParse(_targetCtrl.text);
                                  if (val != null && val >= 0 && val <= 20) {
                                    setState(() => _currentSlider = val);
                                    sendFlowCommand(val);
                                  }
                                },
                                child: const Text("SET", style: TextStyle(fontWeight: FontWeight.bold)),
                              )
                            ],
                          ),
                          
                          const SizedBox(height: 20),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              minimumSize: const Size(double.infinity, 60),
                            ),
                            onPressed: !_connected ? null : () {
                              setState(() {
                                _currentSlider = 0.0;
                                _targetCtrl.text = "0.00";
                              });
                              sendFlowCommand(0.0);
                            },
                            child: const Text('EMERGENCY ZERO VALVE', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // --- TELEMETRY CARD ---
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
                      child: Column(
                        children: [
                          Text("Live Hardware Telemetry", style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.primary)),
                          const SizedBox(height: 10),
                          Text(
                            "${_actualFlow.toStringAsFixed(2)} SLPM",
                            style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.secondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                  Center(child: Text(_status, style: TextStyle(color: _connected ? Colors.green : Colors.grey, fontSize: 14))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
