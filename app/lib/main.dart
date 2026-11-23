import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

final navKey = GlobalKey<NavigatorState>();
late SharedPreferences prefs;

// Sal fixo: os dois aparelhos precisam derivar a mesma chave a partir da senha do chat.
const chatSalt = 'calcplus-v1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  runApp(const CalcApp());
}

// ============================================================
// Armazenamento local
// ============================================================
class Store {
  static String? get server => prefs.getString('server');
  static String? get token => prefs.getString('token');
  static int get myId => prefs.getInt('myId') ?? 0;
  static String? get pinHash => prefs.getString('pinHash');
  static String get salt => prefs.getString('salt') ?? '';
  static bool get configured =>
      server != null && token != null && pinHash != null;

  static String hashPin(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  static Uint8List deriveKey(String pass) {
    final h = utf8.encode('$chatSalt:$pass');
    var d = sha256.convert(h).bytes;
    for (var i = 0; i < 20000; i++) {
      d = sha256.convert([...d, ...h]).bytes;
    }
    return Uint8List.fromList(d);
  }
}

// ============================================================
// Criptografia ponta a ponta (AES-GCM). O servidor só vê texto cifrado.
// ============================================================
class Box {
  final enc.Encrypter _e;
  Box(Uint8List key)
      : _e = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));

  String seal(String text) {
    final iv = enc.IV.fromSecureRandom(12);
    final out = _e.encrypt(text, iv: iv);
    return base64.encode([...iv.bytes, ...out.bytes]);
  }

  String? open(String b64) {
    try {
      final all = base64.decode(b64);
      final iv = enc.IV(Uint8List.fromList(all.sublist(0, 12)));
      return _e.decrypt(
        enc.Encrypted(Uint8List.fromList(all.sublist(12))),
        iv: iv,
      );
    } catch (_) {
      return null;
    }
  }
}

// ============================================================
// API
// ============================================================
class ApiError implements Exception {
  final int code;
  ApiError(this.code);
}

class Api {
  static Future<dynamic> req(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    String? base,
    String? token,
  }) async {
    final uri = Uri.parse(base ?? Store.server!).replace(
      path: path,
      queryParameters: query,
    );
    final tk = token ?? Store.token;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (tk != null && tk.isNotEmpty) 'Authorization': 'Bearer $tk',
    };
    final r = await (method == 'GET'
            ? http.get(uri, headers: headers)
            : http.post(uri, headers: headers, body: jsonEncode(body ?? {})))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode >= 400) throw ApiError(r.statusCode);
    return jsonDecode(utf8.decode(r.bodyBytes));
  }
}

// ============================================================
// App
// ============================================================
class CalcApp extends StatefulWidget {
  const CalcApp({super.key});
  @override
  State<CalcApp> createState() => _CalcAppState();
}

class _CalcAppState extends State<CalcApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Ao sair do app (ou abrir os recentes), volta para a calculadora.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      navKey.currentState?.popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calc+',
      navigatorKey: navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const CalcPage(),
    );
  }
}

// ============================================================
// Calculadora (fachada)
// ============================================================
class _P {
  final String s;
  int i = 0;
  _P(this.s);

  double parse() {
    final v = _expr();
    if (i != s.length) throw const FormatException();
    return v;
  }

