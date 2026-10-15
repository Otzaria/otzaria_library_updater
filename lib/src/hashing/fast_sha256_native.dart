import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'fast_sha256_sink.dart';

/// sink נייטיבי, או null כשאין מימוש מערכת, הבדיקה העצמית נכשלה, או שפתיחת
/// חישוב נכשלה — ואז הקורא נופל ל-`package:crypto`.
FastSha256Sink? startNativeSha256(Sink<Digest> output) {
  final native = _native;
  if (native == null) return null;
  try {
    return _NativeSha256Sink(native, output);
  } on _NativeShaFailure {
    return null;
  }
}

bool get isNativeSha256Available => _native != null;

/// נטען בעצלות, פעם אחת לכל isolate; הבדיקה העצמית היא שלושה גיבובים זעירים.
final _Sha256Native? _native = _openNative();

/// לינוקס ואנדרואיד נופלות ל-`package:crypto`: אין שם ספריית מערכת מובטחת.
_Sha256Native? _openNative() {
  try {
    final native = Platform.isWindows
        ? _BCryptSha256.openOrNull()
        : Platform.isMacOS || Platform.isIOS
            ? _CommonCryptoSha256.openOrNull()
            : null;
    if (native == null) return null;
    return _selfTestPasses(native) ? native : null;
  } catch (_) {
    return null;
  }
}

/// מימוש נייטיבי שאינו מסכים עם `package:crypto` היה דוחה כל עדכון.
bool _selfTestPasses(_Sha256Native native) {
  final samples = <List<int>>[
    const <int>[],
    const <int>[0xEF, 0xBB, 0xBF, 0xD7, 0x90, 0xD7, 0x95, 0x1F, 0xFF],
    Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xFF)),
  ];
  for (final sample in samples) {
    final collector = Sha256DigestCollector();
    final sink = _NativeSha256Sink(native, collector);
    try {
      sink
        ..add(sample)
        ..close();
    } finally {
      sink.dispose();
    }
    if (collector.value.toString() != sha256.convert(sample).toString()) {
      return false;
    }
  }
  return true;
}

abstract class _Sha256Native {
  Pointer<Void> begin();
  void update(Pointer<Void> ctx, Pointer<Uint8> data, int length);
  void finish(Pointer<Void> ctx, Pointer<Uint8> out32);
  void release(Pointer<Void> ctx);
}

class _NativeSha256Sink extends FastSha256Sink {
  _NativeSha256Sink(this._native, this._output) : _ctx = _native.begin();

  static const int _maxBufferBytes = 1 << 20;
  static const int _minBufferBytes = 4 << 10;

  final _Sha256Native _native;
  final Sink<Digest> _output;
  final Pointer<Void> _ctx;
  Pointer<Uint8>? _buffer;
  int _capacity = 0;
  Uint8List? _view;
  bool _closed = false;
  bool _released = false;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    // אחרי השחרור החוצץ הוחזר — כתיבה אליו הייתה שחיתות heap שקטה.
    if (_released || _closed) {
      throw StateError('FastSha256 sink: add after close');
    }
    if (end > start) {
      final view = _ensureBuffer(end - start);
      var offset = start;
      while (offset < end) {
        final length = (end - offset) < _capacity ? end - offset : _capacity;
        view.setRange(0, length, chunk, offset);
        _native.update(_ctx, _buffer!, length);
        offset += length;
      }
    }
    if (isLast) close();
  }

  /// החוצץ מוקצה בפעם הראשונה שיש מה לגבב, בגודל הגוש (4KB עד 1MB).
  Uint8List _ensureBuffer(int needed) {
    final existing = _view;
    if (existing != null) return existing;
    _capacity = needed < _minBufferBytes
        ? _minBufferBytes
        : needed > _maxBufferBytes
            ? _maxBufferBytes
            : needed;
    final buffer = malloc.allocate<Uint8>(_capacity);
    _buffer = buffer;
    return _view = buffer.asTypedList(_capacity);
  }

  @override
  void close() {
    if (_closed) return;
    if (_released) throw StateError('FastSha256 sink: close after dispose');
    _closed = true;
    final out = malloc.allocate<Uint8>(32);
    try {
      _native.finish(_ctx, out);
      _output.add(Digest(Uint8List.fromList(out.asTypedList(32))));
    } finally {
      malloc.free(out);
      dispose();
    }
    _output.close();
  }

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _native.release(_ctx);
    final buffer = _buffer;
    if (buffer != null) malloc.free(buffer);
    _buffer = null;
    _view = null;
  }
}

typedef _BCryptCreateHashNative = Int32 Function(
    Pointer<Void>,
    Pointer<Pointer<Void>>,
    Pointer<Uint8>,
    Uint32,
    Pointer<Uint8>,
    Uint32,
    Uint32);
typedef _BCryptCreateHashDart = int Function(Pointer<Void>,
    Pointer<Pointer<Void>>, Pointer<Uint8>, int, Pointer<Uint8>, int, int);

typedef _BCryptHashDataNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _BCryptHashDataDart = int Function(
    Pointer<Void>, Pointer<Uint8>, int, int);

typedef _BCryptFinishHashNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _BCryptFinishHashDart = int Function(
    Pointer<Void>, Pointer<Uint8>, int, int);

