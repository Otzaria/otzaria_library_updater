import 'package:crypto/crypto.dart';

import 'fast_sha256_sink.dart';

FastSha256Sink? startNativeSha256(Sink<Digest> output) => null;

bool get isNativeSha256Available => false;