  double _expr() {
    var v = _term();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double _term() {
    var v = _unary();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = _unary();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double _unary() {
    if (i < s.length && s[i] == '-') {
      i++;
      return -_unary();
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return _unary();
    }
    return _num();
  }

  double _num() {
    final st = i;
    final digit = RegExp(r'[0-9.]');
    while (i < s.length && digit.hasMatch(s[i])) {
      i++;
    }
    if (st == i) throw const FormatException();
    var v = double.parse(s.substring(st, i));
    while (i < s.length && s[i] == '%') {
      i++;
      v /= 100;
    }
    return v;
  }
}

String fmt(double v) {
  if (v.isNaN || v.isInfinite) return 'Erro';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsPrecision(10);
  if (s.contains('e')) return s;
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

class CalcPage extends StatefulWidget {
  const CalcPage({super.key});
  @override
  State<CalcPage> createState() => _CalcPageState();
}

class _CalcPageState extends State<CalcPage> {
  String expr = '';
  bool justEvaluated = false;

  static const rows = [
    ['C', '⌫', '%', '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '−'],
    ['1', '2', '3', '+'],
    ['00', '0', '.', '='],
  ];

  String _token(String k) =>
      const {'÷': '/', '×': '*', '−': '-'}[k] ?? k;

  String get _display => expr.isEmpty
      ? '0'
      : expr.replaceAll('/', '÷').replaceAll('*', '×').replaceAll('-', '−');

  void _tap(String k) {
    if (k == '=') {
      // PIN + "=" abre o cofre.
      if (Store.configured &&
          RegExp(r'^\d{4,8}$').hasMatch(expr) &&
          Store.hashPin(expr, Store.salt) == Store.pinHash) {
        setState(() => expr = '');
        navKey.currentState!
            .push(MaterialPageRoute(builder: (_) => const VaultPage()));
        return;
      }
      setState(() {
        if (expr.isEmpty) return;
        try {
          expr = fmt(_P(expr).parse());
        } catch (_) {
          expr = 'Erro';
        }
        justEvaluated = true;
      });
      return;
    }
    setState(() {
      if (expr == 'Erro') expr = '';
      if (k == 'C') {
        expr = '';
      } else if (k == '⌫') {
        if (expr.isNotEmpty) expr = expr.substring(0, expr.length - 1);
      } else {
        final isNum = RegExp(r'^[0-9.]+$').hasMatch(k);
        if (justEvaluated && isNum) expr = '';
        expr += _token(k);
      }
      justEvaluated = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Expanded(
                flex: 2,
                child: Container(
                  alignment: Alignment.bottomRight,
                  padding: const EdgeInsets.all(12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _display,
                      style: const TextStyle(
                          fontSize: 64, fontWeight: FontWeight.w300),
                    ),
                  ),
                ),
              ),
              for (final row in rows)
                Expanded(
                  child: Row(
                    children: [for (final k in row) Expanded(child: _key(k))],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(String k) {
    final isOp = '÷×−+='.contains(k);
    final isTop = k == 'C' || k == '⌫' || k == '%';
    final bg = isOp
        ? const Color(0xFFFF9F0A)
        : isTop
            ? const Color(0xFFA5A5A5)
            : const Color(0xFF333333);
    return Padding(
      padding: const EdgeInsets.all(5),
      child: Material(
        color: bg,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _tap(k),
          // Primeiro uso: segurar "%" abre a configuração.
          onLongPress: (k == '%' && !Store.configured)
              ? () => navKey.currentState!
                  .push(MaterialPageRoute(builder: (_) => const SetupPage()))
              : null,
          child: Center(
            child: Text(
              k,
              style: TextStyle(
                fontSize: 28,
                color: isTop ? Colors.black : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// Configuração inicial (primeira vez, em cada aparelho)
// ============================================================
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final server = TextEditingController();
  final name = TextEditingController();
  final code = TextEditingController();
  final pin = TextEditingController();
  final chat = TextEditingController();
  bool first = true;
  bool busy = false;
  String? error;

  Future<void> _go() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var base = server.text.trim();
      if (base.endsWith('/')) base = base.substring(0, base.length - 1);
      if (!base.startsWith('https://')) {
        throw 'O endereço do servidor deve começar com https://';
      }
      final p = pin.text.trim();
      if (!RegExp(r'^\d{4,8}$').hasMatch(p)) {
        throw 'O PIN deve ter de 4 a 8 números.';
      }
      if (chat.text.length < 6) {
        throw 'A senha do chat precisa de pelo menos 6 caracteres.';
      }
      final body = first
          ? {'setupKey': code.text.trim(), 'name': name.text.trim()}
          : {'invite': code.text.trim(), 'name': name.text.trim()};
      final res = await Api.req('POST', first ? '/api/setup' : '/api/join',
          base: base, token: '', body: body);
      final token = res['token'] as String;
      final me = await Api.req('GET', '/api/me', base: base, token: token);

      final rnd = Random.secure();
      final salt =
          base64.encode(List<int>.generate(12, (_) => rnd.nextInt(256)));
      await prefs.clear();
      await prefs.setString('server', base);
      await prefs.setString('token', token);
      await prefs.setInt('myId', me['id'] as int);
      await prefs.setString('salt', salt);
      await prefs.setString('pinHash', Store.hashPin(p, salt));
      await prefs.setString('chatKey', base64.encode(Store.deriveKey(chat.text)));

      if (!mounted) return;
      if (first) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Código de convite'),
            content: SelectableText(
              '${res['invite']}\n\nEnvie para ela, junto com o endereço do '
              'servidor e a senha do chat. Funciona uma única vez.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Ok'),
              ),
            ],
          ),
        );
      }
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      setState(() => error = e.code == 429
          ? 'Muitas tentativas. Tente mais tarde.'
          : 'Código incorreto, ou o convite já foi usado.');
    } on String catch (m) {
      setState(() => error = m);
    } catch (_) {
      setState(() => error = 'Não foi possível conectar ao servidor.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(TextEditingController c, String label,
      {bool obscure = false, TextInputType? type}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: type,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuração')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Primeiro acesso')),
              ButtonSegment(value: false, label: Text('Tenho convite')),
            ],
            selected: {first},
            onSelectionChanged: (s) => setState(() => first = s.first),
          ),
          const SizedBox(height: 16),
          _field(server, 'Endereço do servidor (https://...)',
              type: TextInputType.url),
          _field(name, 'Seu nome'),
          _field(code, first ? 'Chave de setup' : 'Código de convite'),
          _field(pin, 'PIN da calculadora (4 a 8 números)',
              obscure: true, type: TextInputType.number),
          _field(chat, 'Senha do chat (igual nos dois aparelhos)',
              obscure: true),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          FilledButton(
            onPressed: busy ? null : _go,
            child: busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Conectar'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Cofre (tema azul lunar)
// ============================================================
const bgDeep = Color(0xFF050B1F);
const panel = Color(0xFF0B1A45);
const line = Color(0xFF1E3A8A);
const accent = Color(0xFF7FB2FF);
const mine = Color(0xFF1E56D6);
const theirs = Color(0xFF112456);

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});
  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDeep,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        surface: panel,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: line,
      ),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: tab,
            children: const [ChatTab(), LinksTab(), MoreTab()],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
            NavigationDestination(icon: Icon(Icons.public), label: 'Redes'),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Mais'),
          ],
        ),
      ),
    );
  }
}

