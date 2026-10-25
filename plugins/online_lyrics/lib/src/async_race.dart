/// 与超时竞速：到期先返回 [onTimeout] 的结果，慢的一方在后台自然完成
/// （Dart Future 无法取消，结果被丢弃即可）。
///
/// 语义对齐 Kotlin 的 `withTimeoutOrNull`（超时得到回退值）。
library;

import 'dart:async';

Future<T> withDeadline<T>(
  Future<T> future,
  Duration timeout,
  T Function() onTimeout,
) {
  final completer = Completer<T>();
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  Future<void>.delayed(timeout).then((_) {
    if (!completer.isCompleted) completer.complete(onTimeout());
  });
  return completer.future;
}
