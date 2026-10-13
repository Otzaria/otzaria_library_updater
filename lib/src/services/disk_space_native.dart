import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// הבייטים הפנויים לחשבון הנוכחי (ולא לנפח) — מכסת דיסק היא בדיוק ההבדל.
int? windowsFreeBytes(String dir) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getDiskFreeSpaceEx = kernel32.lookupFunction<
      Int32 Function(
          Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
          Pointer<Uint64>)>('GetDiskFreeSpaceExW');

  final pathPtr = dir.toNativeUtf16();
  final freeToCaller = malloc<Uint64>();
  final total = malloc<Uint64>();
  final totalFree = malloc<Uint64>();
  try {
    final ok = getDiskFreeSpaceEx(pathPtr, freeToCaller, total, totalFree);
    if (ok == 0) return null;
    return freeToCaller.value;
  } finally {
    malloc.free(pathPtr);
    malloc.free(freeToCaller);
    malloc.free(total);
    malloc.free(totalFree);
  }
}

String? windowsFileSystemName(String dir) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getVolumePathName = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('GetVolumePathNameW');
  final getVolumeInformation = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>, int)>(
    'GetVolumeInformationW',
  );

  const capacity = 1024;
  final pathPtr = dir.toNativeUtf16();
  final root = malloc<Uint16>(capacity).cast<Utf16>();
  final fsName = malloc<Uint16>(capacity).cast<Utf16>();
  try {
    if (getVolumePathName(pathPtr, root, capacity) == 0) return null;
    final ok = getVolumeInformation(
        root, nullptr, 0, nullptr, nullptr, nullptr, fsName, capacity);
    if (ok == 0) return null;
    return fsName.toDartString();
  } finally {
    malloc.free(pathPtr);
    malloc.free(root);
    malloc.free(fsName);
  }
}
