import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

// Native functions from android/app/src/main/cpp/studymate_llm.cpp.
// Used on Android only. Windows and Linux keep the llama-server process.
final DynamicLibrary _lib = DynamicLibrary.open('libstudymate_llm.so');

typedef _TokenNative = Void Function(Pointer<Utf8>);
typedef _LoadNative = Int32 Function(Pointer<Utf8>, Int32, Int32);
typedef _LoadDart = int Function(Pointer<Utf8>, int, int);
typedef _GenNative = Int32 Function(Pointer<Utf8>, Int32, Pointer<NativeFunction<_TokenNative>>);
typedef _GenDart = int Function(Pointer<Utf8>, int, Pointer<NativeFunction<_TokenNative>>);

final _LoadDart _smLoad = _lib.lookupFunction<_LoadNative, _LoadDart>('sm_load');
final _GenDart _smGenerate = _lib.lookupFunction<_GenNative, _GenDart>('sm_generate');

int _loadSync(String path, int nCtx, int threads) {
  final p = path.toNativeUtf8();
  try {
    return _smLoad(p, nCtx, threads);
  } finally {
    malloc.free(p);
  }
}

int _generateSync(String prompt, int maxTokens, int callbackAddress) {
  final p = prompt.toNativeUtf8();
  try {
    return _smGenerate(
      p,
      maxTokens,
      Pointer<NativeFunction<_TokenNative>>.fromAddress(callbackAddress),
    );
  } finally {
    malloc.free(p);
  }
}

class AndroidLlm {
  bool _loaded = false;
  bool get loaded => _loaded;

  /// Loads the GGUF file on a background isolate so the UI stays responsive.
  Future<void> load(String modelPath, {int contextSize = 4096, int threads = 4}) async {
    final code = await Isolate.run(() => _loadSync(modelPath, contextSize, threads));
    if (code != 0) {
      throw Exception('Could not load the model (code $code). Check free RAM and try again.');
    }
    _loaded = true;
  }

  /// Streams tokens. The prompt must already be formatted with [buildChatMl].
  Stream<String> generate(String prompt, {int maxTokens = 350}) {
    final controller = StreamController<String>();
    final callable = NativeCallable<_TokenNative>.listener((Pointer<Utf8> piece) {
      if (!controller.isClosed) controller.add(piece.toDartString());
    });
    final address = callable.nativeFunction.address;

    Isolate.run(() => _generateSync(prompt, maxTokens, address)).then((code) async {
      // Let the last token messages arrive before closing the callback.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      callable.close();
      if (code != 0 && !controller.isClosed) {
        controller.addError(Exception('Generation failed (code $code).'));
      }
      if (!controller.isClosed) await controller.close();
    }, onError: (Object e) async {
      callable.close();
      if (!controller.isClosed) {
        controller.addError(e);
        await controller.close();
      }
    });
    return controller.stream;
  }
}

/// Qwen models use ChatML. [history] holds {role, content} maps.
String buildChatMl({
  required String system,
  required List<Map<String, String>> history,
  required String user,
}) {
  final b = StringBuffer('<|im_start|>system\n$system<|im_end|>\n');
  for (final m in history) {
    b.write('<|im_start|>${m['role']}\n${m['content']}<|im_end|>\n');
  }
  b.write('<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n');
  return b.toString();
}
