import 'package:file_selector/file_selector.dart';

import '../core/bridge.dart';

Future<bool> addMusicFolder(CoreBridge core, {required bool Function() isMounted}) async {
  final path = await getDirectoryPath();
  if (path == null || !isMounted()) return false;
  await core.addRoot(path);
  return true;
}
