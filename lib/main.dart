import 'package:flutter/material.dart';

import 'app/composition_root.dart';
import 'app/remote_control_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(RemoteControlApp(dependencies: AppDependencies.production()));
}
