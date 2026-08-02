import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/login.dart';
import 'screens/repartidor/repartidor_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    anonKey: Config.supabaseAnonKey,
  );
  runApp(const ZasApp());
}

final supa = Supabase.instance.client;
const naranjaZas = Color(0xFFE85D04);

class ZasApp extends StatelessWidget {
  const ZasApp({super.key});

  @override
  Widget build(BuildContext context) {
    final esquema = ColorScheme.fromSeed(seedColor: naranjaZas);
    return MaterialApp(
      title: 'ZAS Reparto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: esquema,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F5F2),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F5F2),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.black.withValues(alpha: .06)),
          ),
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.black.withValues(alpha: .12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.black.withValues(alpha: .12)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: naranjaZas, width: 2),
          ),
        ),
      ),
      home: const PuertaDeEntrada(),
    );
  }
}

/// Controla: sesión → bloqueo biométrico → app de repartos.
class PuertaDeEntrada extends StatefulWidget {
  const PuertaDeEntrada({super.key});

  @override
  State<PuertaDeEntrada> createState() => _PuertaDeEntradaState();
}

class _PuertaDeEntradaState extends State<PuertaDeEntrada> {
  bool _desbloqueada = false;

  @override
  void initState() {
    super.initState();
    supa.auth.onAuthStateChange.listen((estado) {
      if (estado.event == AuthChangeEvent.signedIn) _desbloqueada = true;
      if (estado.event == AuthChangeEvent.signedOut) _desbloqueada = false;
      if (mounted) setState(() {});
    });
  }

  Future<Map<String, dynamic>?> _cargarPerfil() async {
    final user = supa.auth.currentUser;
    if (user == null) return null;
    return await supa.from('perfiles').select().eq('id', user.id).maybeSingle();
  }

  @override
  Widget build(BuildContext context) {
    final session = supa.auth.currentSession;
    if (session == null) return const LoginScreen();
    if (!_desbloqueada) {
      return PantallaBloqueo(
          onDesbloquear: () => setState(() => _desbloqueada = true));
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: _cargarPerfil(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final perfil = snap.data;
        if (perfil == null || perfil['activo'] == false) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(perfil == null
                      ? 'No se encontró tu perfil.'
                      : 'Tu cuenta está desactivada.'),
                  TextButton(
                    onPressed: () => supa.auth.signOut(),
                    child: const Text('Volver a ingresar'),
                  ),
                ],
              ),
            ),
          );
        }
        return RepartidorHome(perfil: perfil);
      },
    );
  }
}

/// Pantalla de bloqueo: pide huella (o el desbloqueo del teléfono).
class PantallaBloqueo extends StatefulWidget {
  final VoidCallback onDesbloquear;
  const PantallaBloqueo({super.key, required this.onDesbloquear});

  @override
  State<PantallaBloqueo> createState() => _PantallaBloqueoState();
}

class _PantallaBloqueoState extends State<PantallaBloqueo> {
  final _auth = LocalAuthentication();
  String? _mensaje;

  @override
  void initState() {
    super.initState();
    _intentar();
  }

  Future<void> _intentar() async {
    final prefs = await SharedPreferences.getInstance();
    final bioActiva = prefs.getBool('bio_activa') ?? false;
    if (!bioActiva) {
      widget.onDesbloquear();
      return;
    }
    try {
      final soportado = await _auth.isDeviceSupported();
      if (!soportado) {
        widget.onDesbloquear();
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Usa tu huella para entrar a ZAS Reparto',
        options: const AuthenticationOptions(stickyAuth: true),
      );
      if (ok) {
        widget.onDesbloquear();
      } else if (mounted) {
        setState(() => _mensaje = 'No se pudo verificar. Intenta de nuevo.');
      }
    } catch (_) {
      widget.onDesbloquear(); // sin biometría disponible: no bloquear
    }
  }

  Future<void> _usarClave() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bio_activa', false);
    await supa.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFFF48C06), Color(0xFFDC2F02)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.fingerprint,
                    color: Colors.white, size: 52),
              ),
              const SizedBox(height: 24),
              Text('ZAS Reparto',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('Desbloquea con tu huella para continuar',
                  textAlign: TextAlign.center),
              if (_mensaje != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_mensaje!,
                      style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 28),
              FilledButton.icon(
                icon: const Icon(Icons.fingerprint),
                label: const Text('Desbloquear'),
                onPressed: _intentar,
              ),
              TextButton(
                onPressed: _usarClave,
                child: const Text('Ingresar con correo y contraseña'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