class Msg {
  final int id;
  final int sender;
  final String text;
  final int ts;
  Msg(this.id, this.sender, this.text, this.ts);
  Map<String, dynamic> toJson() =>
      {'id': id, 'sender': sender, 'text': text, 'ts': ts};
  factory Msg.fromJson(Map<String, dynamic> j) =>
      Msg(j['id'], j['sender'], j['text'], j['ts']);
}

class ChatTab extends StatefulWidget {
  const ChatTab({super.key});
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final input = TextEditingController();
  final scroll = ScrollController();
  late Box box;
  final List<Msg> msgs = [];
  int lastId = 0;
  Timer? timer;
  bool polling = false;
  bool offline = false;

  @override
  void initState() {
    super.initState();
    box = Box(base64.decode(prefs.getString('chatKey') ?? ''));
    try {
      final raw = prefs.getString('msgs');
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          msgs.add(Msg.fromJson(j as Map<String, dynamic>));
        }
      }
    } catch (_) {}
    lastId = prefs.getInt('lastId') ?? 0;
    _poll();
    timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    final keep = msgs.length > 3000 ? msgs.sublist(msgs.length - 3000) : msgs;
    await prefs.setString('msgs', jsonEncode(keep.map((m) => m.toJson()).toList()));
    await prefs.setInt('lastId', lastId);
  }

  Future<void> _poll() async {
    if (polling || !Store.configured) return;
    polling = true;
    try {
      final rows = await Api.req('GET', '/api/messages',
          query: {'after': '$lastId'}) as List;
      if (offline) setState(() => offline = false);
      if (rows.isNotEmpty) {
        for (final r in rows) {
          final t = box.open(r['body'] as String) ?? '(mensagem ilegível)';
          msgs.add(Msg(r['id'], r['sender'], t, r['ts']));
          lastId = r['id'] as int;
        }
        await _save();
        if (mounted) setState(() {});
        _toEnd();
      }
    } catch (_) {
      if (mounted && !offline) setState(() => offline = true);
    } finally {
      polling = false;
    }
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final t = input.text.trim();
    if (t.isEmpty) return;
    input.clear();
    try {
      await Api.req('POST', '/api/messages', body: {'body': box.seal(t)});
      await _poll();
    } catch (_) {
      input.text = t;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não enviou. Verifique a conexão.')),
        );
      }
    }
  }

  String _hm(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: const BoxDecoration(
            color: panel,
            border: Border(bottom: BorderSide(color: line)),
          ),
          child: Text(
            offline ? 'Chat (sem conexão)' : 'Chat',
            style: const TextStyle(fontFamily: 'serif', fontSize: 20),
          ),
        ),
        Expanded(
          child: msgs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nenhuma mensagem ainda. Escreva a primeira.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final me = m.sender == Store.myId;
                    return Align(
                      alignment:
                          me ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78),
                        decoration: BoxDecoration(
                          color: me ? mine : theirs,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(m.text),
                            const SizedBox(height: 2),
                            Text(_hm(m.ts),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white60)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Mensagem',
                    filled: true,
                    fillColor: panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(color: line),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                icon: const Icon(Icons.send),
                tooltip: 'Enviar',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class LinksTab extends StatefulWidget {
  const LinksTab({super.key});
  @override
  State<LinksTab> createState() => _LinksTabState();
}

class _LinksTabState extends State<LinksTab> {
  List<Map<String, dynamic>> links = [];

  @override
  void initState() {
    super.initState();
    try {
      final raw = prefs.getString('links');
      if (raw != null) {
        links = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.req('GET', '/api/links') as List;
      await prefs.setString('links', jsonEncode(r));
      if (mounted) setState(() => links = r.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Redes',
              style: TextStyle(fontFamily: 'serif', fontSize: 20)),
          const SizedBox(height: 12),
          if (links.isEmpty)
            const Text('Nenhum link ainda. Edite o arquivo links.json no servidor.'),
          for (final l in links)
            Card(
              color: panel,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ListTile(
                title: Text('${l['nome']}'),
                subtitle: Text('${l['url']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => launchUrl(Uri.parse('${l['url']}'),
                    mode: LaunchMode.externalApplication),
              ),
            ),
        ],
      ),
    );
  }
}

class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  Future<void> _confirm(BuildContext context, String title, String text,
      Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (ok == true) {
      await action();
      navKey.currentState?.popUntil((r) => r.isFirst);
    }
  }

  // Permite migrar para outro servidor sem recompilar o app.
  Future<void> _changeServer(BuildContext context) async {
    final c = TextEditingController(text: Store.server ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Endereço do servidor'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Salvar')),
        ],
      ),
    );
    if (ok != true) return;
    var v = c.text.trim();
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
    if (!v.startsWith('https://')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('O endereço deve começar com https://')),
        );
      }
      return;
    }
    await prefs.setString('server', v);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Endereço salvo.')),
      );
    }
  }

  // Copia a conversa (já decifrada) para a área de transferência.
  Future<void> _copyChat(BuildContext context) async {
    final raw = prefs.getString('msgs');
    var out = '';
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        final m = Msg.fromJson(j as Map<String, dynamic>);
        final d = DateTime.fromMillisecondsSinceEpoch(m.ts);
        final who = m.sender == Store.myId ? 'Eu' : 'Ela/Ele';
        out += '[${d.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}] $who: ${m.text}\n';
      }
    }
    await Clipboard.setData(ClipboardData(text: out));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conversa copiada. Cole em um lugar seguro.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Mais',
            style: TextStyle(fontFamily: 'serif', fontSize: 20)),
        const SizedBox(height: 12),
        const Text(
          'As mensagens são cifradas neste aparelho antes de sair. '
          'O servidor guarda apenas texto cifrado.',
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: () => _changeServer(context),
          child: const Text('Trocar endereço do servidor'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _copyChat(context),
          child: const Text('Copiar conversa (backup)'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _confirm(
            context,
            'Limpar conversa',
            'Apaga as mensagens salvas neste aparelho. O histórico cifrado '
                'continua no servidor.',
            () async {
              await prefs.remove('msgs');
            },
          ),
          child: const Text('Limpar conversa deste aparelho'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _confirm(
            context,
            'Apagar tudo',
            'Remove a conta, o PIN, a chave e as mensagens deste aparelho. '
                'Para voltar, será preciso configurar de novo.',
            () async {
              await prefs.clear();
            },
          ),
          child: const Text('Desconectar e apagar tudo'),
        ),
      ],
    );
  }
}
