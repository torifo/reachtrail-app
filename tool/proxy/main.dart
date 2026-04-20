import 'dart:io';

const _port = 3000;

void main() async {
  final apiKey = Platform.environment['YAHOO_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('YAHOO_API_KEY is not set');
  }

  final server = await HttpServer.bind('localhost', _port);
  print('Yahoo proxy running at http://localhost:$_port');

  await for (final req in server) {
    _handle(req, apiKey);
  }
}

Future<void> _handle(HttpRequest req, String apiKey) async {
  req.response.headers.add('Access-Control-Allow-Origin', '*');
  req.response.headers.add('Access-Control-Allow-Methods', 'GET, OPTIONS');

  if (req.method == 'OPTIONS') {
    req.response.statusCode = 200;
    await req.response.close();
    return;
  }

  final params = Map<String, String>.from(req.uri.queryParameters)
    ..['appid'] = apiKey;

  final yahooUri = Uri.https(
    'map.yahooapis.jp',
    '/search/local/V1/localSearch',
    params,
  );

  try {
    final client = HttpClient();
    final yahooReq = await client.getUrl(yahooUri);
    final yahooRes = await yahooReq.close();

    req.response.statusCode = yahooRes.statusCode;
    req.response.headers.contentType = ContentType.json;
    await yahooRes.pipe(req.response);
  } catch (e) {
    req.response.statusCode = 502;
    await req.response.close();
  }
}