typedef _BCryptDestroyHashNative = Int32 Function(Pointer<Void>);
typedef _BCryptDestroyHashDart = int Function(Pointer<Void>);

/// SHA-256 של CNG (Windows) דרך ה-pseudo-handle הקבוע של האלגוריתם: אין ספק
/// לפתוח, ולכן גם אין handle שדולף כש-isolate מסתיים.
class _BCryptSha256 implements _Sha256Native {
  _BCryptSha256._(
    this._algorithm,
    this._createHash,
    this._hashData,
    this._finishHash,
    this._destroyHash,
  );

  final Pointer<Void> _algorithm;
  final _BCryptCreateHashDart _createHash;
  final _BCryptHashDataDart _hashData;
  final _BCryptFinishHashDart _finishHash;
  final _BCryptDestroyHashDart _destroyHash;

  /// `BCRYPT_SHA256_ALG_HANDLE` (Windows 10 ומעלה).
  static final Pointer<Void> _sha256PseudoHandle = Pointer.fromAddress(0x41);

  static _BCryptSha256? openOrNull() {
    final lib = DynamicLibrary.open('bcrypt.dll');
    return _BCryptSha256._(
      _sha256PseudoHandle,
      lib.lookupFunction<_BCryptCreateHashNative, _BCryptCreateHashDart>(
          'BCryptCreateHash'),
      lib.lookupFunction<_BCryptHashDataNative, _BCryptHashDataDart>(
          'BCryptHashData'),
      lib.lookupFunction<_BCryptFinishHashNative, _BCryptFinishHashDart>(
          'BCryptFinishHash'),
      lib.lookupFunction<_BCryptDestroyHashNative, _BCryptDestroyHashDart>(
          'BCryptDestroyHash'),
    );
  }

  @override
  Pointer<Void> begin() {
    final hashOut = calloc<Pointer<Void>>();
    try {
      if (_createHash(_algorithm, hashOut, nullptr, 0, nullptr, 0, 0) != 0) {
        throw const _NativeShaFailure('BCryptCreateHash');
      }
      return hashOut.value;
    } finally {
      calloc.free(hashOut);
    }
  }

  @override
  void update(Pointer<Void> ctx, Pointer<Uint8> data, int length) {
    if (_hashData(ctx, data, length, 0) != 0) {
      throw const _NativeShaFailure('BCryptHashData');
    }
  }

  @override
  void finish(Pointer<Void> ctx, Pointer<Uint8> out32) {
    if (_finishHash(ctx, out32, 32, 0) != 0) {
      throw const _NativeShaFailure('BCryptFinishHash');
    }
  }

  @override
  void release(Pointer<Void> ctx) => _destroyHash(ctx);
}

typedef _CcInitNative = Int32 Function(Pointer<Void>);
typedef _CcInitDart = int Function(Pointer<Void>);

typedef _CcUpdateNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _CcUpdateDart = int Function(Pointer<Void>, Pointer<Uint8>, int);

typedef _CcFinalNative = Int32 Function(Pointer<Uint8>, Pointer<Void>);
typedef _CcFinalDart = int Function(Pointer<Uint8>, Pointer<Void>);

/// SHA-256 של CommonCrypto (macOS ו-iOS), מתוך libSystem שכבר טעון בתהליך.
class _CommonCryptoSha256 implements _Sha256Native {
  _CommonCryptoSha256._(this._init, this._update, this._final);

  /// `CC_SHA256_CTX` הוא 104 בתים; מעוגל למעלה למקרה שהמבנה יגדל.
  static const int _contextBytes = 256;

  final _CcInitDart _init;
  final _CcUpdateDart _update;
  final _CcFinalDart _final;

  static _CommonCryptoSha256? openOrNull() {
    final lib = DynamicLibrary.process();
    return _CommonCryptoSha256._(
      lib.lookupFunction<_CcInitNative, _CcInitDart>('CC_SHA256_Init'),
      lib.lookupFunction<_CcUpdateNative, _CcUpdateDart>('CC_SHA256_Update'),
      lib.lookupFunction<_CcFinalNative, _CcFinalDart>('CC_SHA256_Final'),
    );
  }

  @override
  Pointer<Void> begin() {
    final ctx = calloc.allocate<Uint8>(_contextBytes).cast<Void>();
    if (_init(ctx) != 1) {
      calloc.free(ctx);
      throw const _NativeShaFailure('CC_SHA256_Init');
    }
    return ctx;
  }

  @override
  void update(Pointer<Void> ctx, Pointer<Uint8> data, int length) {
    if (_update(ctx, data, length) != 1) {
      throw const _NativeShaFailure('CC_SHA256_Update');
    }
  }

  @override
  void finish(Pointer<Void> ctx, Pointer<Uint8> out32) {
    if (_final(out32, ctx) != 1) {
      throw const _NativeShaFailure('CC_SHA256_Final');
    }
  }

  @override
  void release(Pointer<Void> ctx) => calloc.free(ctx);
}

class _NativeShaFailure implements Exception {
  const _NativeShaFailure(this.symbol);
  final String symbol;
  @override
  String toString() => 'NativeShaFailure: $symbol';
}
