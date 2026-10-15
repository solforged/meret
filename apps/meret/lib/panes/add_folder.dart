import 'package:file_selector/file_selector.dart';

import '../core/bridge.dart';

Future<bool> addMusicFolder(CoreBridge core, {String? path, required bool Function() isMounted}) async {
  final selected = path ?? await getDirectoryPath();
  if (selected == null || !isMounted()) return false;
  await core.addRoot(selected);
  return true;
}
