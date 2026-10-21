import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Exercise the actual request/redirect/download pipeline without external keys,
// DNS, TLS exceptions or requests to CurseForge during CI.
class TestHeaders implements HttpHeaders {
  final values = <String, String>{};
  TestHeaders([Map<String, String> initial = const {}]) {
    initial.forEach((name, value) => values[name.toLowerCase()] = value);
  }
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final TestHeaders headers;
  final List<int> bytes;
  TestResponse(
    this.statusCode, {
    String text = '',
    List<int>? bytes,
    Map<String, String> headers = const {},
  }) : bytes = bytes ?? utf8.encode(text),
       headers = TestHeaders(headers);
  @override
  int get contentLength => bytes.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestRequest implements HttpClientRequest {
  @override
  final Uri uri;
  final TestResponse Function(TestRequest) respond;
  @override
  final headers = TestHeaders();
  TestRequest(this.uri, this.respond);
  @override
  Future<HttpClientResponse> close() async => respond(this);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestClient implements HttpClient {
  final requests = <TestRequest>[];
  final TestResponse Function(TestRequest) respond;
  TestClient(this.respond);
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = TestRequest(uri, respond);
    requests.add(request);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
